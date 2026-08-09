// Intro plein écran façon Dia (cf. breakdown de George Cartridge) :
// fenêtre borderless au-dessus de tout, bureau assombri, orbe lumineux,
// texte en cascade caractère par caractère, aurora, puis fondu vers
// l'assistant fenêtré. Tout est recréé en SwiftUI natif (pas de vidéos).
import AppKit
import SwiftUI

// MARK: - Fenêtre plein écran sans chrome

final class IntroWindowController {
    static var current: IntroWindowController?

    private let window: NSWindow
    private var finished = false
    private let onFinish: () -> Void

    static func show(onFinish: @escaping () -> Void) {
        guard current == nil else { return }
        current = IntroWindowController(onFinish: onFinish)
    }

    private init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Au-dessus de la barre de menus : l'écran entier appartient à l'intro
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let lang = resolveLanguage(Self.configLanguage())
        window.contentView = NSHostingView(rootView: IntroView(
            onFinish: { [weak self] in self?.finish() },
            t: { L10n.text($0, lang: lang) }
        ))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Phase 1 du breakdown : le bureau s'assombrit en ~1 s
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            window.animator().alphaValue = 1
        }
    }

    private static func configLanguage() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ecoflow-monitor/config.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return json["language"] as? String
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.8
            self.window.animator().alphaValue = 0
        }, completionHandler: {
            self.window.orderOut(nil)
            IntroWindowController.current = nil
            self.onFinish()
        })
    }
}

// MARK: - Texte en cascade (rotation 3D + flou + opacité, 0,02 s/caractère)

struct StaggerText: View {
    let text: String
    let show: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .opacity(show ? 1 : 0)
                    .blur(radius: show ? 0 : 9)
                    .rotation3DEffect(
                        .degrees(show ? 0 : 20),
                        axis: (x: 0.4, y: 1, z: 0)
                    )
                    .offset(y: show ? 0 : 16)
                    .animation(
                        .spring(response: 0.65, dampingFraction: 0.8)
                            .delay(Double(index) * 0.02),
                        value: show
                    )
            }
        }
    }
}

// MARK: - Orbe lumineux (équivalent natif de leur vidéo Spline)

struct IntroOrb: View {
    let visible: Bool

    private static let palette: [Color] = [
        Color(red: 1.00, green: 0.45, blue: 0.65),
        Color(red: 1.00, green: 0.32, blue: 0.24),
        Color(red: 1.00, green: 0.80, blue: 0.30),
        Color(red: 0.72, green: 0.62, blue: 1.00),
        Color(red: 0.32, green: 0.54, blue: 1.00),
        Color(red: 1.00, green: 0.45, blue: 0.65),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.05 * sin(t * 1.3)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: Self.palette, center: .center,
                                          angle: .degrees(t * 24)))
                    .frame(width: 200, height: 200)
                    .blur(radius: 38)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.95), .white.opacity(0)],
                            center: .center, startRadius: 4, endRadius: 88
                        )
                    )
                    .frame(width: 150, height: 150)
                    .blur(radius: 10)
            }
            .scaleEffect((visible ? 1 : 0.2) * breathe)
            .opacity(visible ? 1 : 0)
        }
        .frame(width: 240, height: 240)
    }
}

// MARK: - Séquence de l'intro

struct IntroView: View {
    let onFinish: () -> Void
    let t: (String) -> String

    @State private var orbVisible = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var auroraVisible = false
    @State private var hintVisible = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()

            if auroraVisible {
                AuroraView(intensity: 0.7)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 18) {
                Spacer()
                IntroOrb(visible: orbVisible)
                StaggerText(text: t("Hello."), show: titleVisible)
                    .font(.system(size: 104, weight: .black))
                    .fontWidth(.compressed)
                    .tracking(-2)
                    .foregroundStyle(.white)
                Text(t("Let's set up your EcoFlow battery."))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.72))
                    .opacity(subtitleVisible ? 1 : 0)
                Spacer()
                Text(t("click to continue"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .opacity(hintVisible ? 1 : 0)
                    .padding(.bottom, 46)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onFinish() }
        .task {
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.spring(response: 1.1, dampingFraction: 0.75)) { orbVisible = true }
            try? await Task.sleep(for: .seconds(1.2))
            titleVisible = true  // la cascade par caractère gère sa propre animation
            try? await Task.sleep(for: .seconds(1.0))
            withAnimation(.easeOut(duration: 0.8)) { subtitleVisible = true }
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeIn(duration: 0.6)) { auroraVisible = true }
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.easeIn(duration: 0.5)) { hintVisible = true }
            try? await Task.sleep(for: .seconds(2.4))
            onFinish()
        }
    }
}
