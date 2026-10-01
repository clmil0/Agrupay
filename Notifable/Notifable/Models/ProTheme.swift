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
        AppThemeColor.activeProTheme
    }

    /// El tema Pro que tiñe toda la app: el elegido, sólo en oscuro (los
    /// temas Pro fuerzan el modo oscuro; una vista previa en claro no lo lleva).
    static func ambient(_ scheme: ColorScheme) -> ProTheme? {
        scheme == .dark ? current : nil
    }

    /// La esfera de muestra: la misma que en el paywall y en Apariencia.
    var swatch: RadialGradient {
        switch self {
        case .nebula:
            return RadialGradient(colors: [tone(0xC084FC), tone(0x6D28D9), tone(0x06061A)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .obsidian:
            return RadialGradient(colors: [tone(0xF6E7B8), tone(0xB8892F), tone(0x0B0A08)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .aurora:
            return RadialGradient(colors: [tone(0xA5F3FC), tone(0x10B981), tone(0x04110F)],
                                  center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 34)
        case .sunset:
            return RadialGradient(colors: [tone(0xFDE68A), tone(0xFB7185), tone(0x3B0F2E)],
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
        case .nebula:   return tone(0x06061A)
        case .obsidian: return tone(0x0B0A08)
        case .aurora:   return tone(0x04110F)
        case .sunset:   return tone(0x1A0B14)
        }
    }

    /// Tarjetas: vidrio oscuro con un poco del cielo detrás.
    var surface: Color {
        switch self {
        case .nebula:   return tone(0x100E2C, opacity: 0.84)
        case .obsidian: return tone(0x15130E)
        case .aurora:   return tone(0x081E1B, opacity: 0.86)
        case .sunset:   return tone(0x2A0F1E, opacity: 0.86)
        }
    }

    /// Sheets y menús: el mismo vidrio, opaco y un punto más claro, para
    /// que se despeguen del fondo sin cielo detrás.
    var elevated: Color {
        switch self {
        case .nebula:   return tone(0x15133A)
        case .obsidian: return tone(0x1C1912)
        case .aurora:   return tone(0x0B2522)
        case .sunset:   return tone(0x2E1424)
        }
    }

    var hairline: Color {
        switch self {
        case .nebula:   return tone(0xBEAAFF, opacity: 0.16)
        case .obsidian: return tone(0xE9D29A, opacity: 0.22)
        case .aurora:   return tone(0x6EE7B7, opacity: 0.14)
        case .sunset:   return tone(0xFDBA74, opacity: 0.16)
        }
    }

    var label: Color {
        switch self {
        case .nebula:   return tone(0xF1EEFF)
        case .obsidian: return tone(0xF4EEDF)
        case .aurora:   return tone(0xE8FFF6)
        case .sunset:   return tone(0xFFF1E6)
        }
    }

    var secondaryLabel: Color {
        switch self {
        case .nebula:   return tone(0xA9A6CC)
        case .obsidian: return tone(0xA89F8A)
        case .aurora:   return tone(0x9CC3B6)
        case .sunset:   return tone(0xD6AFA6)
        }
    }

    var tertiaryLabel: Color {
        switch self {
        case .nebula:   return tone(0x8B88B0)
        case .obsidian: return tone(0x8C8471)
        case .aurora:   return tone(0x7FA79A)
        case .sunset:   return tone(0xB08C86)
        }
    }

    /// El acento: barras, globos, el + y lo elegido.
    var accent: Color { tone(accentHex) }

    private var accentHex: UInt32 {
        switch self {
        case .nebula:   return 0x8B5CF6
        case .obsidian: return 0xD4AF61
        case .aurora:   return 0x34D399
        case .sunset:   return 0xFB7185
        }
    }

    /// El acento como texto sobre las tarjetas (el monto de la barra, «3»).
    var accentText: Color {
        switch self {
        case .nebula:   return tone(0xC4B5FD)
        case .obsidian: return tone(0xE9D29A)
        case .aurora:   return tone(0x6EE7B7)
        case .sunset:   return tone(0xFDBA74)
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
        case .nebula:   return [tone(0x6D28D9), tone(0x8B5CF6), tone(0xC4B5FD)]
        case .obsidian: return [tone(0x6E5020), tone(0xD4AF61), tone(0xF6E7B8)]
        case .aurora:   return [tone(0x065F46), tone(0x34D399), tone(0xA5F3FC)]
        case .sunset:   return [tone(0x9F1239), tone(0xFB7185), tone(0xFDBA74), tone(0xFDE68A)]
        }
    }

    /// El + del Resumen.
    var fabGradient: [Color] {
        switch self {
        case .nebula:   return [tone(0x8B5CF6), tone(0xA78BFA)]
        case .obsidian: return [tone(0xB8892F), tone(0xF6E7B8)]
        case .aurora:   return [tone(0x10B981), tone(0x22D3EE)]
        case .sunset:   return [tone(0xFB7185), tone(0xF59E0B)]
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
            return [tone(0x8C6A2F), tone(0xE9D29A), tone(0xB8892F), tone(0xF6E7B8), tone(0x9A7430)]
        case .sunset:
            return [tone(0xFFF1E6), tone(0xFDBA74), tone(0xFB7185)]
        default:
            return nil
        }
    }
}

// MARK: - Matiz e intensidad del cielo

/// Una variante de un tema Pro: el mismo tema con el tono girado unos
/// grados. Sólo gira el tono —la luminosidad no cambia—, así que los textos
/// conservan el contraste que tenían.
struct ProThemeTone: Hashable, Identifiable {
    let name: String
    let degrees: Double
    var id: String { name }
}

extension ProTheme {

    /// La primera es la original.
    var tones: [ProThemeTone] {
        switch self {
        case .nebula:
            return [.init(name: "Violeta", degrees: 0), .init(name: "Índigo", degrees: -28),
                    .init(name: "Orquídea", degrees: 32), .init(name: "Azul cósmico", degrees: -50)]
        case .obsidian:
            return [.init(name: "Oro", degrees: 0), .init(name: "Champaña", degrees: 10),
                    .init(name: "Cobre", degrees: -18), .init(name: "Oro rosa", degrees: -35)]
        case .aurora:
            return [.init(name: "Esmeralda", degrees: 0), .init(name: "Glaciar", degrees: 35),
                    .init(name: "Jade", degrees: -15), .init(name: "Lima", degrees: -45)]
        case .sunset:
            return [.init(name: "Coral", degrees: 0), .init(name: "Ámbar", degrees: 25),
                    .init(name: "Fucsia", degrees: -30), .init(name: "Lavanda", degrees: -70)]
        }
    }

    /// El nombre de la variante elegida, uno por tema.
    var toneKey: String { "proThemeTone.\(rawValue)" }

    /// Cuánto se ve el cielo animado, de 0.2 (tenue) a 1 (vivo). Uno para
    /// todos los temas.
    static let skyIntensityKey = "proThemeSkyIntensity"
    static let skyIntensityRange: ClosedRange<Double> = 0.2...1

    /// Los grados de la variante elegida.
    var hueShift: Double { AppThemeColor.proHueShift(self) }

    /// Las variantes elegidas de todos los temas, para saber si cambiaron.
    static var toneSignature: String {
        allCases.map { String(AppThemeColor.proHueShift($0)) }.joined(separator: ",")
    }

    /// La intensidad elegida del cielo.
    static var skyIntensity: Double { AppThemeColor.proSkyIntensity }

    func tone(named name: String?) -> ProThemeTone {
        tones.first { $0.name == name } ?? tones[0]
    }

    /// El acento de una variante, para su muestra en Apariencia.
    func accent(for tone: ProThemeTone) -> Color {
        Self.shifted(accentHex, degrees: tone.degrees)
    }

    /// Un color del tema con la variante elegida aplicada.
    fileprivate func tone(_ hex: UInt32, opacity: Double = 1) -> Color {
        let shift = hueShift
        guard shift != 0 else { return Color(hex: hex, opacity: opacity) }
        return Self.shifted(hex, degrees: shift).opacity(opacity)
    }

    /// Gira el tono de un color en HSL, sin tocar saturación ni luminosidad.
    static func shifted(_ hex: UInt32, degrees: Double) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2, d = mx - mn
        guard d > 0 else { return Color(hex: hex) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h = (h * 60 + degrees).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60:  (r1, g1, b1) = (c, x, 0)
        case ..<120: (r1, g1, b1) = (x, c, 0)
        case ..<180: (r1, g1, b1) = (0, c, x)
        case ..<240: (r1, g1, b1) = (0, x, c)
        case ..<300: (r1, g1, b1) = (x, 0, c)
        default:     (r1, g1, b1) = (c, 0, x)
        }
        return Color(.sRGB, red: r1 + m, green: g1 + m, blue: b1 + m, opacity: 1)
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
