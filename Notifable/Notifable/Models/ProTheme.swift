import SwiftUI

/// Los temas Pro de Resumen (`3b`–`3e`): fondos animados que se eligen en
/// Apariencia, en la fila «Premium · con fondo animado».
enum ProTheme: String, CaseIterable, Identifiable {
    case nebula = "Nebulosa"
    case obsidian = "Obsidiana"
    case aurora = "Aurora"
    case sunset = "Atardecer"

    var id: String { rawValue }

    static let storageKey = "proTheme"

    /// El tema Pro en uso, sólo si hay Pro: sin él, Resumen vuelve al tema
    /// básico que estuviera elegido (el color de acento no se toca).
    static var current: ProTheme? {
        guard ProStore.isPro else { return nil }
        return ProTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "")
    }

    /// La esfera de muestra: la misma que en el paywall y en Apariencia.
    var swatch: RadialGradient {
        switch self {
        case .nebula:
            return RadialGradient(colors: [Color(hex: 0xC084FC), Color(hex: 0x6D28D9), Color(hex: 0x06061A)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .obsidian:
            return RadialGradient(colors: [Color(hex: 0xF6E7B8), Color(hex: 0xB8892F), Color(hex: 0x0B0A08)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .aurora:
            return RadialGradient(colors: [Color(hex: 0xA5F3FC), Color(hex: 0x10B981), Color(hex: 0x04110F)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .sunset:
            return RadialGradient(colors: [Color(hex: 0xFDE68A), Color(hex: 0xFB7185), Color(hex: 0x3B0F2E)],
                                  center: UnitPoint(x: 0.3, y: 0.7), startRadius: 0, endRadius: 34)
        }
    }
}

/// La esfera de un tema Pro, con su chispa en la esquina.
struct ProThemeSwatch: View {
    let theme: ProTheme
    var size: CGFloat = 40
    var sparkle = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(theme.swatch)
                .frame(width: size, height: size)
                .scaleEffect(size / 40)
                .frame(width: size, height: size)
            if sparkle {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.24, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityLabel(theme.rawValue)
    }
}

extension Color {
    /// `Color(hex: 0x0A84FF)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
