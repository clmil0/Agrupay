import SwiftUI

/// Paleta con contraste verificado. Reemplaza a `Color.primary.opacity(0.05)`.
///
/// El problema del diseño anterior: en modo claro `primary.opacity(0.05)` es
/// #F2F2F2 sobre blanco — una diferencia de luminancia de ~4%, invisible en
/// pantalla al sol o con brillo bajo. Y `primary.opacity(0.7)` como texto
/// secundario sobre ese fondo queda por debajo de 4.5:1.
///
/// Aquí las superficies son **opacas** y llevan un borde de 0.5 pt, y el texto
/// secundario usa valores que cumplen AA (≥ 4.5:1 sobre su propia superficie).
struct Palette {

    let scheme: ColorScheme
    /// El tema de color vigente. Tiñe superficies y bordes (`1c`): el tema se
    /// nota en toda la app sin pintar bordes del color del acento.
    let accent: AppThemeColor
    /// Ajustes › Apariencia › Intensificar el color del tema. Apagado, las
    /// superficies y bordes son los grises neutros de siempre.
    let intense: Bool

    /// Tema Pro (`3b`–`3e`). Lo lleva toda la app en oscuro: superficies,
    /// textos y acento salen del tema; el cielo animado completo queda para
    /// el Resumen y el resto lo lleva atenuado (`ProThemeBackdrop.calm`).
    private(set) var pro: ProTheme?

    init(_ scheme: ColorScheme, accent: AppThemeColor = .current,
         intense: Bool = AppThemeColor.usesIntenseTint,
         pro: ProTheme? = nil) {
        self.scheme = scheme
        self.accent = accent
        self.intense = intense
        self.pro = pro ?? ProTheme.ambient(scheme)
    }

    /// La misma paleta con los colores del tema Pro, si lo hay. Sin tema en
    /// el entorno se queda con el de la app (`nil` no lo apaga).
    func themed(_ pro: ProTheme?) -> Palette {
        guard let pro else { return self }
        var copy = self
        copy.pro = pro
        return copy
    }

    /// La paleta del tema básico, sin el Pro: para mostrar cómo se ve un
    /// tema básico mientras hay uno Pro puesto (la galería de Apariencia).
    func withoutPro() -> Palette {
        var copy = self
        copy.pro = nil
        return copy
    }

    private var dark: Bool { scheme == .dark }

    /// Fondo de pantalla. En oscuro, el negro azulado del dashboard (`1b`):
    /// no es el negro puro de OLED, y por eso las tarjetas se despegan de él
    /// por tono sin necesitar sombra.
    var background: Color {
        if let pro { return pro.base }
        return dark ? Color(red: 0.043, green: 0.055, blue: 0.078)   // #0B0E14
             : Color.white
    }

    /// Superficie de tarjeta **neutra**, sin tinte. Para lo que se pinta
    /// encima de una tarjeta ya tintada o necesita el gris de siempre.
    var neutralSurface: Color {
        if let pro { return pro.surface }
        return dark ? Color(red: 0.086, green: 0.098, blue: 0.133)   // #161922
             : Color(red: 0.969, green: 0.969, blue: 0.976)   // #F7F7F9
    }

    /// Superficie de tarjeta: el gris opaco de siempre con un tinte ligero del
    /// tema. Opaca a propósito —mezclada, no con transparencia—, para que lo
    /// que pase por debajo al hacer scroll no se transparente.
    var surface: Color {
        if let pro { return pro.surface }
        guard intense else { return neutralSurface }
        return neutralSurface.mixed(with: accent.color, amount: dark ? 0.10 : 0.06, scheme: scheme)
    }

    /// Superficie elevada (sheets, menús).
    var surfaceElevated: Color {
        if let pro { return pro.elevated }
        return dark ? Color(red: 0.118, green: 0.133, blue: 0.176)   // #1E222D
             : Color.white
    }

    /// Relleno del elemento elegido dentro de un control oscuro (la opción
    /// activa de «Semana · Mes», la tarjeta «Todas» del carrusel).
    var selectedFill: Color {
        if let pro { return pro.accent.opacity(0.24) }
        return dark ? Color(red: 0.137, green: 0.157, blue: 0.220)   // #232838
             : Color(red: 0.898, green: 0.906, blue: 0.925)
    }

    /// Borde de 0.5 pt que separa la tarjeta del fondo. Sigue siendo el
    /// hairline gris, con apenas un toque del tema: nunca un borde del color
    /// del acento.
    var hairline: Color {
        if let pro { return pro.hairline }
        guard intense else { return dark ? Color.white.opacity(0.07) : Color.black.opacity(0.10) }
        let base: Color = dark ? .white : .black
        return base.mixed(with: accent.color, amount: 0.30, scheme: scheme)
            .opacity(dark ? 0.14 : 0.11)
    }

    /// Separador interno de listas.
    var separator: Color {
        if let pro { return pro.hairline.opacity(0.7) }
        return dark ? Color.white.opacity(0.06) : Color.black.opacity(0.10)
    }

    var label: Color {
        if let pro { return pro.label }
        return dark ? Color(red: 0.929, green: 0.941, blue: 0.957)   // #EDF0F4
             : .black
    }

    /// Texto secundario legible: #AEAEB2 sobre #1C1C1E = 6.1:1;
    /// #6C6C70 sobre #F7F7F9 = 5.4:1. (Antes: 3.1:1 y 3.6:1.)
    var secondaryLabel: Color {
        if let pro { return pro.secondaryLabel }
        return dark ? Color(red: 0.604, green: 0.639, blue: 0.698)   // #9AA3B2
             : Color(red: 0.424, green: 0.424, blue: 0.439)   // #6C6C70
    }

    /// Terciario, sólo para marcas de tiempo y placeholders.
    var tertiaryLabel: Color {
        if let pro { return pro.tertiaryLabel }
        return dark ? Color(red: 0.541, green: 0.576, blue: 0.639)   // #8A93A3
             : Color(red: 0.557, green: 0.557, blue: 0.576)
    }

    /// Relleno de barras de progreso y pistas de gráficos.
    var track: Color {
        if let pro { return pro.hairline }
        return dark ? Color(red: 0.165, green: 0.196, blue: 0.259)   // #2A3242
             : Color(red: 0.890, green: 0.890, blue: 0.909)
    }

    /// Barras del periodo anterior en los gráficos comparativos.
    var comparison: Color {
        if let pro { return pro.secondaryLabel.opacity(0.35) }
        return dark ? Color(red: 0.227, green: 0.263, blue: 0.337)   // #3A4356
             : Color(red: 0.788, green: 0.804, blue: 0.839)
    }

    // MARK: Gasto e ingreso

    /// El color del gasto ahora sigue al tema.
    var expense: Color { pro?.accent ?? accent.color }

    /// Un punto más claro que el gasto, del mismo tono.
    var expenseLight: Color { pro?.accentText ?? accent.color.shiftedHSL(lightness: 0.10, scheme: scheme) }

    /// Texto en el segundo acento, sólo en los temas de dos colores (`nil` en
    /// los demás, que se quedan con su gris). Títulos de las tiras, el
    /// monto sobre la barra elegida, el «vs. mes pasado» y las flechas del
    /// resumen.
    var duoText: Color? {
        // Los temas Pro son de un acento: títulos y flechas en gris.
        if pro != nil { return nil }
        return accent.isDuotone ? accent.secondaryOnSurface(scheme) : nil
    }

    /// Color para texto de gasto sobre la superficie con contraste verificado.
    var expenseText: Color { pro?.accentText ?? accent.onSurface(scheme) }

    /// Fondo del chip de delta de gasto.
    /// Con tema Pro va oscuro y translúcido: el chip cae sobre el cielo, que
    /// puede ser claro (el sol de Atardecer).
    var expenseSoft: Color { pro.map { $0.base.opacity(0.55) } ?? accent.color.opacity(dark ? 0.16 : 0.12) }

    /// El ingreso. En los temas de dos colores es el segundo acento —el gasto
    /// ya es el primero—, así ingreso, Neto positivo y deltas a la baja
    /// llevan los dos colores del tema. En los de un color, el verde de
    /// siempre: un segundo tono derivado se confundiría con el gasto.
    var income: Color {
        if let pro { return pro.positive }
        if accent.isDuotone {
            return dark ? accent.secondaryColor : accent.secondaryOnSurface(scheme)
        }
        return dark ? Color(red: 0.063, green: 0.725, blue: 0.506)            // #10B981
                    : Color(red: 0.020, green: 0.588, blue: 0.412)            // #059669
    }

    var incomeSoft: Color { income.opacity(dark ? 0.16 : 0.12) }

    var positive: Color { income }
    var negative: Color { dark ? Color(red: 1.0, green: 0.412, blue: 0.380) : Color(red: 0.659, green: 0.118, blue: 0.082) }
    var warning: Color { dark ? Color(red: 1.0, green: 0.624, blue: 0.039) : Color(red: 0.702, green: 0.416, blue: 0.0) }
}

extension EnvironmentValues {
    var palette: Palette {
        Palette(self.colorScheme)
    }
}

// MARK: - Mezcla de colores

extension Color {

    /// Componentes RGB resueltos para el esquema dado — los colores de sistema
    /// (`.purple`, `.orange`) cambian entre claro y oscuro.
    func rgb(_ scheme: ColorScheme) -> (r: Double, g: Double, b: Double) {
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let resolved = UIColor(self).resolvedColor(with: traits)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    /// Mezcla opaca: `amount` 0 es este color, 1 es `other`.
    func mixed(with other: Color, amount: Double, scheme: ColorScheme) -> Color {
        let a = rgb(scheme), b = other.rgb(scheme)
        let t = min(1, max(0, amount))
        return Color(red: a.r + (b.r - a.r) * t,
                     green: a.g + (b.g - a.g) * t,
                     blue: a.b + (b.b - a.b) * t)
    }

    /// Desplaza tono (grados), saturación y luminosidad en HSL — la misma
    /// fórmula del diseño `1c` para derivar la rampa de categorías.
    func shiftedHSL(hue dh: Double = 0, saturation ds: Double = 0, lightness dl: Double = 0,
                    scheme: ColorScheme) -> Color {
        let (r, g, b) = rgb(scheme)
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
        }
        h = (h + dh).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let s2 = min(1, max(0, s + ds))
        let l2 = min(1, max(0, l + dl))
        let c = (1 - abs(2 * l2 - 1)) * s2
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l2 - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60:  (r1, g1, b1) = (c, x, 0)
        case ..<120: (r1, g1, b1) = (x, c, 0)
        case ..<180: (r1, g1, b1) = (0, c, x)
        case ..<240: (r1, g1, b1) = (0, x, c)
        case ..<300: (r1, g1, b1) = (x, 0, c)
        default:     (r1, g1, b1) = (c, 0, x)
        }
        return Color(red: r1 + m, green: g1 + m, blue: b1 + m)
    }
}

extension AppThemeColor {

    /// Color de relleno (botones, barras, chips activos). El color del sistema.
    var fill: Color { color }

    /// Color para **texto e iconos sobre fondo claro**. `systemPurple` sobre
    /// blanco da 3.4:1 y no cumple AA para texto; esta variante sí.
    func onSurface(_ scheme: ColorScheme) -> Color {
        guard scheme == .light else {
            if let pro = Self.activeProTheme, pro.companionAccent == self { return pro.accentText }
            return tintOnDark
        }
        switch self {
        case .purple: return Color(red: 0.478, green: 0.235, blue: 0.600)   // #7A3C99
        case .blue:   return Color(red: 0.000, green: 0.349, blue: 0.698)   // #0059B2
        case .green:  return Color(red: 0.114, green: 0.498, blue: 0.235)   // #1D7F3C
        case .orange: return Color(red: 0.702, green: 0.416, blue: 0.000)   // #B36A00
        case .red:    return Color(red: 0.659, green: 0.118, blue: 0.082)   // #A81E15
        case .charcoal: return Color(red: 0.110, green: 0.110, blue: 0.118) // #1C1C1E
        case .lavender: return Color(red: 0.357, green: 0.271, blue: 0.722) // #5B45B8
        case .peach:    return Color(red: 0.659, green: 0.267, blue: 0.122) // #A8441F
        case .sky:      return Color(red: 0.106, green: 0.353, blue: 0.612) // #1B5A9C
        case .rose:     return Color(red: 0.631, green: 0.192, blue: 0.353) // #A1315A
        case .lilac:     return Color(red: 0.357, green: 0.271, blue: 0.722) // #5B45B8
        case .mint:      return Color(red: 0.118, green: 0.478, blue: 0.388) // #1E7A63
        case .salmon:    return Color(red: 0.659, green: 0.267, blue: 0.122) // #A8441F
        case .lightBlue: return Color(red: 0.106, green: 0.353, blue: 0.612) // #1B5A9C
        case .pink:      return Color(red: 0.631, green: 0.192, blue: 0.353) // #A1315A
        case .sand:      return Color(red: 0.541, green: 0.333, blue: 0.078) // #8A5514
        }
    }

    /// Variante clara para texto sobre fondo oscuro.
    private var tintOnDark: Color {
        switch self {
        case .purple: return Color(red: 0.847, green: 0.651, blue: 0.941)   // #D8A6F0
        case .blue:   return Color(red: 0.392, green: 0.702, blue: 1.000)
        case .green:  return Color(red: 0.561, green: 0.890, blue: 0.658)
        case .orange: return Color(red: 1.000, green: 0.749, blue: 0.373)
        case .red:    return Color(red: 1.000, green: 0.541, blue: 0.510)
        case .charcoal: return Color(red: 0.820, green: 0.820, blue: 0.839) // #D1D1D6
        case .lavender: return Color(red: 0.796, green: 0.757, blue: 0.984) // #CBC1FB
        case .peach:    return Color(red: 0.984, green: 0.780, blue: 0.702) // #FBC7B3
        case .sky:      return Color(red: 0.722, green: 0.847, blue: 0.973) // #B8D8F8
        case .rose:     return Color(red: 0.973, green: 0.776, blue: 0.839) // #F8C6D6
        case .lilac:     return Color(red: 0.796, green: 0.757, blue: 0.984) // #CBC1FB
        case .mint:      return Color(red: 0.624, green: 0.906, blue: 0.824) // #9FE7D2
        case .salmon:    return Color(red: 0.984, green: 0.780, blue: 0.702) // #FBC7B3
        case .lightBlue: return Color(red: 0.722, green: 0.847, blue: 0.973) // #B8D8F8
        case .pink:      return Color(red: 0.973, green: 0.776, blue: 0.839) // #F8C6D6
        case .sand:      return Color(red: 0.949, green: 0.827, blue: 0.675) // #F2D3AC
        }
    }

    /// Fondo tenue para chips y banners de acento. Los temas pastel usan un
    /// tinte propio en claro (el genérico queda muy débil sobre blanco); en
    /// oscuro la fórmula genérica (20%) ya coincide con el diseño.
    func softFill(_ scheme: ColorScheme) -> Color {
        guard scheme == .light, isPastel else {
            return color.opacity(scheme == .dark ? 0.20 : 0.14)
        }
        switch self {
        case .lavender: return Color(red: 0.929, green: 0.918, blue: 0.984) // #EDEAFB
        case .peach:    return Color(red: 0.992, green: 0.929, blue: 0.906) // #FDEDE7
        case .sky:      return Color(red: 0.914, green: 0.949, blue: 0.988) // #E9F2FC
        case .rose:     return Color(red: 0.984, green: 0.922, blue: 0.945) // #FBEBF1
        case .lilac:     return Color(red: 0.929, green: 0.918, blue: 0.984) // #EDEAFB
        case .mint:      return Color(red: 0.902, green: 0.965, blue: 0.945) // #E6F6F1
        case .salmon:    return Color(red: 0.992, green: 0.929, blue: 0.906) // #FDEDE7
        case .lightBlue: return Color(red: 0.914, green: 0.949, blue: 0.988) // #E9F2FC
        case .pink:      return Color(red: 0.984, green: 0.922, blue: 0.945) // #FBEBF1
        case .sand:      return Color(red: 0.984, green: 0.945, blue: 0.894) // #FBF1E4
        default:        return color.opacity(0.14)
        }
    }

    // MARK: - Acento 2 (temas pastel de dos colores)

    /// Segundo acento con roles fijos: ingresos, hoy en el scrubber, badge de
    /// Pendientes, suscripciones, deltas a la baja. En los temas de un solo
    /// color no existe un segundo acento, así que cae de vuelta al primero —
    /// esas pantallas se ven exactamente igual que hoy.
    var secondaryColor: Color {
        switch self {
        case .lavender: return Color(red: 0.498, green: 0.847, blue: 0.741) // #7FD8BD
        case .peach:    return Color(red: 0.561, green: 0.737, blue: 0.910) // #8FBCE8
        case .sky:      return Color(red: 0.929, green: 0.780, blue: 0.608) // #EDC79B
        case .rose:     return Color(red: 0.592, green: 0.824, blue: 0.714) // #97D2B6
        default: return color
        }
    }

    func secondaryOnSurface(_ scheme: ColorScheme) -> Color {
        guard isDuotone else { return onSurface(scheme) }
        guard scheme == .light else {
            switch self {
            case .lavender: return Color(red: 0.624, green: 0.906, blue: 0.824) // #9FE7D2
            case .peach:    return Color(red: 0.733, green: 0.847, blue: 0.957) // #BBD8F4
            case .sky:      return Color(red: 0.949, green: 0.827, blue: 0.675) // #F2D3AC
            case .rose:     return Color(red: 0.706, green: 0.890, blue: 0.804) // #B4E3CD
            default: return secondaryColor
            }
        }
        switch self {
        case .lavender: return Color(red: 0.118, green: 0.478, blue: 0.388) // #1E7A63
        case .peach:    return Color(red: 0.141, green: 0.333, blue: 0.514) // #245583
        case .sky:      return Color(red: 0.541, green: 0.333, blue: 0.078) // #8A5514
        case .rose:     return Color(red: 0.122, green: 0.420, blue: 0.314) // #1F6B50
        default: return secondaryColor
        }
    }

    /// El color del ingreso, para rellenar un ícono o un chip: el segundo
    /// acento en los temas de dos colores, el verde en los demás.
    var incomeFillColor: Color { Palette(.dark, accent: self).income }

    /// El color del ingreso para texto o un ícono suelto sobre la superficie.
    func incomeColor(_ scheme: ColorScheme) -> Color { Palette(scheme, accent: self).income }

    func secondarySoftFill(_ scheme: ColorScheme) -> Color {
        guard isDuotone else { return softFill(scheme) }
        guard scheme == .light else { return secondaryColor.opacity(0.18) }
        switch self {
        case .lavender: return Color(red: 0.902, green: 0.965, blue: 0.945) // #E6F6F1
        case .peach:    return Color(red: 0.910, green: 0.945, blue: 0.980) // #E8F1FA
        case .sky:      return Color(red: 0.984, green: 0.945, blue: 0.894) // #FBF1E4
        case .rose:     return Color(red: 0.914, green: 0.961, blue: 0.937) // #E9F5EF
        default: return secondaryColor.opacity(0.14)
        }
    }
}

/// Tarjeta estándar: superficie opaca + borde hairline. Un solo modificador
/// para que ninguna pantalla vuelva a inventar su propio fondo.
struct SurfaceCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    /// Sólo para redibujar la tarjeta al cambiar de tema: `Palette` lo lee.
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @Environment(\.proTheme) private var proTheme
    var radius: CGFloat = 18
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let palette = Palette(scheme).themed(proTheme)
        return content
            .padding(padding)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
    }
}

extension View {
    func surfaceCard(radius: CGFloat = 18, padding: CGFloat = 16) -> some View {
        modifier(SurfaceCard(radius: radius, padding: padding))
    }
}
