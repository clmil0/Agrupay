import SwiftUI
import UIKit

/// Detalles que sólo tiene quien es Pro sin tema Pro elegido: el tema básico
/// sigue igual, pero se siente más cuidado. Con un tema Pro puesto, el tema
/// ya se encarga (sus propios degradados y brillos).
enum ProTouches {

    /// Pro y en el tema básico: los degradados y el brillo del Resumen.
    static func isActive(isPro: Bool, theme: ProTheme?) -> Bool {
        isPro && theme == nil
    }

    // MARK: - Degradado del acento

    /// El acento y un vecino en la rueda: en dos colores, el acento 2; en
    /// Carbón (sin tono que girar), sólo un punto más claro.
    static func accentGradient(_ accent: AppThemeColor, _ scheme: ColorScheme) -> [Color] {
        let base = accent.color
        let partner: Color
        if accent.isDuotone {
            partner = accent.secondaryColor
        } else if accent == .charcoal {
            partner = base.shiftedHSL(lightness: 0.18, scheme: scheme)
        } else {
            partner = base.shiftedHSL(hue: -32, saturation: 0.05, lightness: 0.08, scheme: scheme)
        }
        return [base, partner]
    }

    // MARK: - Brillo del monto

    private static let shimmerDayKey = "proShimmerDay"

    /// Una vez al día: la primera vez que se ve el Resumen.
    static func claimDailyShimmer() -> Bool {
        let today = AssistantBrief.dayKey(Date())
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: shimmerDayKey) != today else { return false }
        defaults.set(today, forKey: shimmerDayKey)
        return true
    }
}

// MARK: - Haptics

/// Vibraciones más finas para Pro en los momentos que cierran algo. Sin Pro
/// no suena nada nuevo: cada llamada es un no-op.
enum ProHaptics {

    enum Event {
        /// Etiquetar un gasto con una categoría.
        case categorized
        /// Dividir un gasto en partes.
        case split
        /// Saldar una deuda entre amigos.
        case settled
        /// Confirmar un pendiente (gasto recurrente).
        case confirmed
        /// El brillo del monto del Resumen.
        case shimmer
    }

    @MainActor
    static func play(_ event: Event) {
        guard ProStore.isPro else { return }
        switch event {
        case .categorized:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.75)
        case .split:
            // Un toque seco por el corte y uno suave cuando las partes caen.
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.6)
            after(0.09) { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9) }
        case .settled:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            after(0.22) { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5) }
        case .confirmed:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
        case .shimmer:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.45)
        }
    }

    @MainActor
    private static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }
}

// MARK: - Brillo

/// Una franja de luz que cruza el contenido en diagonal, recortada a su
/// forma (sólo toca las cifras, no el fondo). Pasa cada vez que cambia
/// `trigger`.
struct ProShimmer: ViewModifier {
    let trigger: Int
    let tint: Color

    @State private var phase: CGFloat = 0
    @State private var running = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let band = max(geo.size.width * 0.35, 60)
                    LinearGradient(colors: [tint.opacity(0), tint.opacity(0.85), tint.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: band, height: geo.size.height * 2)
                        .rotationEffect(.degrees(18))
                        .offset(x: -band + phase * (geo.size.width + band * 2),
                                y: -geo.size.height / 2)
                        .opacity(running ? 1 : 0)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onChange(of: trigger) { _, _ in
                phase = 0
                running = true
                withAnimation(.easeInOut(duration: 1.1)) {
                    phase = 1
                } completion: {
                    running = false
                    phase = 0
                }
            }
    }
}

extension View {
    func proShimmer(trigger: Int, tint: Color) -> some View {
        modifier(ProShimmer(trigger: trigger, tint: tint))
    }
}
