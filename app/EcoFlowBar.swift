// EcoFlowBar — EcoFlow battery panel in the menu bar, "Stats" style.
// Reads state.json (written by the ef_monitor.py daemon) and drives config.json.
import AppKit
import Charts
import SwiftUI

// MARK: - Daemon supervisor (the daemon lives and dies with the app)

// The daemon is no longer a LaunchAgent: the app launches it as a child
// process, restarts it if it dies, and stops it on quit. If the app crashes,
// the daemon detects EOF on its stdin (a pipe held by the app) and stops.
final class DaemonSupervisor {
    static let shared = DaemonSupervisor()

    private var process: Process?
    private var shouldRun = false
    private var spawnDate = Date.distantPast
    private var rapidFailures = 0
    private let queue = DispatchQueue(label: "fr.koa.ecoflow-bar.daemon")

    private var projectDir: URL {
        URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
    }

    func ensureRunning() {
        queue.async {
            self.shouldRun = true
            if self.process?.isRunning != true { self.spawn() }
        }
    }

    func stop() {
        queue.async {
            self.shouldRun = false
            self.process?.terminate()
            self.process = nil
        }
    }

    /// Synchronous stop for applicationWillTerminate
    func stopSync() {
        queue.sync {
            self.shouldRun = false
            self.process?.terminate()
            self.process = nil
        }
    }

    func restart() {
        queue.async {
            self.shouldRun = true
            if let process = self.process, process.isRunning {
                process.terminate()  // the terminationHandler restarts it (shouldRun)
            } else {
                self.spawn()
            }
        }
    }

    // Two layouts: development (project folder + venv) or distributed app
    // (daemon bundled in Resources/daemon, venv bootstrapped in Application
    // Support from the bundled wheels)
    private func daemonInvocation() -> (URL, [String])? {
        let devPython = projectDir.appendingPathComponent(".venv/bin/python")
        let devScript = projectDir.appendingPathComponent("scripts/ef_monitor.py")
        if FileManager.default.isExecutableFile(atPath: devPython.path),
           FileManager.default.fileExists(atPath: devScript.path) {
            return (devPython, [devScript.path])
        }
        if let resources = Bundle.main.resourceURL {
            let runner = resources.appendingPathComponent("daemon/run.sh")
            if FileManager.default.fileExists(atPath: runner.path) {
                return (URL(fileURLWithPath: "/bin/bash"), [runner.path])
            }
        }
        return nil
    }

    private func spawn() {
        guard let (executable, arguments) = daemonInvocation() else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["EF_SUPERVISED"] = "1"
        process.environment = environment
        // Pipe never written to: its closing (app dies, even by crash)
        // signals the daemon to stop
        process.standardInput = Pipe()
        if let log = Self.appendingLogHandle() {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // Exponential backoff if the daemon dies right after launch
                // (e.g. Bluetooth permission denied): 2, 4, 8… 60 s max
                if Date().timeIntervalSince(self.spawnDate) < 10 {
                    self.rapidFailures += 1
                } else {
                    self.rapidFailures = 0
                }
                let delay = min(60.0, 2.0 * pow(2.0, Double(self.rapidFailures)))
                self.queue.asyncAfter(deadline: .now() + delay) {
                    if self.shouldRun, self.process?.isRunning != true { self.spawn() }
                }
            }
        }
        do {
            try process.run()
            spawnDate = Date()
            self.process = process
        } catch {
            NSLog("EcoFlowBar: could not launch the daemon: \(error)")
        }
    }

    private static func appendingLogHandle() -> FileHandle? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ecoflow-monitor.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        DaemonSupervisor.shared.stopSync()
    }
}

// MARK: - Model

struct EFState {
    var status = "missing"
    var ts: Double = 0
    var device = "EcoFlow"
    var level: Double?
    var mode = "idle"
    var onEcoflow = false
    var remainingDischarge: Int?
    var remainingCharge: Int?
    var inputSum: Double?
    var acInput: Double?
    var acOutput: Double?
    var usbcOutput: Double?
    var temperature: Double?
    var macCpuWatts: Double?
    var acPorts = false
    var chargeLimitMax: Double?
    var chargeLimitMin: Double?
    var levelEffective: Double?

    // % shown everywhere: the usable window if limits are active
    var displayLevel: Double { levelEffective ?? level ?? 0 }
    var hasLimitWindow: Bool {
        (chargeLimitMin ?? 0) > 0 || (chargeLimitMax ?? 100) < 100
    }

    var isStale: Bool { Date().timeIntervalSince1970 - ts > 60 }
    var isConnected: Bool { status == "connected" && !isStale }
}

struct Sample: Identifiable {
    let ts: Double
    let level: Double
    let charging: Bool
    let macWatts: Double?
    let cpuWatts: Double?
    let inW: Double
    let outW: Double
    var id: Double { ts }
    var date: Date { Date(timeIntervalSince1970: ts) }
}

final class Model: ObservableObject {
    @Published var state = EFState()
    @Published var config: [String: Any] = [:]
    @Published var history: [Sample] = []

    static let appDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ecoflow-monitor")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ecoflow-monitor.log")

    private var timer: Timer?

    init() {
        reload()
        // App launched ⇒ daemon guaranteed (except onboarding, which suspends it)
        if !needsOnboarding {
            DaemonSupervisor.shared.ensureRunning()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    // Effective language: the "language" setting (auto/fr/en), otherwise the system's
    var language: String { resolveLanguage(config["language"] as? String) }

    func t(_ key: String) -> String { L10n.text(key, lang: language) }

    func reload() {
        state = Self.readState()
        config = Self.readJSON(Self.appDir.appendingPathComponent("config.json")) ?? [:]
        history = Self.readHistory()
    }

    private static func readHistory() -> [Sample] {
        let url = appDir.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { item in
            guard let ts = item["ts"] as? Double, let level = item["level"] as? Double
            else { return nil }
            return Sample(
                ts: ts,
                level: level,
                charging: item["mode"] as? String == "charging",
                macWatts: item["mac_w"] as? Double,
                cpuWatts: item["cpu_w"] as? Double,
                inW: item["in_w"] as? Double ?? 0,
                outW: item["out_w"] as? Double ?? 0
            )
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readState() -> EFState {
        guard let json = readJSON(appDir.appendingPathComponent("state.json")) else {
            return EFState()
        }
        var s = EFState()
        s.status = json["status"] as? String ?? "unknown"
        s.ts = (json["ts"] as? Double) ?? 0
        s.device = json["device"] as? String ?? "EcoFlow"
        s.level = json["battery_level"] as? Double
        s.mode = json["power_mode"] as? String ?? "idle"
        s.onEcoflow = json["mac_on_ecoflow"] as? Bool ?? false
        // Effective runtime (corrected for the discharge limit) takes priority
        s.remainingDischarge = json["remaining_time_discharging_effective"] as? Int
            ?? json["remaining_time_discharging"] as? Int
        s.remainingCharge = json["remaining_time_charging"] as? Int
        s.inputSum = json["input_power"] as? Double
        s.acInput = json["ac_input_power"] as? Double
        s.acOutput = json["ac_output_power"] as? Double
        s.usbcOutput = json["usbc_output_power"] as? Double
        s.temperature = json["cell_temperature"] as? Double
        s.macCpuWatts = json["mac_cpu_w"] as? Double
        s.acPorts = json["ac_ports"] as? Bool ?? false
        s.chargeLimitMax = json["battery_charge_limit_max"] as? Double
        s.chargeLimitMin = json["battery_charge_limit_min"] as? Double
        s.levelEffective = json["battery_level_effective"] as? Double
        return s
    }

    // Writes a value to config.json (the daemon hot-reloads via mtime)
    func setConfig(_ dottedKey: String, _ value: Any) {
        let url = Self.appDir.appendingPathComponent("config.json")
        var root = Self.readJSON(url) ?? [:]
        let parts = dottedKey.split(separator: ".").map(String.init)
        if parts.count == 1 {
            root[parts[0]] = value
        } else {
            var child = root[parts[0]] as? [String: Any] ?? [:]
            child[parts[1]] = value
            // Hysteresis safeguard (same rule as ef_config.py)
            if parts[0] == "thresholds",
               let low = child["lowpower"] as? Int {
                let restore = child["restore"] as? Int ?? 15
                if restore < low + 3 { child["restore"] = low + 3 }
            }
            root[parts[0]] = child
        }
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        reload()
    }

    func configBool(_ dottedKey: String, default def: Bool = true) -> Bool {
        let parts = dottedKey.split(separator: ".").map(String.init)
        if parts.count == 1 { return config[parts[0]] as? Bool ?? def }
        let child = config[parts[0]] as? [String: Any]
        return child?[parts[1]] as? Bool ?? def
    }

    // Drops a one-shot command executed by the daemon (command.json)
    func sendCommand(_ action: String, value: Any) {
        let url = Self.appDir.appendingPathComponent("command.json")
        let payload: [String: Any] = [
            "action": action,
            "value": value,
            "ts": Date().timeIntervalSince1970,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: url)
        }
    }

    // Today's energy (Wh) integrated from history (1/min samples)
    func energyToday() -> (inWh: Double, outWh: Double) {
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let today = history.filter { $0.ts >= midnight }
        return (
            today.reduce(0) { $0 + $1.inW / 60 },
            today.reduce(0) { $0 + $1.outW / 60 }
        )
    }

    func threshold(_ key: String, default def: Int) -> Int {
        let child = config["thresholds"] as? [String: Any]
        if let v = child?[key] as? Int { return v }
        if let v = child?[key] as? Double { return Int(v) }
        return def
    }

    // MARK: Bindings for the settings window

    func bindBool(_ dottedKey: String, default def: Bool) -> Binding<Bool> {
        Binding(
            get: { self.configBool(dottedKey, default: def) },
            set: { self.setConfig(dottedKey, $0) }
        )
    }

    func bindThreshold(_ key: String, default def: Int) -> Binding<Double> {
        Binding(
            get: { Double(self.threshold(key, default: def)) },
            set: { self.setConfig("thresholds.\(key)", Int($0.rounded())) }
        )
    }

    func bindNumber(_ key: String, default def: Double) -> Binding<Double> {
        Binding(
            get: {
                if let v = self.config[key] as? Double { return v }
                if let v = self.config[key] as? Int { return Double(v) }
                return def
            },
            set: { self.setConfig(key, Int($0.rounded())) }
        )
    }

    // Optional limits (None = not managed)
    func limitValue(_ key: String) -> Int? {
        if let v = self.config[key] as? Int { return v }
        if let v = self.config[key] as? Double { return Int(v) }
        return nil
    }

    func bindLimitEnabled(_ key: String, defaultWhenOn: Int) -> Binding<Bool> {
        Binding(
            get: { self.limitValue(key) != nil },
            set: { self.setConfig(key, $0 ? defaultWhenOn : NSNull()) }
        )
    }

    func bindLimit(_ key: String, default def: Int) -> Binding<Double> {
        Binding(
            get: { Double(self.limitValue(key) ?? def) },
            set: { self.setConfig(key, Int($0.rounded())) }
        )
    }

    // MARK: Launch at login (LaunchAgent fr.koa.ecoflow-bar)

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.koa.ecoflow-bar.plist")
    }

    var launchAtLogin: Binding<Bool> {
        Binding(
            get: { FileManager.default.fileExists(atPath: self.launchAgentURL.path) },
            set: { self.setLaunchAtLogin($0) }
        )
    }

    private func setLaunchAtLogin(_ on: Bool) {
        if !on {
            // Removing the plist is enough: the current instance keeps running
            try? FileManager.default.removeItem(at: launchAgentURL)
        } else {
            let exec = URL(fileURLWithPath: Bundle.main.bundlePath)
                .appendingPathComponent("Contents/MacOS/EcoFlowBar").path
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>fr.koa.ecoflow-bar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(exec)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <dict>
                    <key>SuccessfulExit</key>
                    <false/>
                </dict>
            </dict>
            </plist>
            """
            try? plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["bootstrap", "gui/\(getuid())", launchAgentURL.path]
            try? process.run()
        }
        reload()
    }

    // Onboarding needed as long as account and battery are not configured
    var needsOnboarding: Bool {
        let userId = config["user_id"] as? String
        let sn = config["device_sn"] as? String
        return (userId ?? "").isEmpty || (sn ?? "").isEmpty
    }

    func restartDaemon() {
        DaemonSupervisor.shared.restart()
    }

    // The daemon monopolizes the BLE connection: while it is connected, the
    // battery stops advertising and the pairing scan cannot see it.
    // Onboarding therefore suspends it, then restarts it when leaving.
    func stopDaemon() {
        DaemonSupervisor.shared.stop()
    }

    func startDaemon() {
        DaemonSupervisor.shared.ensureRunning()
    }

    // Starts fresh for the wizard: account and device forgotten
    func resetOnboardingConfig() {
        setConfig("user_id", NSNull())
        setConfig("device_sn", NSNull())
        setConfig("device_name", NSNull())
    }

    // Resets then relaunches the app: on restart, needsOnboarding triggers
    // the full sequence (full-screen intro → wizard)
    func resetAndRestartApp() {
        resetOnboardingConfig()
        stopDaemon()
        // With no leftover state, the relaunch immediately sees "not configured"
        try? FileManager.default.removeItem(
            at: Self.appDir.appendingPathComponent("state.json")
        )
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.8; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? relaunch.run()  // survives the app's exit (re-parented)
        NSApplication.shared.terminate(nil)
    }

    private func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Display helpers

func fmtWatts(_ value: Double?) -> String {
    guard let value else { return "—" }
    return "\(Int(value.rounded())) W"
}

func fmtMinutes(_ minutes: Int?) -> String? {
    guard let minutes, minutes > 0 else { return nil }
    return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
}

func levelColor(_ level: Double, discharging: Bool) -> Color {
    if discharging && level <= 10 { return .red }
    if discharging && level <= 20 { return .orange }
    return Color(red: 0.3, green: 0.75, blue: 0.4)
}

// MARK: - Components

struct HeroRing: View {
    let level: Double
    let color: Color
    let badgeSymbol: String
    let badgeColor: Color
    let capsuleText: String?

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.06))
            Circle()
                .inset(by: 10)
                .stroke(Color.primary.opacity(0.10), lineWidth: 9)
            Circle()
                .inset(by: 10)
                .trim(from: 0, to: max(0.02, min(1, level / 100)))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.45), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * level / 100)
                    ),
                    style: StrokeStyle(lineWidth: 9, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(level))%")
                .font(.system(size: 27, weight: .bold, design: .rounded))
        }
        .frame(width: 136, height: 136)
        .overlay(alignment: .topTrailing) {
            Image(systemName: badgeSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(badgeColor)
                .frame(width: 25, height: 25)
                .background(Circle().fill(.thickMaterial))
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .offset(x: -6, y: 2)
        }
        .overlay(alignment: .bottom) {
            if let capsuleText {
                Text(capsuleText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.thickMaterial))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .offset(y: 7)
            }
        }
        .padding(.bottom, 6)
    }
}

struct Row: View {
    let dot: Color?
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            }
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Combined battery + power draw chart

struct HistoryChart: View {
    let samples: [Sample]
    var t: (String) -> String = { $0 }
    @AppStorage("historyWindowHours") private var windowHours = 6

    private static let battColor = Color(red: 0.3, green: 0.75, blue: 0.4)
    private static let consoColor = Color.orange
    private static let cpuColor = Color.pink

    private var windowed: [Sample] {
        let cutoff = Date().timeIntervalSince1970 - Double(windowHours) * 3600
        return samples.filter { $0.ts >= cutoff }
    }

    // W scale (right axis): power draw mapped to the chart's 0-100 domain
    private var maxWatts: Double {
        let peak = windowed.compactMap { max($0.macWatts ?? 0, $0.cpuWatts ?? 0) }.max() ?? 0
        return max(30, peak * 1.2)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                SectionHeader(title: "\(t("History")) — \(windowHours) h")
                Picker("", selection: $windowHours) {
                    Text("1 h").tag(1)
                    Text("6 h").tag(6)
                    Text("24 h").tag(24)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 110)
            }
            if windowed.count < 2 {
                Text(t("Collecting history…"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            } else {
                chart
                legend
            }
        }
    }

    private var chart: some View {
        let maxW = maxWatts
        return Chart {
            ForEach(windowed) { sample in
                AreaMark(
                    x: .value("Heure", sample.date),
                    y: .value("Batterie", sample.level),
                    series: .value("Série", "batterie")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Self.battColor.opacity(0.25), Self.battColor.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Heure", sample.date),
                    y: .value("Batterie", sample.level),
                    series: .value("Série", "batterie")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Self.battColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))

                if let watts = sample.macWatts {
                    LineMark(
                        x: .value("Heure", sample.date),
                        y: .value("Conso", watts / maxW * 100),
                        series: .value("Série", "conso")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Self.consoColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                if let cpu = sample.cpuWatts {
                    LineMark(
                        x: .value("Heure", sample.date),
                        y: .value("CPU", cpu / maxW * 100),
                        series: .value("Série", "cpu")
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Self.cpuColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 2]))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v)) %").font(.system(size: 8))
                            .foregroundStyle(Self.battColor)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v / 100 * maxW)) W").font(.system(size: 8))
                            .foregroundStyle(Self.consoColor)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 8))
            }
        }
        .frame(height: 78)
    }

    private var legend: some View {
        let conso = windowed.compactMap(\.macWatts)
        let cpu = windowed.compactMap(\.cpuWatts)
        return HStack(spacing: 10) {
            legendItem(Self.battColor, "Batterie")
            if !conso.isEmpty {
                legendItem(Self.consoColor,
                           "\(t("Load avg.")) \(Int((conso.reduce(0, +) / Double(conso.count)).rounded())) W")
            }
            if !cpu.isEmpty {
                legendItem(Self.cpuColor,
                           String(format: t("CPU avg.") + " %.1f W", cpu.reduce(0, +) / Double(cpu.count)))
            }
            Spacer()
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @State private var confirmHibernate = false
    @State private var confirmAcOff = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            if model.state.isConnected {
                connectedBody
            } else {
                disconnectedBody
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    // Scripts directory: project (dev) or Resources/daemon (distributed app)
    private var scriptsDir: URL? {
        let dev = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scripts")
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent("ef_hibernate.sh").path) {
            return dev
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("daemon/scripts"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("ef_hibernate.sh").path) {
            return bundled
        }
        return nil
    }

    // The post-hibernation restore agent must point to the current script —
    // essential for the distributed app (no setup.sh)
    private func ensureRestoreAgent(scriptsDir: URL) {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.koa.ecoflow-restore.plist")
        let restore = scriptsDir.appendingPathComponent("ef_restore.sh").path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>fr.koa.ecoflow-restore</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(restore)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    private func hibernate() {
        guard let scriptsDir else { return }
        ensureRestoreAgent(scriptsDir: scriptsDir)
        let script = scriptsDir.appendingPathComponent("ef_hibernate.sh")
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ecoflow-hibernate.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Script output logged so a failure can be diagnosed
        process.arguments = ["-c", "exec /bin/bash \"$1\" >> \"$2\" 2>&1", "--", script.path, log.path]
        do {
            try process.run()
        } catch {
            try? "could not launch: \(error)\n".write(to: log, atomically: true, encoding: .utf8)
        }
    }

    @ViewBuilder private var connectedBody: some View {
        let s = model.state
        let level = s.displayLevel
        let discharging = s.mode == "discharging"

        HeroRing(
            level: level,
            color: levelColor(level, discharging: discharging),
            badgeSymbol: heroBadge(s.mode).0,
            badgeColor: heroBadge(s.mode).1,
            capsuleText: heroCapsule(s)
        )
        .padding(.top, 2)

        HistoryChart(samples: model.history, t: model.t)

        VStack(spacing: 6) {
            SectionHeader(title: s.device)
            if s.mode == "discharging", let remaining = fmtMinutes(s.remainingDischarge) {
                Row(dot: .green, label: t("Time remaining"), value: remaining)
            }
            if s.mode == "charging", let remaining = fmtMinutes(s.remainingCharge) {
                Row(dot: .yellow, label: t("Full charge in"), value: remaining)
            }
            Row(
                dot: s.onEcoflow ? .blue : .gray,
                label: t("Mac on EcoFlow"),
                value: s.onEcoflow ? "oui" : "non"
            )
            Row(
                dot: statusDot(s.mode),
                label: t("State"),
                value: [
                    "charging": t("state.charging"),
                    "discharging": t("state.discharging"),
                    "plugged": t("state.plugged"),
                ][s.mode] ?? t("state.idle")
            )
            if s.hasLimitWindow, let raw = s.level {
                Row(
                    dot: .gray,
                    label: t("Raw level"),
                    value: "\(Int(raw)) % · \(t("window")) \(Int(s.chargeLimitMin ?? 0))–\(Int(s.chargeLimitMax ?? 100)) %"
                )
            }
        }

        VStack(spacing: 6) {
            SectionHeader(title: t("Power flow"))
            Row(dot: .yellow, label: t("Input"), value: fmtWatts(s.inputSum))
            acRow(s)
            Row(dot: .purple, label: t("USB-C output"), value: fmtWatts(s.usbcOutput))
            if let cpu = s.macCpuWatts {
                Row(dot: .pink, label: t("Mac CPU (internal)"), value: String(format: "%.1f W", cpu))
            }
            if let temp = s.temperature {
                Row(dot: .orange, label: t("Temperature"), value: "\(Int(temp)) °C")
            }
            energyRow
        }
    }

    // AC output row with a switch (command executed by the daemon)
    @ViewBuilder private func acRow(_ s: EFState) -> some View {
        if confirmAcOff {
            HStack(spacing: 7) {
                Text(t("Cut the Mac's power?"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(t("Cut power")) {
                    confirmAcOff = false
                    model.sendCommand("set_ac", value: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.mini)
                Button(t("Cancel")) { confirmAcOff = false }
                    .controlSize(.mini)
            }
        } else {
            HStack(spacing: 7) {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                Text(t("AC output")).font(.system(size: 12))
                Button {
                    if s.acPorts && s.onEcoflow {
                        confirmAcOff = true
                    } else {
                        model.sendCommand("set_ac", value: !s.acPorts)
                    }
                } label: {
                    Image(systemName: s.acPorts ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(s.acPorts ? Color.blue : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(s.acPorts ? t("Turn off AC output") : t("Turn on AC output"))
                Spacer()
                Text(fmtWatts(s.acOutput))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
        }
    }

    private var energyRow: some View {
        let energy = model.energyToday()
        return Row(
            dot: .teal,
            label: t("Energy today"),
            value: "↓ \(Int(energy.inWh)) Wh · ↑ \(Int(energy.outWh)) Wh"
        )
    }

    private func heroBadge(_ mode: String) -> (String, Color) {
        switch mode {
        case "charging": return ("bolt.fill", .yellow)
        case "discharging": return ("battery.100percent", .green)
        case "plugged": return ("powerplug.fill", .blue)
        default: return ("pause.fill", .gray)
        }
    }

    private func heroCapsule(_ s: EFState) -> String? {
        switch s.mode {
        case "discharging":
            return fmtMinutes(s.remainingDischarge)
        case "charging":
            if let remaining = fmtMinutes(s.remainingCharge) {
                return "\(t("full in")) \(remaining)"
            }
            return t("state.charging")
        case "plugged":
            return t("state.plugged")
        default:
            return nil
        }
    }

    private func statusDot(_ mode: String) -> Color {
        switch mode {
        case "charging": return .yellow
        case "discharging": return .green
        case "plugged": return .blue
        default: return .gray
        }
    }

    @ViewBuilder private var disconnectedBody: some View {
        let message: String = {
            if model.state.isStale { return t("Daemon unreachable — see log") }
            switch model.state.status {
            case "searching": return t("Bluetooth search…")
            case "offline": return t("EcoFlow out of range or off")
            case "unconfigured": return t("Not configured")
            case "bluetooth_denied": return t("Bluetooth denied — Settings → Privacy → Bluetooth")
            default: return t("Waiting for daemon…")
            }
        }()
        VStack(spacing: 8) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    @ViewBuilder private var footer: some View {
        if confirmHibernate {
            VStack(spacing: 8) {
                Text(t("Save the session and shut down the Mac?"))
                    .font(.system(size: 11, weight: .semibold))
                Text(t("Apps, tabs and tmux will be restored on next startup."))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(t("Cancel")) { confirmHibernate = false }
                        .controlSize(.small)
                    Spacer()
                    Button(t("Shut down")) {
                        confirmHibernate = false
                        hibernate()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
            }
        } else {
            footerControls
        }
    }

    @ViewBuilder private var footerControls: some View {
        Toggle(isOn: Binding(
            get: { model.configBool("actions_enabled") },
            set: { model.setConfig("actions_enabled", $0) }
        )) {
            Text(t("Automatic actions on the Mac")).font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        HStack {
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label(t("Settings"), systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Spacer()
            Button {
                confirmHibernate = true
            } label: {
                Image(systemName: "moon.zzz")
            }
            .buttonStyle(.borderless)
            .help(t("Hibernate: save session and shut down"))
            Button {
                NSWorkspace.shared.open(Model.logURL)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help(t("Daemon log"))
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(t("Quit EcoFlowBar"))
        }
    }

}

// MARK: - Settings window (sidebar + cards, modern app style)

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, account, protection, battery, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .account: return "Account"
        case .protection: return "Protection"
        case .battery: return "Battery"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .account: return "person.fill"
        case .protection: return "shield.fill"
        case .battery: return "battery.75percent"
        case .advanced: return "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(red: 0.55, green: 0.57, blue: 0.62)
        case .account: return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .protection: return Color(red: 0.30, green: 0.72, blue: 0.42)
        case .battery: return Color(red: 0.95, green: 0.60, blue: 0.20)
        case .advanced: return Color(red: 0.62, green: 0.45, blue: 0.90)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @State private var section: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(t(section.title))
                        .font(.system(size: 22, weight: .bold))
                    Group {
                        switch section {
                        case .general: GeneralPane(model: model)
                        case .account: AccountPane(model: model)
                        case .protection: ProtectionPane(model: model)
                        case .battery: BatteryPane(model: model)
                        case .advanced: AdvancedPane(model: model)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
        }
        .frame(width: 680, height: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("EcoFlowBar")
                    .font(.system(size: 13, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ForEach(SettingsSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 6.5)
                            .fill(item.color.gradient)
                            .frame(width: 25, height: 25)
                            .overlay(
                                Image(systemName: item.icon)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                        Text(t(item.title))
                            .font(.system(size: 13,
                                          weight: section == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(section == item ? Color.primary.opacity(0.09) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .frame(width: 172)
        .background(.regularMaterial)
    }
}

// MARK: Settings components

struct SettingsCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, footnote: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.05))
            )
            if let footnote {
                Text(footnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

struct ToggleRow: View {
    let label: String
    var subtitle: String?
    let isOn: Binding<Bool>

    init(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.subtitle = subtitle
        self.isOn = isOn
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.vertical, 9)
    }
}

struct SlideRow: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = "%"

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 13))
                .frame(width: 165, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text("\(Int(value.wrappedValue)) \(unit)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

struct ActionRow: View {
    let label: String
    var subtitle: String?
    let buttonTitle: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if destructive {
                Button(buttonTitle, role: .destructive, action: action)
                    .controlSize(.small)
            } else {
                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 9)
    }
}

// MARK: Sections

struct GeneralPane: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @AppStorage(MenuBarPrefs.icon) private var showIcon = true
    @AppStorage(MenuBarPrefs.percent) private var showPercent = true
    @AppStorage(MenuBarPrefs.time) private var showTime = true
    @AppStorage(MenuBarPrefs.watts) private var showWatts = false

    var body: some View {
        SettingsCard(title: t("Behavior")) {
            ToggleRow(t("Automatic actions on the Mac"),
                      subtitle: t("Master switch: low power, shutdown, alerts"),
                      isOn: model.bindBool("actions_enabled", default: true))
            Divider()
            ToggleRow("Notifications",
                      subtitle: t("Power source changes, low battery, temperature"),
                      isOn: model.bindBool("actions.notify", default: true))
            Divider()
            ToggleRow(t("Launch at login"), isOn: model.launchAtLogin)
        }
        SettingsCard(title: t("Menu bar"),
                     footnote: t("Everything unchecked: the icon alone remains.")) {
            ToggleRow(t("Battery icon"), isOn: $showIcon)
            Divider()
            ToggleRow(t("Percentage"), isOn: $showPercent)
            Divider()
            ToggleRow(t("Time remaining"), isOn: $showTime)
            Divider()
            ToggleRow(t("Power draw"), isOn: $showWatts)
        }
        SettingsCard(title: t("Language")) {
            HStack {
                Text(t("Language")).font(.system(size: 13))
                Spacer()
                Picker("", selection: languageBinding) {
                    ForEach(L10n.choices, id: \.0) { code, name in
                        Text(code == "auto" ? t("Automatic (system)") : name).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.vertical, 9)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { (model.config["language"] as? String) ?? "auto" },
            set: { model.setConfig("language", $0) }
        )
    }
}

struct AccountPane: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @StateObject private var scanner = BLEScanner()

    @State private var editingAccount = false
    @State private var email = ""
    @State private var password = ""
    @State private var region = "auto"
    @State private var loginBusy = false
    @State private var loginError: String?
    @State private var scanning = false

    private var userId: String? {
        (model.config["user_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private var deviceSN: String? { model.config["device_sn"] as? String }
    private var deviceName: String? { model.config["device_name"] as? String }

    var body: some View {
        SettingsCard(title: t("EcoFlow account"),
                     footnote: t("Password sent only to EcoFlow, never stored.")) {
            if editingAccount {
                VStack(spacing: 8) {
                    TextField("Email", text: $email).textFieldStyle(.roundedBorder)
                    SecureField(t("Password"), text: $password).textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("", selection: $region) {
                            ForEach(EFLogin.regions, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        Spacer()
                        Button(t("Cancel")) {
                            editingAccount = false
                            password = ""
                            loginError = nil
                        }
                        .controlSize(.small)
                        Button {
                            login()
                        } label: {
                            if loginBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(t("Sign in"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(email.isEmpty || password.isEmpty || loginBusy)
                    }
                    if let loginError {
                        Text(t(loginError)).font(.system(size: 11)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 10)
            } else {
                ActionRow(label: t("Status"),
                          subtitle: userId != nil ? t("Connected") : t("Not signed in"),
                          buttonTitle: userId != nil ? t("Change account…") : t("Sign in…")) {
                    editingAccount = true
                }
            }
        }

        SettingsCard(title: t("Bluetooth pairing")) {
            InfoRow(label: t("Current battery"),
                    value: deviceSN.map { "\(deviceName ?? "EcoFlow") · \($0)" } ?? t("none"))
            Divider()
            if scanning {
                if scanner.state == .unauthorized {
                    Label(t("Bluetooth denied — Settings → Privacy → Bluetooth"),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(.vertical, 9)
                } else if scanner.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(t("Searching… is the battery on and nearby?"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                }
                ForEach(scanner.devices) { device in
                    ActionRow(label: device.name,
                              subtitle: "SN \(device.sn) · \(device.rssi) dBm",
                              buttonTitle: deviceSN == device.sn ? t("✓ Current") : t("Select")) {
                        model.setConfig("device_sn", device.sn)
                        model.setConfig("device_name", device.name)
                        model.restartDaemon()
                        scanner.stop()
                        scanning = false
                    }
                    Divider()
                }
                ActionRow(label: t("Searching"), buttonTitle: t("Stop")) {
                    scanner.stop()
                    scanning = false
                }
            } else {
                ActionRow(label: t("Change battery"),
                          subtitle: t("The daemon releases Bluetooth during the search"),
                          buttonTitle: t("Search…")) {
                    scanning = true
                    model.stopDaemon()
                    scanner.start()
                }
            }
        }
        .onDisappear {
            scanner.stop()
            if scanning { model.startDaemon() }
            scanning = false
        }
    }

    private func login() {
        loginBusy = true
        loginError = nil
        Task {
            do {
                let newUserId = try await EFLogin.login(email: email, password: password, region: region)
                model.setConfig("user_id", newUserId)
                model.restartDaemon()
                password = ""
                editingAccount = false
            } catch {
                loginError = error.localizedDescription
            }
            loginBusy = false
        }
    }
}

struct ProtectionPane: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }

    var body: some View {
        SettingsCard(title: t("Thresholds"),
                     footnote: t("As effective % of the usable window. Return-to-normal stays above the low power threshold (hysteresis).")) {
            SlideRow(label: "Notification", value: model.bindThreshold("notify", default: 20),
                     range: 5...50)
            Divider()
            SlideRow(label: t("Low power"), value: model.bindThreshold("lowpower", default: 10),
                     range: 5...30)
            Divider()
            SlideRow(label: t("Shutdown"), value: model.bindThreshold("shutdown", default: 5),
                     range: 1...15)
            Divider()
            SlideRow(label: t("Return to normal"), value: model.bindThreshold("restore", default: 15),
                     range: 10...45)
        }
        SettingsCard(title: "Options") {
            ToggleRow(t("Automatic low power"),
                      subtitle: t("Throttles the Mac below the threshold, via pmset"),
                      isOn: model.bindBool("actions.lowpower", default: true))
            Divider()
            ToggleRow(t("Low power as soon as on battery"),
                      subtitle: t("Without waiting for the threshold, as soon as AC is lost"),
                      isOn: model.bindBool("actions.lowpower_on_battery", default: false))
            Divider()
            ToggleRow(t("Automatic shutdown"),
                      subtitle: t("Pseudo-hibernation at critical level"),
                      isOn: model.bindBool("actions.shutdown", default: false))
            Divider()
            ToggleRow(t("Only when the Mac is on the EcoFlow"),
                      subtitle: t("Detected via AC output watts"),
                      isOn: model.bindBool("require_mac_on_ecoflow", default: true))
        }
    }
}

struct BatteryPane: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }

    var body: some View {
        SettingsCard(title: t("State"),
                     footnote: t("Displayed % and time remaining are relative to the usable window.")) {
            InfoRow(label: t("Raw level"),
                    value: model.state.level.map { "\(Int($0)) %" } ?? "—")
            Divider()
            InfoRow(label: t("Applied window"),
                    value: "\(Int(model.state.chargeLimitMin ?? 0)) – \(Int(model.state.chargeLimitMax ?? 100)) %")
        }
        SettingsCard(title: t("Charge limit"),
                     footnote: t("80-85% daily extends LFP cell lifespan.")) {
            ToggleRow(t("Manage the charge limit"),
                      isOn: model.bindLimitEnabled("charge_limit_max", defaultWhenOn: 85))
            if model.limitValue("charge_limit_max") != nil {
                Divider()
                SlideRow(label: t("Charge up to"),
                         value: model.bindLimit("charge_limit_max", default: 85),
                         range: 50...100, step: 5)
            }
        }
        SettingsCard(title: t("Discharge reserve"),
                     footnote: t("A reserve avoids deep discharge and keeps an emergency margin.")) {
            ToggleRow(t("Manage the discharge limit"),
                      isOn: model.bindLimitEnabled("charge_limit_min", defaultWhenOn: 10))
            if model.limitValue("charge_limit_min") != nil {
                Divider()
                SlideRow(label: t("Minimum reserve"),
                         value: model.bindLimit("charge_limit_min", default: 10),
                         range: 0...30, step: 5)
            }
        }
    }
}

struct AdvancedPane: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @State private var confirmReset = false

    var body: some View {
        SettingsCard(title: t("Measurement")) {
            SlideRow(label: t("Refresh interval"), value: model.bindNumber("poll_seconds", default: 3),
                     range: 2...15, unit: "s")
            Divider()
            SlideRow(label: t("\"Mac plugged\" threshold"), value: model.bindNumber("mac_watts_min", default: 5),
                     range: 3...30, unit: "W")
            Divider()
            SlideRow(label: t("Shutdown warning delay"),
                     value: model.bindNumber("shutdown_grace_seconds", default: 60),
                     range: 15...300, step: 15, unit: "s")
        }
        SettingsCard(title: "Maintenance") {
            ActionRow(label: t("Daemon log"), buttonTitle: t("Open")) {
                NSWorkspace.shared.open(Model.logURL)
            }
            Divider()
            ActionRow(label: t("Configuration file"), buttonTitle: t("Open")) {
                NSWorkspace.shared.open(Model.appDir.appendingPathComponent("config.json"))
            }
            Divider()
            ActionRow(label: t("Monitoring daemon"), buttonTitle: t("Restart")) {
                model.restartDaemon()
            }
        }
        SettingsCard(title: t("Danger zone")) {
            ActionRow(label: t("Reset the app"),
                      subtitle: t("Clears account and pairing, replays the full setup"),
                      buttonTitle: t("Reset…"),
                      destructive: true) {
                confirmReset = true
            }
        }
        .alert(t("Reset EcoFlowBar?"), isPresented: $confirmReset) {
            Button(t("Reset and relaunch"), role: .destructive) {
                model.resetAndRestartApp()
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("The EcoFlow account and pairing will be erased, then the app will relaunch the full setup."))
        }
    }
}

// MARK: - Menu bar label

// Label display preferences (Settings → Menu bar)
enum MenuBarPrefs {
    static let icon = "mbShowIcon"
    static let percent = "mbShowPercent"
    static let time = "mbShowTime"
    static let watts = "mbShowWatts"
}

struct MenuLabel: View {
    @ObservedObject var model: Model
    private var t: (String) -> String { model.t }
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MenuBarPrefs.icon) private var showIcon = true
    @AppStorage(MenuBarPrefs.percent) private var showPercent = true
    @AppStorage(MenuBarPrefs.time) private var showTime = true
    @AppStorage(MenuBarPrefs.watts) private var showWatts = false

    var body: some View {
        let s = model.state
        // The label is rendered from launch: a reliable entry point to open
        // the wizard as long as the app is not configured.
        // The trigger sits outside the branches: it must fire even if a recent
        // state.json makes it look like there's an active connection (post-reset).
        Group {
            content(s)
        }
        .onAppear {
            if model.needsOnboarding {
                // Dia-style full-screen intro, then windowed wizard
                IntroWindowController.show {
                    openWindow(id: "onboarding")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    @ViewBuilder private func content(_ s: EFState) -> some View {
        if !s.isConnected {
            Image(systemName: s.isStale || s.status != "searching"
                  ? "bolt.trianglebadge.exclamationmark" : "bolt.slash")
        } else {
            let level = Int(s.displayLevel)
            let text = labelText(s, level: level)
            // Everything unchecked: fall back to the icon alone
            HStack(spacing: 4) {
                if showIcon || text.isEmpty {
                    Image(systemName: batterySymbol(level, mode: s.mode))
                        .renderingMode(.template)
                }
                if !text.isEmpty {
                    Text(text)
                }
            }
        }
    }

    private func labelText(_ s: EFState, level: Int) -> String {
        var parts: [String] = []
        if showPercent { parts.append("\(level)%") }
        if showTime, s.mode == "discharging",
           let remaining = fmtMinutes(s.remainingDischarge) {
            parts.append(remaining.replacingOccurrences(of: " h ", with: ":"))
        }
        if showWatts {
            let load = (s.acOutput ?? 0) + (s.usbcOutput ?? 0)
            parts.append("\(Int(load.rounded())) W")
        }
        return parts.joined(separator: " ")
    }

    private func batterySymbol(_ level: Int, mode: String) -> String {
        if mode == "charging" { return "battery.100percent.bolt" }
        if mode == "plugged" { return "powerplug" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

// MARK: - App

@main
struct EcoFlowBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window(model.t("EcoFlow Settings"), id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Welcome", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
