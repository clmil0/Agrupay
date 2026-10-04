import SwiftUI
import UIKit

/// El cobro en modo intenso (`1c` de «Cobros entre amigos»): al abrir la app,
/// el personaje de quien cobra cae desde arriba, aterriza, mira a los lados y
/// señala el globo mientras el monto sube desde cero.
///
/// «Ya le pagué» equivale a «Listo» (ojos felices, salto y aleteo, el monto
/// pasa a verde). «Más tarde» lo cierra con el personaje desinflado y el cobro
/// queda en Amigos, donde entra como en el modo suave.
///
/// Los tiempos y curvas son los del diseño, en milisegundos (`KeyMotion`).
struct PaymentReminderModal: View {
    enum Outcome { case paid, later }

    let reminder: PaymentReminder
    let name: String
    let look: PenguinLook
    let onFinish: (Outcome) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var origin = Date()
    @State private var motion = PaymentReminderModal.intro()
    @State private var outcome: Outcome?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(origin) * 1000
            let v = { (channel: Channel) in motion.value(channel, at: t) }

            ZStack(alignment: .bottom) {
                // Oscurece y desenfoca la app, como el diseño.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color(red: 0.02, green: 0.027, blue: 0.043).opacity(scheme == .dark ? 0.62 : 0.4)
                }
                .ignoresSafeArea()
                .opacity(v(.backdrop))

                card(t: t, v)
                    .offset(y: v(.cardY))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear { origin = Date() }
    }

    // MARK: - Tarjeta

    private func card(t: Double, _ v: (Channel) -> Double) -> some View {
        VStack(spacing: 0) {
            stage(v)
                .frame(height: 232)

            VStack(spacing: 0) {
                Text(name + " te está cobrando")
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .entering(v, 0)

                if let amount = reminder.amount {
                    Text(Money.format(countedAmount(amount, t: t), currency: reminder.currency))
                        .font(.system(size: 50, weight: .heavy))
                        .tracking(-1.8)
                        .monospacedDigit()
                        .foregroundStyle(amountColor(v(.amountGreen)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .scaleEffect(v(.amountScale))
                        .padding(.top, 4)
                        .entering(v, 1)
                }

                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
                    .padding(.top, 4)
                    .entering(v, 2)

                if !reminder.message.isEmpty {
                    Text("«" + reminder.message + "»")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(palette.label)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .entering(v, 3)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                Button { finish(.paid) } label: {
                    Text("Ya le pagué")
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(accent.color, in: Capsule())
                }
                .buttonStyle(PressScaleStyle())

                Button { finish(.later) } label: {
                    Text("Más tarde")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
            .entering(v, 4)
            .disabled(outcome != nil)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 25, y: -10)
    }

    /// El escenario: halo, sombra, personaje y globo.
    private func stage(_ v: (Channel) -> Double) -> some View {
        ZStack(alignment: .bottom) {
            RadialGradient(colors: [accent.color.opacity(0.20), accent.color.opacity(0)],
                           center: .center, startRadius: 0, endRadius: 110)
                .frame(width: 230, height: 230)
                .clipShape(Circle())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 40)

            Ellipse()
                .fill(Color.black.opacity(0.5))
                .frame(width: 128, height: 18)
                .blur(radius: 3)
                .scaleEffect(x: v(.shadowSX), y: v(.shadowSY))
                .opacity(v(.shadowOpacity))
                .padding(.bottom, 14)

            PenguinView(look: look, mood: mood, pose: pose(v))
                .frame(width: 176, height: 172)
                // De dentro hacia fuera: respirar, inclinarse, caer.
                .scaleEffect(x: v(.breathSX), y: v(.breathSY), anchor: .bottom)
                .offset(y: v(.breathY))
                .scaleEffect(x: v(.leanSX), y: v(.leanSY), anchor: .bottom)
                .rotationEffect(.degrees(v(.lean)), anchor: .bottom)
                .scaleEffect(x: v(.fallSX), y: v(.fallSY), anchor: .bottom)
                .offset(y: v(.fallY))
                .opacity(v(.rigOpacity))
                .padding(.bottom, 20)

            bubble
                .scaleEffect(v(.bubbleScale), anchor: .bottomLeading)
                .rotationEffect(.degrees(v(.bubbleRot)), anchor: .bottomLeading)
                .opacity(v(.bubbleOpacity))
                .offset(y: v(.bubbleFloat))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 34)
        }
    }

    private var bubble: some View {
        Text(bubbleText)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(red: 0.043, green: 0.055, blue: 0.078))
            .lineLimit(1)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(Color(red: 0.929, green: 0.941, blue: 0.957),
                        in: UnevenRoundedRectangle(topLeadingRadius: 17, bottomLeadingRadius: 5,
                                                   bottomTrailingRadius: 17, topTrailingRadius: 17,
                                                   style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 6)
    }

    // MARK: - Texto

    private var detail: String {
        guard let day = reminder.occurredOn else { return reminder.merchant }
        return reminder.merchant + " · "
            + day.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
    }

    private var bubbleText: String {
        switch outcome {
        case .paid: return "¡Gracias!"
        case .later: return "Ok… te espero"
        case nil:
            guard let amount = reminder.amount else { return "¿Y lo mío?" }
            let whole = Int(amount.rounded(.down))
            let unit = reminder.currency == "USD" ? (whole == 1 ? "dólar" : "dólares")
                                                  : (whole == 1 ? "sol" : "soles")
            return "¿Y mis \(whole) \(unit)?"
        }
    }

    /// Sube de cero cuando el personaje señala el globo.
    private func countedAmount(_ amount: Double, t: Double) -> Double {
        guard outcome == nil else { return amount }
        let p = min(1, max(0, (t - 2480) / 800))
        return amount * (1 - pow(1 - p, 3))
    }

    private func amountColor(_ green: Double) -> Color {
        green <= 0 ? palette.label : palette.label.mixed(with: palette.income, amount: green, scheme: scheme)
    }

    // MARK: - Personaje

    private var mood: PenguinMood {
        switch outcome {
        case .paid: return .happy
        case .later: return .warning
        case nil: return .ok
        }
    }

    private func pose(_ v: (Channel) -> Double) -> PenguinPose {
        PenguinPose(wingLeft: v(.wingL), wingRight: v(.wingR),
                    tuft: v(.tuft), tuftLift: v(.tuftY), tuftStretch: v(.tuftSY),
                    face: CGSize(width: v(.faceX), height: v(.faceY)),
                    blink: v(.blink))
    }

    // MARK: - Salida

    private func finish(_ kind: Outcome) {
        guard outcome == nil else { return }
        outcome = kind
        origin = Date()
        motion = kind == .paid ? Self.paidExit() : Self.laterExit()
        let close: Double = kind == .paid ? 1350 : 1450
        Self.addClose(to: &motion, at: close)
        if kind == .paid && ProStore.isPro {
            ProHaptics.play(.settled)
        } else {
            UIImpactFeedbackGenerator(style: kind == .paid ? .medium : .light).impactOccurred()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(Int(close) + 580))
            onFinish(kind)
        }
    }
}

// MARK: - Líneas de tiempo

extension PaymentReminderModal {

    enum Channel: Hashable {
        case backdrop, cardY
        case textOpacity(Int), textY(Int)
        case fallY, fallSX, fallSY, rigOpacity
        case lean, leanSX, leanSY
        case breathSX, breathSY, breathY
        case shadowSX, shadowSY, shadowOpacity
        case wingL, wingR, tuft, tuftY, tuftSY
        case faceX, faceY, blink
        case bubbleScale, bubbleRot, bubbleOpacity, bubbleFloat
        case amountScale, amountGreen
    }

    typealias Motion = KeyMotion<Channel>

    private static var rest: [Channel: Double] {
        var rest: [Channel: Double] = [:]
        for channel in [Channel.backdrop, .rigOpacity, .fallSX, .fallSY, .leanSX, .leanSY,
                        .breathSX, .breathSY, .shadowSX, .shadowSY, .tuftSY, .blink,
                        .bubbleScale, .bubbleOpacity, .amountScale] {
            rest[channel] = 1
        }
        for index in 0..<5 { rest[.textOpacity(index)] = 1 }
        rest[.shadowOpacity] = 0.55
        return rest
    }

    /// Entra (resorte), cae estirado, aterriza aplastado con las alas
    /// siguiendo, parpadea y mira, anticipa y señala el globo. 3.7 s y luego
    /// la espera en bucle.
    static func intro() -> Motion {
        var m = Motion(rest: rest)
        m.add([(0, [.backdrop: 0]), (1, [.backdrop: 1])], at: 0, duration: 320, curve: .cssEaseOut)
        m.add([(0, [.cardY: 720]), (0.68, [.cardY: -14]), (0.86, [.cardY: 4]), (1, [.cardY: 0])],
              at: 60, duration: 700, curve: .css(0.2, 0.75, 0.35, 1))
        for index in 0..<5 {
            m.add([(0, [.textOpacity(index): 0, .textY(index): 12]), (1, [.textOpacity(index): 1, .textY(index): 0])],
                  at: 640 + Double(index) * 70, duration: 420, curve: .css(0.2, 0.8, 0.3, 1))
        }

        // Caída + impacto: una sola curva para que el aplastamiento nazca del golpe.
        m.add([(0, [.fallY: -440, .fallSX: 0.92, .fallSY: 1.1, .rigOpacity: 0], .linear),
               (0.04, [.fallY: -400, .fallSX: 0.92, .fallSY: 1.1, .rigOpacity: 1], .css(0.5, 0, 0.9, 0.5)),
               (0.36, [.fallY: 0, .fallSX: 0.88, .fallSY: 1.16], .css(0.1, 0.6, 0.3, 1)),
               (0.44, [.fallY: 0, .fallSX: 1.22, .fallSY: 0.76], .css(0.3, 0, 0.3, 1)),
               (0.58, [.fallY: -16, .fallSX: 0.94, .fallSY: 1.08], .css(0.4, 0, 0.6, 1)),
               (0.72, [.fallY: 0, .fallSX: 1.07, .fallSY: 0.94], .cssEaseOut),
               (0.85, [.fallY: 0, .fallSX: 0.99, .fallSY: 1.01], .linear),
               (1, [.fallY: 0, .fallSX: 1, .fallSY: 1], .linear)],
              at: 380, duration: 1100, curve: .linear)
        m.add([(0, [.shadowSX: 0.15, .shadowSY: 0.15, .shadowOpacity: 0]),
               (0.36, [.shadowSX: 0.9, .shadowSY: 0.9, .shadowOpacity: 0.5]),
               (0.44, [.shadowSX: 1.3, .shadowSY: 1, .shadowOpacity: 0.7]),
               (0.58, [.shadowSX: 0.85, .shadowSY: 0.85, .shadowOpacity: 0.4]),
               (1, [.shadowSX: 1, .shadowSY: 1, .shadowOpacity: 0.55])],
              at: 380, duration: 1100, curve: .cssEaseOut)
        func wing(_ channel: Channel, _ s: Double) -> [(Double, [Channel: Double])] {
            [(0, [channel: 22 * s]), (0.36, [channel: 30 * s]), (0.46, [channel: -16 * s]),
             (0.6, [channel: 9 * s]), (0.76, [channel: -3 * s]), (1, [channel: 0])]
        }
        m.add(wing(.wingL, 1), at: 420, duration: 1100, curve: .cssEaseInOut)
        m.add(wing(.wingR, -1), at: 450, duration: 1100, curve: .cssEaseInOut)
        m.add([(0, [.tuft: -6, .tuftY: 4]), (0.36, [.tuft: -10, .tuftY: 6]),
               (0.5, [.tuft: 16, .tuftY: -6, .tuftSY: 1.15]), (0.64, [.tuft: -9]),
               (0.78, [.tuft: 4]), (1, [.tuft: 0])],
              at: 470, duration: 1100, curve: .cssEaseInOut)
        m.add([(0, [.blink: 1]), (0.45, [.blink: 0.08]), (1, [.blink: 1])], at: 1300, duration: 170)
        m.add([(0, [.faceX: 0]), (0.14, [.faceX: -13]), (0.42, [.faceX: -13]), (0.56, [.faceX: 13]),
               (0.8, [.faceX: 13]), (1, [.faceX: 4, .faceY: -3])],
              at: 1480, duration: 900, curve: .css(0.4, 0, 0.2, 1))
        m.add([(0, [.lean: 0]), (0.14, [.lean: -5, .leanSX: 1.02, .leanSY: 0.97]), (0.3, [.lean: 3]),
               (0.78, [.lean: 2]), (0.9, [.lean: -1]), (1, [.lean: 0])],
              at: 2150, duration: 1500, curve: .cssEaseInOut)
        m.add([(0, [.wingR: 0]), (0.12, [.wingR: 14]), (0.26, [.wingR: -98]), (0.33, [.wingR: -82]),
               (0.4, [.wingR: -88]), (0.47, [.wingR: -76]), (0.54, [.wingR: -88]), (0.61, [.wingR: -76]),
               (0.68, [.wingR: -88]), (0.78, [.wingR: -86]), (0.9, [.wingR: 8]), (1, [.wingR: 0])],
              at: 2150, duration: 1500, curve: .cssEaseInOut)
        m.add([(0, [.bubbleScale: 0, .bubbleRot: -8, .bubbleOpacity: 0]),
               (0.55, [.bubbleScale: 1.14, .bubbleRot: 2, .bubbleOpacity: 1]),
               (0.78, [.bubbleScale: 0.95, .bubbleRot: -1, .bubbleOpacity: 1]),
               (1, [.bubbleScale: 1, .bubbleRot: 0, .bubbleOpacity: 1])],
              at: 2480, duration: 460, curve: .css(0.3, 0.7, 0.4, 1))
        m.add([(0, [.amountScale: 1]), (0.4, [.amountScale: 1.07]), (1, [.amountScale: 1])],
              at: 3280, duration: 360, curve: .cssEaseOut)

        // Espera: respira, parpadea, vuelve a señalar el globo.
        let idle = 3700.0
        m.add([(0, [.breathSX: 1, .breathSY: 1]), (1, [.breathSX: 1.018, .breathSY: 0.982])],
              at: idle, duration: 1300, curve: .cssEaseInOut, iterations: .infinity, alternate: true)
        m.add([(0, [.blink: 1]), (0.9, [.blink: 1]), (0.93, [.blink: 0.08]), (0.96, [.blink: 1]), (1, [.blink: 1])],
              at: idle + 600, duration: 3600, curve: .linear, iterations: .infinity)
        m.add([(0, [.wingR: 0]), (0.55, [.wingR: 0]), (0.61, [.wingR: -22]), (0.67, [.wingR: 0]),
               (0.73, [.wingR: -22]), (0.79, [.wingR: 0]), (0.85, [.wingR: -22]), (0.91, [.wingR: 0]), (1, [.wingR: 0])],
              at: idle, duration: 3000, curve: .cssEaseInOut, iterations: .infinity)
        m.add([(0, [.tuft: 0]), (0.58, [.tuft: 0]), (0.64, [.tuft: 5]), (0.76, [.tuft: -4]), (0.88, [.tuft: 3]), (1, [.tuft: 0])],
              at: idle, duration: 3000, curve: .cssEaseInOut, iterations: .infinity)
        m.add([(0, [.lean: 0]), (0.55, [.lean: 0]), (0.7, [.lean: 1.5]), (0.88, [.lean: 1.5]), (1, [.lean: 0])],
              at: idle, duration: 3000, curve: .cssEaseInOut, iterations: .infinity)
        m.add([(0, [.bubbleFloat: 0]), (1, [.bubbleFloat: -5])],
              at: idle, duration: 1500, curve: .cssEaseInOut, iterations: .infinity, alternate: true)
        return m
    }

    private static func bubblePop(_ m: inout Motion) {
        m.add([(0, [.bubbleScale: 0.6, .bubbleOpacity: 0.4]), (0.6, [.bubbleScale: 1.1, .bubbleOpacity: 1]),
               (1, [.bubbleScale: 1, .bubbleOpacity: 1])],
              at: 0, duration: 360, curve: .css(0.3, 0.7, 0.4, 1))
    }

    /// Ojos felices, salto con aplastamiento y aleteo; el monto pasa a verde.
    static func paidExit() -> Motion {
        var m = Motion(rest: rest)
        bubblePop(&m)
        m.add([(0, [:], .cssEaseOut),
               (0.2, [.fallSX: 1.14, .fallSY: 0.84], .css(0.2, 0.6, 0.4, 1)),
               (0.46, [.fallY: -74, .fallSX: 0.92, .fallSY: 1.1], .css(0.6, 0, 0.9, 0.5)),
               (0.68, [.fallY: 0, .fallSX: 1.16, .fallSY: 0.84], .cssEaseOut),
               (0.84, [.fallY: -6, .fallSX: 0.97, .fallSY: 1.04], .linear),
               (1, [.fallY: 0, .fallSX: 1, .fallSY: 1], .linear)],
              at: 0, duration: 760, curve: .linear)
        m.add([(0, [.shadowSX: 1, .shadowSY: 1, .shadowOpacity: 0.55]),
               (0.2, [.shadowSX: 1.1, .shadowSY: 1.1, .shadowOpacity: 0.5]),
               (0.46, [.shadowSX: 0.55, .shadowSY: 0.55, .shadowOpacity: 0.25]),
               (0.68, [.shadowSX: 1.2, .shadowSY: 1, .shadowOpacity: 0.6]),
               (1, [.shadowSX: 1, .shadowSY: 1, .shadowOpacity: 0.55])],
              at: 0, duration: 760)
        func flap(_ channel: Channel, _ s: Double) -> [(Double, [Channel: Double])] {
            [(0, [channel: 0]), (0.17, [channel: 44 * s]), (0.34, [channel: 6 * s]), (0.5, [channel: 44 * s]),
             (0.67, [channel: 6 * s]), (0.83, [channel: 40 * s]), (1, [channel: 0])]
        }
        m.add(flap(.wingL, 1), at: 120, duration: 820, curve: .cssEaseInOut)
        m.add(flap(.wingR, -1), at: 150, duration: 820, curve: .cssEaseInOut)
        m.add([(0, [.tuft: 0]), (0.4, [.tuft: -12]), (0.7, [.tuft: 14, .tuftSY: 1.15]), (1, [.tuft: 0])],
              at: 60, duration: 760)
        m.add([(0, [.amountGreen: 0]), (1, [.amountGreen: 1])], at: 200, duration: 300)
        return m
    }

    /// Párpado caído, se desinfla, alas bajas.
    static func laterExit() -> Motion {
        var m = Motion(rest: rest)
        bubblePop(&m)
        m.add([(0, [.breathSX: 1, .breathSY: 1]), (0.25, [.breathSX: 1.03, .breathSY: 1.03]),
               (1, [.breathY: 4, .breathSX: 1.05, .breathSY: 0.93])],
              at: 0, duration: 900, curve: .css(0.4, 0, 0.2, 1))
        m.add([(0, [.lean: 0]), (1, [.lean: -3])], at: 200, duration: 900, curve: .cssEaseInOut)
        m.add([(0, [.wingL: 0]), (0.25, [.wingL: 8]), (1, [.wingL: -16])], at: 0, duration: 800)
        m.add([(0, [.wingR: 0]), (0.25, [.wingR: -8]), (1, [.wingR: 14])], at: 40, duration: 800)
        m.add([(0, [.faceX: 0]), (1, [.faceX: -4, .faceY: 6])], at: 200, duration: 700)
        m.add([(0, [.tuft: 0]), (1, [.tuft: -18, .tuftY: 4])], at: 150, duration: 900, curve: .css(0.3, 1.4, 0.5, 1))
        return m
    }

    /// La tarjeta baja y el fondo se aclara.
    static func addClose(to m: inout Motion, at start: Double) {
        m.add([(0, [.cardY: 0]), (0.2, [.cardY: -10]), (1, [.cardY: 760])],
              at: start, duration: 480, curve: .css(0.5, 0, 0.8, 0.4))
        m.add([(0, [.backdrop: 1]), (1, [.backdrop: 0])], at: start + 240, duration: 320, curve: .cssEaseIn)
    }
}

private extension View {
    /// Cada bloque de texto entra subiendo 12 pt, uno tras otro.
    func entering(_ v: (PaymentReminderModal.Channel) -> Double, _ index: Int) -> some View {
        opacity(v(.textOpacity(index)))
            .offset(y: v(.textY(index)))
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Presentación

/// El modal va en una ventana propia, por encima de cualquier hoja abierta y
/// por debajo del blindaje de privacidad (`PrivacyShield`, `.alert + 1`).
@MainActor
enum PaymentReminderModalPresenter {

    private static var window: UIWindow?

    static var isPresenting: Bool { window != nil }

    static func present(_ reminder: PaymentReminder) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return }

        // El teclado vive en una ventana del sistema por encima de `.alert`:
        // con un formulario abierto (registrar un gasto) se dibujaba encima
        // del modal. Se guarda antes de mostrarlo.
        scene.windows.forEach { $0.endEditing(true) }

        let friend = FriendsManager.shared.friend(with: reminder.fromUser)
        let modal = PaymentReminderModal(reminder: reminder,
                                         name: friend.name,
                                         look: friend.penguin ?? PenguinLook()) { outcome in
            finish(reminder, outcome)
        }

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.overrideUserInterfaceStyle = PrivacyShield.isDark() ? .dark : .light
        w.backgroundColor = .clear
        let host = UIHostingController(rootView: modal)
        host.view.backgroundColor = .clear
        w.rootViewController = host
        w.isHidden = false
        window = w
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Al bloquear la app el modal se quita sin contar como visto: vuelve a
    /// salir al desbloquear.
    static func suspend() {
        window?.isHidden = true
        window = nil
    }

    private static func finish(_ reminder: PaymentReminder, _ outcome: PaymentReminderModal.Outcome) {
        let reminders = PaymentReminders.shared
        reminders.markModalShown(reminder)
        if outcome == .paid {
            Task { await reminders.dismiss(reminder) }
        }
        suspend()
    }
}
