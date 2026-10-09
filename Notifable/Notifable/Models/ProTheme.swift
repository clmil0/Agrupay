import SwiftUI

/// Los temas Pro de Resumen: fondos animados que se eligen en Apariencia ›
/// Temas › Premium. Los de noche (`3b`–`3e`, Abismo y Orquídea) fuerzan el
/// modo oscuro; los de día (Perla, Alba, Glaciar, Marfil, Salvia y Peonía)
/// son su contraparte clara y fuerzan el claro.
enum ProTheme: String, CaseIterable, Identifiable {
    case nebula = "Nebulosa"
    case obsidian = "Obsidiana"
    case aurora = "Aurora"
    case sunset = "Atardecer"
    case abyss = "Abismo"
    case pearl = "Perla"
    case dawn = "Alba"
    case glacier = "Glaciar"
    case ivory = "Marfil"
    case sage = "Salvia"
    case peony = "Peonía"
    case orchid = "Orquídea"

    var id: String { rawValue }

    static let storageKey = "proTheme"

    /// En el orden de Apariencia.
    static let day: [ProTheme] = [.pearl, .dawn, .glacier, .ivory, .sage, .peony]
    static let night: [ProTheme] = [.nebula, .obsidian, .aurora, .sunset, .abyss, .orchid]

    /// Los de día: van en claro mientras se usan.
    var isLight: Bool { Self.day.contains(self) }

    /// El modo que impone el tema a toda la app.
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// El tema Pro en uso, sólo si hay Pro: sin él, Resumen vuelve al tema
    /// básico que estuviera elegido (el color de acento no se toca).
    static var current: ProTheme? {
        AppThemeColor.activeProTheme
    }

    /// El tema Pro que tiñe toda la app: el elegido, sólo en su modo (una
    /// vista previa en el modo contrario no lo lleva).
    static func ambient(_ scheme: ColorScheme) -> ProTheme? {
        guard let current, current.colorScheme == scheme else { return nil }
        return current
    }

    /// Una línea para Apariencia, debajo de la lista de temas.
    var blurb: String {
        switch self {
        case .nebula:   return "Nubes de color que respiran y estrellas."
        case .obsidian: return "Negro cálido con un halo de oro."
        case .aurora:   return "Cintas boreales sobre un cielo nocturno."
        case .sunset:   return "Un sol que late sobre el agua."
        case .abyss:    return "Medusas que laten en aguas profundas."
        case .pearl:    return "Nácar que gira, burbujas y destellos."
        case .dawn:     return "Cielo durazno con un sol que sube."
        case .glacier:  return "Facetas de hielo, un destello y nieve que cae."
        case .ivory:    return "Papel crema con grano y brillo de oro."
        case .sage:     return "Luz que se filtra entre hojas."
        case .peony:    return "Cielo rubor con pétalos que caen."
        case .orchid:   return "Una luna rosada que late y pétalos de luz."
        }
    }

    /// La esfera de muestra: la misma que en el paywall y en Apariencia.
    var swatch: RadialGradient {
        let (stops, center): ([UInt32], UnitPoint) = {
            switch self {
            case .nebula:   return ([0xC084FC, 0x6D28D9, 0x06061A], UnitPoint(x: 0.3, y: 0.3))
            case .obsidian: return ([0xF6E7B8, 0xB8892F, 0x0B0A08], UnitPoint(x: 0.3, y: 0.3))
            case .aurora:   return ([0xA5F3FC, 0x10B981, 0x04110F], UnitPoint(x: 0.3, y: 0.3))
            case .sunset:   return ([0xFDE68A, 0xFB7185, 0x3B0F2E], UnitPoint(x: 0.3, y: 0.7))
            case .abyss:    return ([0xCFFAFE, 0x22D3EE, 0x0E7490, 0x03141A], UnitPoint(x: 0.3, y: 0.3))
            case .pearl:    return ([0xFFFFFF, 0xF5C6E0, 0xC8B8FF, 0xA6E6D4], UnitPoint(x: 0.3, y: 0.3))
            case .dawn:     return ([0xFFF4D6, 0xFDBA74, 0xFFD9C2, 0xFFF1E6], UnitPoint(x: 0.7, y: 0.75))
            case .glacier:  return ([0xFFFFFF, 0xBFDDF7, 0x6FA9E8, 0x1F6FD1], UnitPoint(x: 0.3, y: 0.3))
            case .ivory:    return ([0xFFFFFF, 0xF6E7B8, 0xD4AF61, 0xB8892F], UnitPoint(x: 0.3, y: 0.3))
            case .sage:     return ([0xFFF6D6, 0xCFE6C8, 0x7FBF95, 0x3E9A6E], UnitPoint(x: 0.35, y: 0.3))
            case .peony:    return ([0xFFFFFF, 0xFFD0E1, 0xF28DB5, 0xE0608F], UnitPoint(x: 0.3, y: 0.3))
            case .orchid:   return ([0xFFF4FA, 0xF472B6, 0xA21D5E, 0x170A12], UnitPoint(x: 0.3, y: 0.3))
            }
        }()
        return RadialGradient(colors: stops.map { tone($0) }, center: center, startRadius: 0, endRadius: 34)
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
        case .abyss:    return tone(0x03141A)
        case .pearl:    return tone(0xFBF8FB)
        case .dawn:     return tone(0xFFF8F1)
        case .glacier:  return tone(0xF2F7FC)
        case .ivory:    return tone(0xFAF6EC)
        case .sage:     return tone(0xF5F8F3)
        case .peony:    return tone(0xFFF5F8)
        case .orchid:   return tone(0x170A12)
        }
    }

    /// Tarjetas: vidrio con un poco del cielo detrás. En los de día, vidrio
    /// blanco casi opaco, para que el texto secundario siga cumpliendo AA
    /// sobre el cielo.
    var surface: Color {
        switch self {
        case .nebula:   return tone(0x100E2C, opacity: 0.84)
        case .obsidian: return tone(0x15130E)
        case .aurora:   return tone(0x081E1B, opacity: 0.86)
        case .sunset:   return tone(0x2A0F1E, opacity: 0.86)
        case .abyss:    return tone(0x062028, opacity: 0.86)
        case .pearl:    return Color.white.opacity(0.80)
        case .dawn:     return Color.white.opacity(0.82)
        case .glacier:  return Color.white.opacity(0.86)
        case .ivory:    return Color(hex: 0xFFFDF7, opacity: 0.9)
        case .sage:     return Color.white.opacity(0.82)
        case .peony:    return Color.white.opacity(0.82)
        case .orchid:   return tone(0x2A0F22, opacity: 0.86)
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
        case .abyss:    return tone(0x092A33)
        case .orchid:   return tone(0x30122A)
        case .ivory:    return Color(hex: 0xFFFDF7)
        case .pearl, .dawn, .glacier, .sage, .peony: return .white
        }
    }

    var hairline: Color {
        switch self {
        case .nebula:   return tone(0xBEAAFF, opacity: 0.16)
        case .obsidian: return tone(0xE9D29A, opacity: 0.22)
        case .aurora:   return tone(0x6EE7B7, opacity: 0.14)
        case .sunset:   return tone(0xFDBA74, opacity: 0.16)
        case .abyss:    return tone(0x67E8F9, opacity: 0.16)
        case .pearl:    return tone(0x5B3FC4, opacity: 0.14)
        case .dawn:     return tone(0xB2431A, opacity: 0.14)
        case .glacier:  return tone(0x145096, opacity: 0.16)
        case .ivory:    return tone(0xB8892F, opacity: 0.30)
        case .sage:     return tone(0x1E6B50, opacity: 0.14)
        case .peony:    return tone(0xA82E62, opacity: 0.14)
        case .orchid:   return tone(0xF9A8D4, opacity: 0.16)
        }
    }

    /// El carril de las barras y de las pistas. En los de noche, el mismo
    /// hairline; en los de día un tono opaco propio, que se lee sobre el cielo.
    var track: Color {
        switch self {
        case .pearl:   return tone(0xDCD1EC)
        case .dawn:    return tone(0xF3E3D6)
        case .glacier: return tone(0xCCDBEB)
        case .ivory:   return tone(0xEEE6D3)
        case .sage:    return tone(0xE2EBDF)
        case .peony:   return tone(0xEDCDDB)
        default:       return hairline
        }
    }

    var label: Color {
        switch self {
        case .nebula:   return tone(0xF1EEFF)
        case .obsidian: return tone(0xF4EEDF)
        case .aurora:   return tone(0xE8FFF6)
        case .sunset:   return tone(0xFFF1E6)
        case .abyss:    return tone(0xE6FBFF)
        case .pearl:    return tone(0x1E1530)
        case .dawn:     return tone(0x2A1A12)
        case .glacier:  return tone(0x0B1A2E)
        case .ivory:    return tone(0x1F1A10)
        case .sage:     return tone(0x13241A)
        case .peony:    return tone(0x2A1420)
        case .orchid:   return tone(0xFFEEF6)
        }
    }

    var secondaryLabel: Color {
        switch self {
        case .nebula:   return tone(0xA9A6CC)
        case .obsidian: return tone(0xA89F8A)
        case .aurora:   return tone(0x9CC3B6)
        case .sunset:   return tone(0xD6AFA6)
        case .abyss:    return tone(0x9CC0C8)
        case .pearl:    return tone(0x665E74)
        case .dawn:     return tone(0x76594B)
        case .glacier:  return tone(0x4E5F73)
        case .ivory:    return tone(0x6B604A)
        case .sage:     return tone(0x56675C)
        case .peony:    return tone(0x775A67)
        case .orchid:   return tone(0xD3A9BD)
        }
    }

    var tertiaryLabel: Color {
        switch self {
        case .nebula:   return tone(0x8B88B0)
        case .obsidian: return tone(0x8C8471)
        case .aurora:   return tone(0x7FA79A)
        case .sunset:   return tone(0xB08C86)
        case .abyss:    return tone(0x7FA3AC)
        case .pearl:    return tone(0x8A8396)
        case .dawn:     return tone(0x987D70)
        case .glacier:  return tone(0x75849A)
        case .ivory:    return tone(0x8C826C)
        case .sage:     return tone(0x7B8A80)
        case .peony:    return tone(0x9A7E8A)
        case .orchid:   return tone(0xA9879A)
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
        case .abyss:    return 0x22D3EE
        case .pearl:    return 0x7B5BE6
        case .dawn:     return 0xF2683C
        case .glacier:  return 0x1F6FD1
        case .ivory:    return 0xB8892F
        case .sage:     return 0x3E9A6E
        case .peony:    return 0xE0608F
        case .orchid:   return 0xF472B6
        }
    }

    /// El acento como texto sobre las tarjetas (el monto de la barra, «3»).
    var accentText: Color {
        switch self {
        case .nebula:   return tone(0xC4B5FD)
        case .obsidian: return tone(0xE9D29A)
        case .aurora:   return tone(0x6EE7B7)
        case .sunset:   return tone(0xFDBA74)
        case .abyss:    return tone(0x67E8F9)
        case .pearl:    return tone(0x5B3FC4)
        case .dawn:     return tone(0xB2431A)
        case .glacier:  return tone(0x14569F)
        case .ivory:    return tone(0x8A5514)
        case .sage:     return tone(0x1E6B50)
        case .peony:    return tone(0xA82E62)
        case .orchid:   return tone(0xF9A8D4)
        }
    }

    /// Fondo tenue del acento: chips y el cuadrito del ícono de cuentas.
    var soft: Color { accent.opacity(isLight ? 0.14 : 0.22) }

    /// Neto positivo e ingresos. No gira con la variante: un ingreso no
    /// debe confundirse con el gasto.
    var positive: Color {
        switch self {
        case .nebula:   return Color(hex: 0x5EEAD4)
        case .obsidian: return Color(hex: 0xE9D29A)
        case .aurora:   return Color(hex: 0x6EE7B7)
        case .sunset:   return Color(hex: 0xFDE68A)
        case .abyss:    return Color(hex: 0xA7F3D0)
        case .pearl:    return Color(hex: 0x0F7F63)
        case .dawn:     return Color(hex: 0x1F7A4C)
        case .glacier:  return Color(hex: 0x0B7A6C)
        case .ivory:    return Color(hex: 0x5E7A2A)
        // Azul: el verde se confundiría con el acento.
        case .sage:     return Color(hex: 0x2A6FA8)
        case .peony:    return Color(hex: 0x1F7A5A)
        case .orchid:   return Color(hex: 0x99E6C8)
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
        case .abyss:    return .lightBlue
        case .pearl:    return .lilac
        case .dawn:     return .salmon
        case .glacier:  return .lightBlue
        case .ivory:    return .sand
        case .sage:     return .mint
        case .peony:    return .peony
        case .orchid:   return .peony
        }
    }

    /// La barra elegida del gráfico. Peonía la lleva entre el acento y su
    /// texto, para que se despegue del cielo rubor.
    var barAccent: Color {
        self == .peony ? tone(0xC44778) : accent
    }

    /// Obsidiana y Marfil escriben las cifras con serifa (New York).
    var usesSerifNumbers: Bool { self == .obsidian || self == .ivory }

    var numberDesign: Font.Design { usesSerifNumbers ? .serif : .default }

    /// El peso de las cifras grandes: la serifa va en medio, salvo Marfil,
    /// que necesita más peso sobre el crema.
    var numberWeight: Font.Weight {
        switch self {
        case .obsidian: return .medium
        default:        return .bold
        }
    }

    /// El espaciado del monto grande: la serifa no se aprieta tanto.
    var heroTracking: CGFloat { usesSerifNumbers ? -0.6 : -1.8 }

    /// Barras en cápsula: Obsidiana y su par de día.
    var barCornerRadius: CGFloat { usesSerifNumbers ? 40 : 5 }

    /// El monto grande con degradado, si el tema lo lleva.
    var amountGradient: LinearGradient? {
        func stops(_ list: [(UInt32, Double)]) -> [Gradient.Stop] {
            list.map { Gradient.Stop(color: tone($0.0), location: $0.1) }
        }
        switch self {
        case .obsidian:
            return LinearGradient(stops: stops([(0x8C6A2F, 0), (0xE9D29A, 0.25), (0xB8892F, 0.5), (0xF6E7B8, 0.75), (0x9A7430, 1)]),
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sunset:
            return LinearGradient(stops: stops([(0xFFF1E6, 0), (0xFDBA74, 0.5), (0xFB7185, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .abyss:
            return LinearGradient(stops: stops([(0xE6FBFF, 0.45), (0xA5F3FC, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .pearl:
            return LinearGradient(stops: stops([(0x2A1D52, 0), (0x5B3FC4, 0.45), (0xA8408A, 1)]),
                                  startPoint: .leading, endPoint: .trailing)
        case .dawn:
            return LinearGradient(stops: stops([(0x3A1E10, 0.3), (0xB2431A, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .glacier:
            return LinearGradient(stops: stops([(0x0B1A2E, 0.35), (0x14569F, 0.75), (0x2E86C8, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .ivory:
            return LinearGradient(stops: stops([(0x5E431A, 0), (0x9A7430, 0.3), (0x6E5020, 0.55), (0xB08A3E, 0.78), (0x5E431A, 1)]),
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sage:
            return LinearGradient(stops: stops([(0x13241A, 0.4), (0x1E6B50, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .peony:
            return LinearGradient(stops: stops([(0x3A1426, 0), (0xA82E62, 0.55), (0xD4568C, 1)]),
                                  startPoint: .leading, endPoint: .trailing)
        case .orchid:
            return LinearGradient(stops: stops([(0xFFEEF6, 0.35), (0xF9A8D4, 1)]),
                                  startPoint: .top, endPoint: .bottom)
        case .nebula, .aurora:
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
        case .obsidian, .ivory:
            return [.init(name: "Oro", degrees: 0), .init(name: "Champaña", degrees: 10),
                    .init(name: "Cobre", degrees: -18), .init(name: "Oro rosa", degrees: -35)]
        case .aurora:
            return [.init(name: "Esmeralda", degrees: 0), .init(name: "Glaciar", degrees: 35),
                    .init(name: "Jade", degrees: -15), .init(name: "Lima", degrees: -45)]
        case .sunset:
            return [.init(name: "Coral", degrees: 0), .init(name: "Ámbar", degrees: 25),
                    .init(name: "Fucsia", degrees: -30), .init(name: "Lavanda", degrees: -70)]
        case .abyss:
            return [.init(name: "Cian", degrees: 0), .init(name: "Turquesa", degrees: -18),
                    .init(name: "Azul abisal", degrees: 28), .init(name: "Violeta abisal", degrees: 75)]
        case .pearl:
            return [.init(name: "Nácar", degrees: 0), .init(name: "Ópalo", degrees: 30),
                    .init(name: "Rosa perla", degrees: -35), .init(name: "Menta perla", degrees: 140)]
        case .dawn:
            return [.init(name: "Durazno", degrees: 0), .init(name: "Miel", degrees: 18),
                    .init(name: "Rosa alba", degrees: -25), .init(name: "Lila alba", degrees: -60)]
        case .glacier:
            return [.init(name: "Hielo", degrees: 0), .init(name: "Turquesa", degrees: -25),
                    .init(name: "Índigo", degrees: 25), .init(name: "Lavanda", degrees: 50)]
        case .sage:
            return [.init(name: "Salvia", degrees: 0), .init(name: "Eucalipto", degrees: 25),
                    .init(name: "Oliva", degrees: -30), .init(name: "Musgo", degrees: -15)]
        case .peony:
            return [.init(name: "Peonía", degrees: 0), .init(name: "Cereza", degrees: -14),
                    .init(name: "Malva", degrees: 28), .init(name: "Coral", degrees: -32)]
        case .orchid:
            return [.init(name: "Orquídea", degrees: 0), .init(name: "Cereza", degrees: -14),
                    .init(name: "Malva", degrees: 28), .init(name: "Coral", degrees: -32)]
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
