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

// MARK: - Colores de cada tema

extension ProTheme {

    /// El fondo liso sobre el que se dibuja el cielo, y el color del
    /// degradado al pie (detrás del + y de Dictar).
    var base: Color {
        switch self {
        case .nebula:   return Color(hex: 0x06061A)
        case .obsidian: return Color(hex: 0x0B0A08)
        case .aurora:   return Color(hex: 0x04110F)
        case .sunset:   return Color(hex: 0x1A0B14)
        }
    }

    /// Tarjetas: vidrio oscuro con un poco del cielo detrás.
    var surface: Color {
        switch self {
        case .nebula:   return Color(red: 16 / 255, green: 14 / 255, blue: 44 / 255).opacity(0.84)
        case .obsidian: return Color(hex: 0x15130E)
        case .aurora:   return Color(red: 8 / 255, green: 30 / 255, blue: 27 / 255).opacity(0.86)
        case .sunset:   return Color(red: 42 / 255, green: 15 / 255, blue: 30 / 255).opacity(0.86)
        }
    }

    var hairline: Color {
        switch self {
        case .nebula:   return Color(red: 190 / 255, green: 170 / 255, blue: 1).opacity(0.16)
        case .obsidian: return Color(red: 233 / 255, green: 210 / 255, blue: 154 / 255).opacity(0.22)
        case .aurora:   return Color(red: 110 / 255, green: 231 / 255, blue: 183 / 255).opacity(0.14)
        case .sunset:   return Color(red: 253 / 255, green: 186 / 255, blue: 116 / 255).opacity(0.16)
        }
    }

    var label: Color {
        switch self {
        case .nebula:   return Color(hex: 0xF1EEFF)
        case .obsidian: return Color(hex: 0xF4EEDF)
        case .aurora:   return Color(hex: 0xE8FFF6)
        case .sunset:   return Color(hex: 0xFFF1E6)
        }
    }

    var secondaryLabel: Color {
        switch self {
        case .nebula:   return Color(hex: 0xA9A6CC)
        case .obsidian: return Color(hex: 0xA89F8A)
        case .aurora:   return Color(hex: 0x9CC3B6)
        case .sunset:   return Color(hex: 0xD6AFA6)
        }
    }

    var tertiaryLabel: Color {
        switch self {
        case .nebula:   return Color(hex: 0x8B88B0)
        case .obsidian: return Color(hex: 0x8C8471)
        case .aurora:   return Color(hex: 0x7FA79A)
        case .sunset:   return Color(hex: 0xB08C86)
        }
    }

    /// El acento: barras, globos, el + y lo elegido.
    var accent: Color {
        switch self {
        case .nebula:   return Color(hex: 0x8B5CF6)
        case .obsidian: return Color(hex: 0xD4AF61)
        case .aurora:   return Color(hex: 0x34D399)
        case .sunset:   return Color(hex: 0xFB7185)
        }
    }

    /// El acento como texto sobre las tarjetas (el monto de la barra, «3»).
    var accentText: Color {
        switch self {
        case .nebula:   return Color(hex: 0xC4B5FD)
        case .obsidian: return Color(hex: 0xE9D29A)
        case .aurora:   return Color(hex: 0x6EE7B7)
        case .sunset:   return Color(hex: 0xFDBA74)
        }
    }

    /// Neto positivo e ingresos.
    var positive: Color {
        switch self {
        case .nebula:   return Color(hex: 0x5EEAD4)
        case .obsidian: return Color(hex: 0xE9D29A)
        case .aurora:   return Color(hex: 0x6EE7B7)
        case .sunset:   return Color(hex: 0xFDE68A)
        }
    }

    /// De abajo arriba, la barra elegida del gráfico.
    var barGradient: [Color] {
        switch self {
        case .nebula:   return [Color(hex: 0x6D28D9), Color(hex: 0x8B5CF6), Color(hex: 0xC4B5FD)]
        case .obsidian: return [Color(hex: 0x6E5020), Color(hex: 0xD4AF61), Color(hex: 0xF6E7B8)]
        case .aurora:   return [Color(hex: 0x065F46), Color(hex: 0x34D399), Color(hex: 0xA5F3FC)]
        case .sunset:   return [Color(hex: 0x9F1239), Color(hex: 0xFB7185), Color(hex: 0xFDBA74), Color(hex: 0xFDE68A)]
        }
    }

    /// El + del Resumen.
    var fabGradient: [Color] {
        switch self {
        case .nebula:   return [Color(hex: 0x8B5CF6), Color(hex: 0xA78BFA)]
        case .obsidian: return [Color(hex: 0xB8892F), Color(hex: 0xF6E7B8)]
        case .aurora:   return [Color(hex: 0x10B981), Color(hex: 0x22D3EE)]
        case .sunset:   return [Color(hex: 0xFB7185), Color(hex: 0xF59E0B)]
        }
    }

    /// El tema básico más parecido: lo toma el resto de la app (botones,
    /// interruptores, pantallas apiladas), que no lleva el cielo del Resumen.
    var companionAccent: AppThemeColor {
        switch self {
        case .nebula:   return .purple
        case .obsidian: return .sand
        case .aurora:   return .mint
        case .sunset:   return .salmon
        }
    }

    /// Obsidiana escribe las cifras con serifa (New York).
    var numberDesign: Font.Design { self == .obsidian ? .serif : .default }

    /// El monto grande: oro pulido en Obsidiana, cielo cálido en Atardecer.
    var amountGradient: [Color]? {
        switch self {
        case .obsidian:
            return [Color(hex: 0x8C6A2F), Color(hex: 0xE9D29A), Color(hex: 0xB8892F), Color(hex: 0xF6E7B8), Color(hex: 0x9A7430)]
        case .sunset:
            return [Color(hex: 0xFFF1E6), Color(hex: 0xFDBA74), Color(hex: 0xFB7185)]
        default:
            return nil
        }
    }
}

extension EnvironmentValues {
    /// El tema Pro del Resumen. Sólo lo pone el dashboard: fuera de él es
    /// `nil` y todo se dibuja con la paleta de siempre.
    @Entry var proTheme: ProTheme? = nil
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
