// EcoFlowBar — panneau batterie EcoFlow dans la barre de menus, style "Stats".
// Lit state.json (écrit par le démon ef_monitor.py) et pilote config.json.
import AppKit
import Charts
import SwiftUI

// MARK: - Modèle

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

    // % affiché partout : la fenêtre utilisable si des limites sont actives
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
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

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
        // Autonomie effective (corrigée de la limite de décharge) en priorité
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

    // Écrit une valeur dans config.json (le démon recharge à chaud via mtime)
    func setConfig(_ dottedKey: String, _ value: Any) {
        let url = Self.appDir.appendingPathComponent("config.json")
        var root = Self.readJSON(url) ?? [:]
        let parts = dottedKey.split(separator: ".").map(String.init)
        if parts.count == 1 {
            root[parts[0]] = value
        } else {
            var child = root[parts[0]] as? [String: Any] ?? [:]
            child[parts[1]] = value
            // Garde-fou hystérésis (même règle que ef_config.py)
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

    // Dépose une commande one-shot exécutée par le démon (command.json)
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

    // Énergie du jour (Wh) intégrée depuis l'historique (échantillons 1/min)
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
}

// MARK: - Helpers d'affichage

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

// MARK: - Composants

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

// MARK: - Graphique combiné batterie + consommation

struct HistoryChart: View {
    let samples: [Sample]
    @AppStorage("historyWindowHours") private var windowHours = 6

    private static let battColor = Color(red: 0.3, green: 0.75, blue: 0.4)
    private static let consoColor = Color.orange
    private static let cpuColor = Color.pink

    private var windowed: [Sample] {
        let cutoff = Date().timeIntervalSince1970 - Double(windowHours) * 3600
        return samples.filter { $0.ts >= cutoff }
    }

    // Échelle W (axe de droite) : conso ramenée au domaine 0-100 du graphique
    private var maxWatts: Double {
        let peak = windowed.compactMap { max($0.macWatts ?? 0, $0.cpuWatts ?? 0) }.max() ?? 0
        return max(30, peak * 1.2)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                SectionHeader(title: "Historique — \(windowHours) h")
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
                Text("Historique en cours de collecte…")
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
                           "Conso moy. \(Int((conso.reduce(0, +) / Double(conso.count)).rounded())) W")
            }
            if !cpu.isEmpty {
                legendItem(Self.cpuColor,
                           String(format: "CPU moy. %.1f W", cpu.reduce(0, +) / Double(cpu.count)))
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

// MARK: - Panneau

struct PanelView: View {
    @ObservedObject var model: Model
    @State private var confirmHibernate = false
    @State private var confirmAcOff = false

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

    // MARK: Lancement au démarrage (pilote le LaunchAgent fr.koa.ecoflow-bar)

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/fr.koa.ecoflow-bar.plist")
    }

    private var launchAtLogin: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private func toggleLaunchAtLogin() {
        if launchAtLogin {
            // Retirer le plist suffit : l'instance courante continue de tourner,
            // l'app ne sera simplement plus lancée au prochain login
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
            try? process.run()  // "already bootstrapped" si l'app tourne déjà : sans effet
        }
        model.reload()
    }

    private func hibernate() {
        // Le bundle vit à la racine du projet : EcoFlowBar.app/../scripts/
        let script = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/ef_hibernate.sh")
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ecoflow-hibernate.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // Sortie du script journalisée pour pouvoir diagnostiquer un échec
        process.arguments = ["-c", "exec /bin/bash \"$1\" >> \"$2\" 2>&1", "--", script.path, log.path]
        do {
            try process.run()
        } catch {
            try? "lancement impossible : \(error)\n".write(to: log, atomically: true, encoding: .utf8)
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

        HistoryChart(samples: model.history)

        VStack(spacing: 6) {
            SectionHeader(title: s.device)
            if s.mode == "discharging", let remaining = fmtMinutes(s.remainingDischarge) {
                Row(dot: .green, label: "Autonomie restante", value: remaining)
            }
            if s.mode == "charging", let remaining = fmtMinutes(s.remainingCharge) {
                Row(dot: .yellow, label: "Charge complète dans", value: remaining)
            }
            Row(
                dot: s.onEcoflow ? .blue : .gray,
                label: "Mac sur l'EcoFlow",
                value: s.onEcoflow ? "oui" : "non"
            )
            Row(
                dot: statusDot(s.mode),
                label: "État",
                value: [
                    "charging": "en charge",
                    "discharging": "sur batterie",
                    "plugged": "sur secteur",
                ][s.mode] ?? "au repos"
            )
            if s.hasLimitWindow, let raw = s.level {
                Row(
                    dot: .gray,
                    label: "Niveau réel",
                    value: "\(Int(raw)) % · fenêtre \(Int(s.chargeLimitMin ?? 0))–\(Int(s.chargeLimitMax ?? 100)) %"
                )
            }
        }

        VStack(spacing: 6) {
            SectionHeader(title: "Flux")
            Row(dot: .yellow, label: "Entrée", value: fmtWatts(s.inputSum))
            acRow(s)
            Row(dot: .purple, label: "Sortie USB-C", value: fmtWatts(s.usbcOutput))
            if let cpu = s.macCpuWatts {
                Row(dot: .pink, label: "CPU du Mac (interne)", value: String(format: "%.1f W", cpu))
            }
            if let temp = s.temperature {
                Row(dot: .orange, label: "Température", value: "\(Int(temp)) °C")
            }
            energyRow
        }
    }

    // Ligne Sortie AC avec interrupteur (commande exécutée par le démon)
    @ViewBuilder private func acRow(_ s: EFState) -> some View {
        if confirmAcOff {
            HStack(spacing: 7) {
                Text("Couper l'alimentation du Mac ?")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Couper") {
                    confirmAcOff = false
                    model.sendCommand("set_ac", value: false)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.mini)
                Button("Annuler") { confirmAcOff = false }
                    .controlSize(.mini)
            }
        } else {
            HStack(spacing: 7) {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                Text("Sortie AC").font(.system(size: 12))
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
                .help(s.acPorts ? "Couper la sortie AC" : "Activer la sortie AC")
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
            label: "Énergie aujourd'hui",
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
                return "pleine dans \(remaining)"
            }
            return "en charge"
        case "plugged":
            return "sur secteur"
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
            if model.state.isStale { return "Démon injoignable — voir le journal" }
            switch model.state.status {
            case "searching": return "Recherche Bluetooth…"
            case "offline": return "EcoFlow hors de portée ou éteinte"
            case "unconfigured": return "Non configuré — lancer ef_login.py"
            default: return "En attente du démon…"
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
                Text("Sauvegarder la session et éteindre le Mac ?")
                    .font(.system(size: 11, weight: .semibold))
                Text("Apps, onglets et tmux seront restaurés au prochain démarrage.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Annuler") { confirmHibernate = false }
                        .controlSize(.small)
                    Spacer()
                    Button("Éteindre") {
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
            Text("Actions automatiques sur le Mac").font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        HStack {
            settingsMenu
            Spacer()
            Button {
                confirmHibernate = true
            } label: {
                Image(systemName: "moon.zzz")
            }
            .buttonStyle(.borderless)
            .help("Hiberner : sauvegarder la session et éteindre")
            Button {
                NSWorkspace.shared.open(Model.logURL)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("Journal du démon")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quitter EcoFlowBar")
        }
    }

    private var settingsMenu: some View {
        Menu("Réglages") {
            Menu("Barre de menus") {
                displayToggle("Icône batterie", MenuBarPrefs.icon, def: true)
                displayToggle("Pourcentage", MenuBarPrefs.percent, def: true)
                displayToggle("Autonomie restante", MenuBarPrefs.time, def: true)
                displayToggle("Puissance débitée", MenuBarPrefs.watts, def: false)
            }
            Divider()
            thresholdMenu("Notification à", key: "notify", def: 20, presets: [15, 20, 25, 30])
            thresholdMenu("Mode éco à", key: "lowpower", def: 10, presets: [5, 10, 15])
            thresholdMenu("Extinction à", key: "shutdown", def: 5, presets: [3, 5, 8])
            thresholdMenu("Retour normal à", key: "restore", def: 15, presets: [13, 15, 20, 25])
            Divider()
            toggleItem("Notifications", "actions.notify")
            toggleItem("Mode éco automatique", "actions.lowpower")
            toggleItem("Mode éco dès la batterie", "actions.lowpower_on_battery")
            toggleItem("Extinction automatique", "actions.shutdown")
            toggleItem("Seulement si Mac sur l'EcoFlow", "require_mac_on_ecoflow")
            Divider()
            limitMenu("Limite de charge", key: "charge_limit_max",
                      presets: [80, 85, 90, 100], deviceValue: model.state.chargeLimitMax)
            limitMenu("Limite de décharge", key: "charge_limit_min",
                      presets: [0, 5, 10, 15, 20], deviceValue: model.state.chargeLimitMin)
            Divider()
            Button {
                toggleLaunchAtLogin()
            } label: {
                if launchAtLogin {
                    Label("Lancer au démarrage", systemImage: "checkmark")
                } else {
                    Text("Lancer au démarrage")
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // Limites écrites dans la batterie (max 80-85 % = longévité ;
    // min > 0 = réserve). Le % affiché est rapporté à cette fenêtre.
    private func limitMenu(_ title: String, key: String, presets: [Int],
                           deviceValue: Double?) -> some View {
        let target = model.config[key] as? Int
        let device = deviceValue.map { Int($0) }
        let label = target.map { "\(title) : \($0) %" }
            ?? "\(title) : \(device.map { "\($0) %" } ?? "—") (non pilotée)"
        return Menu(label) {
            ForEach(presets, id: \.self) { value in
                Button {
                    model.setConfig(key, value)
                } label: {
                    if value == target {
                        Label("\(value) %", systemImage: "checkmark")
                    } else {
                        Text("\(value) %")
                    }
                }
            }
            Button {
                model.setConfig(key, NSNull())
            } label: {
                if target == nil {
                    Label("Ne pas piloter", systemImage: "checkmark")
                } else {
                    Text("Ne pas piloter")
                }
            }
        }
    }

    private func thresholdMenu(_ label: String, key: String, def: Int, presets: [Int]) -> some View {
        let current = model.threshold(key, default: def)
        return Menu("\(label) : \(current) %") {
            ForEach(Array(Set(presets + [current])).sorted(), id: \.self) { value in
                Button {
                    model.setConfig("thresholds.\(key)", value)
                } label: {
                    if value == current {
                        Label("\(value) %", systemImage: "checkmark")
                    } else {
                        Text("\(value) %")
                    }
                }
            }
        }
    }

    private func displayToggle(_ label: String, _ key: String, def: Bool) -> some View {
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? def
        return Button {
            UserDefaults.standard.set(!current, forKey: key)
        } label: {
            if current {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }

    private func toggleItem(_ label: String, _ key: String) -> some View {
        Button {
            model.setConfig(key, !model.configBool(key, default: key == "actions.shutdown" ? false : true))
        } label: {
            if model.configBool(key, default: key == "actions.shutdown" ? false : true) {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

// MARK: - Libellé barre de menus

// Préférences d'affichage du libellé (Réglages → Barre de menus)
enum MenuBarPrefs {
    static let icon = "mbShowIcon"
    static let percent = "mbShowPercent"
    static let time = "mbShowTime"
    static let watts = "mbShowWatts"
}

struct MenuLabel: View {
    @ObservedObject var model: Model
    @AppStorage(MenuBarPrefs.icon) private var showIcon = true
    @AppStorage(MenuBarPrefs.percent) private var showPercent = true
    @AppStorage(MenuBarPrefs.time) private var showTime = true
    @AppStorage(MenuBarPrefs.watts) private var showWatts = false

    var body: some View {
        let s = model.state
        if !s.isConnected {
            Image(systemName: s.isStale || s.status != "searching"
                  ? "bolt.trianglebadge.exclamationmark" : "bolt.slash")
        } else {
            let level = Int(s.displayLevel)
            let text = labelText(s, level: level)
            // Tout décoché : on retombe sur l'icône seule
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
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
