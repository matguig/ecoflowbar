// First-run setup wizard — everything happens in the app, no terminal:
// sign in to the EcoFlow account (official API), Bluetooth pairing (CoreBluetooth),
// admin permissions via the macOS dialog (sudoers).
import AppKit
import CoreBluetooth
import SwiftUI

// MARK: - EcoFlow account sign-in (same call as the official app)

enum EFLoginError: LocalizedError {
    case http(Int)
    case api(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Network error (\(code))"
        case .api(let message): return message
        case .malformed: return "Unexpected server response"
        }
    }
}

enum EFLogin {
    static let regions = ["auto", "api", "api-e", "api-a", "api-j", "api-r"]

    static func login(email: String, password: String, region: String) async throws -> String {
        let host = region == "auto" ? "api.ecoflow.com" : "\(region).ecoflow.com"
        var request = URLRequest(url: URL(string: "https://\(host)/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "scene": "IOT_APP",
            "appVersion": "1.0.0",
            "password": Data(password.utf8).base64EncodedString(),
            "oauth": ["bundleId": "com.ef.EcoFlow"],
            "userType": "ECOFLOW",
            "email": email,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EFLoginError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["code"] as? String
        else { throw EFLoginError.malformed }
        guard code == "0" else {
            throw EFLoginError.api(json["message"] as? String ?? "credentials rejected")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let user = dataObj["user"] as? [String: Any],
              let userId = user["userId"] as? String
        else { throw EFLoginError.malformed }
        return userId
    }
}

// MARK: - Bluetooth scan for EcoFlow devices

final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate {
    struct Found: Identifiable {
        let sn: String
        let name: String
        var rssi: Int
        var id: String { sn }
    }

    @Published var devices: [Found] = []
    @Published var state: CBManagerState = .unknown
    private var central: CBCentralManager?

    static let manufacturerID: UInt16 = 46517  // 0xB5B5, EcoFlow

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else if central?.state == .poweredOn {
            scan()
        }
    }

    func stop() {
        central?.stopScan()
    }

    private func scan() {
        central?.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state == .poweredOn { scan() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              mfg.count >= 19,
              UInt16(mfg[0]) | (UInt16(mfg[1]) << 8) == Self.manufacturerID
        else { return }
        // After the manufacturer ID: [0x13][SN 16 bytes] (cf. eflib protocol)
        let payload = mfg.dropFirst(2)
        guard payload.first == 0x13 else { return }
        let snBytes = payload.dropFirst().prefix(16).filter { $0 != 0 }
        guard let sn = String(bytes: snBytes, encoding: .ascii), !sn.isEmpty else { return }

        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = Self.modelName(sn: sn) ?? localName ?? "EcoFlow"
        DispatchQueue.main.async {
            if let index = self.devices.firstIndex(where: { $0.sn == sn }) {
                self.devices[index].rssi = RSSI.intValue
            } else {
                self.devices.append(Found(sn: sn, name: name, rssi: RSSI.intValue))
            }
        }
    }

    private static func modelName(sn: String) -> String? {
        let prefixes: [String: String] = [
            "R631": "River 3 Plus", "R634": "River 3 Plus (270)",
            "R635": "River 3 Plus Wireless", "R63": "River 3",
            "R62": "River 2", "R60": "River 2",
            "D361": "Delta 3 Plus", "D3": "Delta 3", "DP3": "Delta Pro 3",
        ]
        for (prefix, name) in prefixes.sorted(by: { $0.key.count > $1.key.count })
        where sn.hasPrefix(prefix) {
            return name
        }
        return nil
    }
}

// MARK: - Admin permissions without a terminal (macOS dialog)

enum AdminSetup {
    static var sudoersInstalled: Bool {
        FileManager.default.fileExists(atPath: "/etc/sudoers.d/ecoflow-monitor")
    }

    /// Installs the sudoers rule via the macOS administrator password prompt
    /// (no terminal); visudo validates the file before installation.
    static func installSudoers() async -> Bool {
        let user = NSUserName()
        let content = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 1, "
            + "/usr/bin/pmset -a lowpowermode 0, /sbin/shutdown -h now, "
            + "/usr/bin/powermetrics -i 500 -n 1 --samplers cpu_power\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ecoflow-sudoers-\(getpid())")
        do {
            try content.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let shell = "visudo -cf '\(tmp.path)' && install -m 440 '\(tmp.path)' /etc/sudoers.d/ecoflow-monitor"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}

// MARK: - Aurora: visual signature (the only continuously moving element)

struct AuroraView: View {
    @State private var risen = false
    var intensity: Double = 0.6

    private static let palette: [Color] = [
        Color(red: 1.00, green: 0.45, blue: 0.65),  // pink
        Color(red: 1.00, green: 0.32, blue: 0.24),  // red
        Color(red: 1.00, green: 0.80, blue: 0.30),  // yellow
        Color(red: 0.72, green: 0.62, blue: 1.00),  // lavender
        Color(red: 0.32, green: 0.54, blue: 1.00),  // blue
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(Array(Self.palette.enumerated()), id: \.offset) { index, color in
                        let phase = t * 0.22 + Double(index) * 1.35
                        Ellipse()
                            .fill(color)
                            .frame(width: geo.size.width * 0.44, height: geo.size.height * 0.46)
                            .offset(
                                x: geo.size.width * (-0.46 + Double(index) * 0.23)
                                    + CGFloat(sin(phase)) * 26,
                                y: geo.size.height * 0.40 + CGFloat(cos(phase * 0.7)) * 14
                            )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .blur(radius: 72)
            .opacity(intensity)
            .scaleEffect(y: risen ? 1 : 0.05, anchor: .bottom)
        }
        .allowsHitTesting(false)
        .onAppear {
            // The aurora "unfurls from the ground" as it appears
            withAnimation(.spring(response: 1.6, dampingFraction: 0.85)) { risen = true }
        }
    }
}

// MARK: - Typographic components and buttons

private struct GiantTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 88, weight: .black))
            .fontWidth(.compressed)
            .tracking(-1.5)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
    }
}

private struct SubText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: 400)
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 30)
            .padding(.vertical, 11)
            .background(Capsule().fill(Color.primary))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// MARK: - Onboarding view (inspired by Dia: one screen, one message)

struct OnboardingView: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @StateObject private var scanner = BLEScanner()
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case welcome, account, pairing, prefs, system, done
    }

    @State private var step: Step = .welcome
    @State private var email = ""
    @State private var password = ""
    @State private var region = "auto"
    @State private var loginBusy = false
    @State private var loginError: String?
    @State private var sudoersBusy = false
    @State private var sudoersOK = AdminSetup.sudoersInstalled

    private var userId: String? { model.config["user_id"] as? String }
    private var deviceSN: String? { model.config["device_sn"] as? String }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            AuroraView()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                Spacer(minLength: 0)
                progressDots
                    .padding(.bottom, 22)
            }
            .padding(.horizontal, 40)
        }
        .frame(width: 760, height: 540)
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: step)
        .onChange(of: step) { _, newStep in
            if newStep == .pairing { scanner.start() } else { scanner.stop() }
        }
        .onAppear {
            // Resuming the wizard = start fresh, daemon suspended: while
            // connected it prevents the battery from advertising (scan impossible)
            model.stopDaemon()
            model.resetOnboardingConfig()
        }
        .onDisappear {
            scanner.stop()
            model.startDaemon()
        }
    }

    private var header: some View {
        HStack {
            if step != .welcome && step != .done {
                Button {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.top, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue
                          ? Color.primary.opacity(0.85)
                          : Color.primary.opacity(0.15))
                    .frame(width: s == step ? 24 : 12, height: 4)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .account: accountStep
        case .pairing: pairingStep
        case .prefs: prefsStep
        case .system: systemStep
        case .done: doneStep
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            GiantTitle(text: t("Hello."))
            SubText(text: t("Your EcoFlow battery, in the menu bar.\nReal time remaining, automatic Mac protection, 100% local over Bluetooth."))
            Button(t("Get started")) { step = .account }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 10)
            Picker("", selection: Binding(
                get: { (model.config["language"] as? String) ?? "auto" },
                set: { model.setConfig("language", $0) }
            )) {
                ForEach(L10n.choices, id: \.0) { code, name in
                    Text(code == "auto" ? t("Automatic (system)") : name).tag(code)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.top, 8)
        }
    }

    private var accountStep: some View {
        VStack(spacing: 18) {
            GiantTitle(text: t("Your account."))
            SubText(text: t("EcoFlow's Bluetooth requires the ID of the account linked to the battery. The password goes only to EcoFlow — never stored."))

            if userId != nil {
                Label(t("Account connected"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
                Button(t("Continue")) { step = .pairing }
                    .buttonStyle(PillButtonStyle())
            } else {
                VStack(spacing: 10) {
                    TextField("Email", text: $email)
                    SecureField(t("Password"), text: $password)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(width: 300)
                .background(.clear)
                .overlay(alignment: .center) { EmptyView() }
                .modifier(FieldCard())

                HStack(spacing: 14) {
                    Picker("", selection: $region) {
                        ForEach(EFLogin.regions, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Button {
                        login()
                    } label: {
                        if loginBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(t("Sign in"))
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(email.isEmpty || password.isEmpty || loginBusy)
                }

                if let loginError {
                    Text(t(loginError))
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Button(t("Later")) { step = .pairing }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func login() {
        loginBusy = true
        loginError = nil
        Task {
            do {
                let userId = try await EFLogin.login(email: email, password: password, region: region)
                model.setConfig("user_id", userId)
                password = ""
                step = .pairing
            } catch {
                loginError = error.localizedDescription
            }
            loginBusy = false
        }
    }

    private var pairingStep: some View {
        VStack(spacing: 16) {
            GiantTitle(text: t("In range."))

            if scanner.state == .unauthorized {
                SubText(text: t("Bluetooth access denied — allow EcoFlowBar in Privacy settings."))
                Button(t("Open Privacy → Bluetooth")) {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
                    )
                }
                .buttonStyle(PillButtonStyle())
            } else if scanner.devices.isEmpty {
                SubText(text: t("Turn on your battery and keep it nearby."))
                ProgressView().controlSize(.small).padding(.top, 4)
            } else {
                SubText(text: t("Choose the battery to monitor."))
                VStack(spacing: 8) {
                    ForEach(scanner.devices.prefix(3)) { device in
                        deviceCard(device)
                    }
                }
                .frame(width: 360)
            }

            if deviceSN != nil {
                Button(t("Continue")) { step = .prefs }
                    .buttonStyle(PillButtonStyle())
            } else {
                Button(t("Later")) { step = .prefs }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    private func deviceCard(_ device: BLEScanner.Found) -> some View {
        Button {
            // The daemon is suspended during the wizard: it will connect to
            // this device when it restarts, on close
            model.setConfig("device_sn", device.sn)
            model.setConfig("device_name", device.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "minus.plus.batteryblock")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 13, weight: .semibold))
                    Text("SN \(device.sn) · \(device.rssi) dBm")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: deviceSN == device.sn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(deviceSN == device.sn ? .green : .secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )
        }
        .buttonStyle(.plain)
    }

    private var prefsStep: some View {
        VStack(spacing: 18) {
            GiantTitle(text: t("Your rules."))
            SubText(text: t("What EcoFlowBar may do for you — everything remains adjustable in Settings."))

            VStack(spacing: 12) {
                onboardingToggle(t("Launch at login"), isOn: model.launchAtLogin)
                onboardingToggle(t("Notifications (source changes, low battery)"),
                                 isOn: model.bindBool("actions.notify", default: true))
                onboardingToggle(t("Automatic actions on the Mac (low power…)"),
                                 isOn: model.bindBool("actions_enabled", default: true))
                Divider()
                onboardingToggle(t("Limit the charge range (battery health)"),
                                 isOn: chargeRangeBinding)
                if chargeRangeBinding.wrappedValue {
                    rangeSlider(t("Min reserve"), binding: model.bindLimit("charge_limit_min", default: 10),
                                range: 0...30)
                    rangeSlider(t("Max charge"), binding: model.bindLimit("charge_limit_max", default: 85),
                                range: 50...100)
                }
            }
            .padding(16)
            .frame(width: 400)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )

            Button(t("Continue")) { step = .system }
                .buttonStyle(PillButtonStyle())
        }
    }

    private var chargeRangeBinding: Binding<Bool> {
        Binding(
            get: {
                model.limitValue("charge_limit_max") != nil
                    || model.limitValue("charge_limit_min") != nil
            },
            set: { on in
                model.setConfig("charge_limit_max", on ? 85 : NSNull())
                model.setConfig("charge_limit_min", on ? 10 : NSNull())
            }
        )
    }

    private func onboardingToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func rangeSlider(_ label: String, binding: Binding<Double>,
                             range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Slider(value: binding, in: range, step: 5)
            Text("\(Int(binding.wrappedValue)) %")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var systemStep: some View {
        VStack(spacing: 18) {
            GiantTitle(text: t("The Mac's keys."))
            SubText(text: t("To enable low power mode, clean shutdown and CPU measurement, macOS will ask once for your administrator password. Optional — display works without it."))

            HStack(spacing: 10) {
                Image(systemName: sudoersOK ? "checkmark.circle.fill" : "lock")
                    .font(.system(size: 16))
                    .foregroundStyle(sudoersOK ? .green : .secondary)
                Text(sudoersOK ? t("Permissions installed") : t("Permissions not installed"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if !sudoersOK {
                    Button {
                        sudoersBusy = true
                        Task {
                            sudoersOK = await AdminSetup.installSudoers()
                            sudoersBusy = false
                        }
                    } label: {
                        if sudoersBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(t("Install…")).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .disabled(sudoersBusy)
                }
            }
            .padding(14)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )

            Button(sudoersOK ? t("Continue") : t("Skip")) { step = .done }
                .buttonStyle(sudoersOK ? AnyButtonStyle(PillButtonStyle()) : AnyButtonStyle(GhostButtonStyle()))
        }
    }

    private var doneStep: some View {
        VStack(spacing: 22) {
            GiantTitle(text: t("All set."))
            SubText(text: t("The indicator now lives in your menu bar, updated over Bluetooth, no Internet needed. All adjustments are in Settings."))
            Button(t("Finish")) { dismiss() }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 10)
        }
    }
}

// Hot-swappable button style (Continue/Skip depending on state)
private struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}

// Translucent card for the sign-in fields
private struct FieldCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            )
    }
}
