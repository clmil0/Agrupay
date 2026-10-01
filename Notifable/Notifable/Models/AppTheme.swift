import SwiftUI

enum AppThemeColor: String, CaseIterable, Identifiable {
    case purple = "Morado"
    case blue = "Azul"
    case green = "Verde"
    case orange = "Naranja"
    case red = "Rojo"
    /// Gama oscura: casi negro en claro. En oscuro sube a un gris grafito,
    /// porque un acento negro sobre fondo negro desaparece (botones, barras,
    /// pestaña activa) — sigue siendo lo bastante oscuro para texto blanco.
    case charcoal = "Carbón"
    // Pastel de un solo color: los mismos tonos de los temas de dos colores,
    // para quien quiere el pastel sin el segundo acento.
    case lilac = "Lila"
    case mint = "Menta"
    case salmon = "Salmón"
    case lightBlue = "Celeste"
    case pink = "Rosado"
    case sand = "Arena"
    // Temas pastel de dos colores: un segundo acento con roles fijos
    // (ingresos, hoy en el scrubber, badge de Pendientes, suscripciones,
    // deltas a la baja) — ver `secondaryColor` y compañía más abajo.
    case lavender = "Lavanda"
    case peach = "Durazno"
    case sky = "Cielo"
    case rose = "Rosa"

    var id: String { self.rawValue }

    /// `true` para los temas pastel de dos colores, que tienen un
    /// `secondaryColor` propio en vez de heredar el mismo acento.
    var isDuotone: Bool {
        switch self {
        case .lavender, .peach, .sky, .rose: return true
        default: return false
        }
    }

    /// Temas pastel, de uno o dos colores: comparten tintes suaves propios en
    /// claro (el genérico queda muy débil sobre blanco).
    var isPastel: Bool {
        switch self {
        case .purple, .blue, .green, .orange, .red, .charcoal: return false
        default: return true
        }
    }

    /// El color del tema. Con un tema Pro puesto, su tema básico compañero
    /// toma el acento del Pro (el violeta de Nebulosa y no el morado del
    /// sistema): botones, interruptores y chips combinan con el cielo.
    var color: Color {
        if let pro = Self.activeProTheme, pro.companionAccent == self { return pro.accent }
        return baseColor
    }

    /// El tema Pro en uso (con Pro activo), leído de la misma caché.
    static var activeProTheme: ProTheme? {
        ThemeDefaults.values.pro
    }

    /// Los ajustes de los temas Pro, leídos de la misma caché.
    static func proHueShift(_ theme: ProTheme) -> Double { ThemeDefaults.values.proHues[theme] ?? 0 }
    static var proSkyIntensity: Double { ThemeDefaults.values.skyIntensity }

    private var baseColor: Color {
        switch self {
        case .purple: return .purple
        // El azul de marca del ícono (#2E5BFF) — no el azul de sistema — para
        // que "Azul" en Ajustes sea el mismo color que ve el usuario en el
        // ícono y el splash.
        case .blue: return AppBrand.accent
        case .green: return .green
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .red: return .red
        case .charcoal:
            return Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.388, green: 0.388, blue: 0.400, alpha: 1)   // #636366
                    : UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1)   // #2C2C2E
            })
        case .lavender: return Color(red: 0.659, green: 0.600, blue: 0.941)   // #A899F0
        case .peach:    return Color(red: 0.949, green: 0.631, blue: 0.533)   // #F2A188
        case .sky:      return Color(red: 0.549, green: 0.745, blue: 0.949)   // #8CBEF2
        case .rose:     return Color(red: 0.941, green: 0.651, blue: 0.745)   // #F0A6BE
        case .lilac:     return Color(red: 0.659, green: 0.600, blue: 0.941)  // #A899F0
        case .mint:      return Color(red: 0.498, green: 0.847, blue: 0.741)  // #7FD8BD
        case .salmon:    return Color(red: 0.949, green: 0.631, blue: 0.533)  // #F2A188
        case .lightBlue: return Color(red: 0.549, green: 0.745, blue: 0.949)  // #8CBEF2
        case .pink:      return Color(red: 0.941, green: 0.651, blue: 0.745)  // #F0A6BE
        case .sand:      return Color(red: 0.929, green: 0.780, blue: 0.608)  // #EDC79B
        }
    }
}

extension AppThemeColor {

    static let storageKey = "appAccentColor"

    /// El tema guardado. Mismo valor por defecto que los `@AppStorage`.
    static var current: AppThemeColor {
        ThemeDefaults.values.theme
    }

    var themeKindLabel: String { isDuotone ? "Dos colores" : "Un color" }

    // MARK: - Intensificar el color del tema (opcional)

    /// Ajustes › Apariencia: tiñe tarjetas y bordes con el tema. Apagado por
    /// defecto — superficies grises neutras y los bordes de acento de siempre.
    static let intenseTintKey = "intenseThemeTint"

    static var usesIntenseTint: Bool {
        ThemeDefaults.values.intenseTint
    }

    // MARK: - Colores de categoría del tema (opcional)

    /// Ajustes › Apariencia: si las categorías sin color elegido a mano toman
    /// su color de una rampa del tema en vez de su color fijo. Apagado por
    /// defecto — cada categoría conserva su color.
    static let themedCategoryColorsKey = "themedCategoryColors"

    static var usesThemedCategoryColors: Bool {
        ThemeDefaults.values.themedCategoryColors
    }

    /// Rampa de `1c`: acento 1, una variante vecina, acento 2, su vecina y un
    /// acento 1 lavado. En los temas de un color el segundo tono se deriva
    /// (−70° en la rueda, un punto más claro) para que la rampa no repita.
    func categoryRamp(_ scheme: ColorScheme) -> [Color] {
        let acc = color
        let acc2 = isDuotone ? secondaryColor
                             : acc.shiftedHSL(hue: -70, lightness: 0.06, scheme: scheme)
        return [
            acc,
            acc.shiftedHSL(hue: -35, lightness: 0.10, scheme: scheme),
            acc2,
            acc2.shiftedHSL(hue: -30, lightness: 0.10, scheme: scheme),
            acc.shiftedHSL(hue: 25, saturation: -0.15, lightness: 0.16, scheme: scheme),
            acc2.shiftedHSL(hue: 30, saturation: -0.10, lightness: -0.08, scheme: scheme),
            acc.shiftedHSL(hue: 60, lightness: -0.06, scheme: scheme),
            acc2.shiftedHSL(hue: -60, saturation: -0.10, lightness: 0.12, scheme: scheme)
        ]
    }
}

extension AppThemeColor {
    /// Fuerza el tema a "Azul" una sola vez, para que el color de marca se
    /// vea de inmediato sin depender de que el usuario lo elija a mano en
    /// Ajustes. No vuelve a tocar la preferencia después de esta vez.
    static func migrateToBrandBlueIfNeeded() {
        let key = "didMigrateToBrandBlueTheme"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(AppThemeColor.blue.rawValue, forKey: "appAccentColor")
        defaults.set(true, forKey: key)
    }
}

// MARK: - Temas recientes

extension AppThemeColor {

    /// Ajustes › Apariencia muestra en su fila los seis temas usados más
    /// recientemente; el resto vive en «Ver todos».
    static let recentKey = "recentAccentColors"
    static let recentCount = 6

    /// Semilla cuando todavía no hay historial: los seis del diseño.
    private static let recentSeed: [AppThemeColor] = [.blue, .purple, .green, .orange, .lavender, .peach]

    static func recent(defaults: UserDefaults = .standard) -> [AppThemeColor] {
        let stored = (defaults.string(forKey: recentKey) ?? "")
            .split(separator: ",")
            .compactMap { AppThemeColor(rawValue: String($0)) }
        var result: [AppThemeColor] = []
        for theme in stored + recentSeed where !result.contains(theme) {
            result.append(theme)
        }
        // El tema en uso siempre está a la vista.
        let inUse = AppThemeColor(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .blue
        if !result.prefix(recentCount).contains(inUse) { result.insert(inUse, at: 0) }
        return Array(result.prefix(recentCount))
    }

    /// Un tema que ya está en la fila no se mueve —la fila no salta bajo el
    /// dedo—; uno nuevo (de la galería) entra primero y empuja al más viejo.
    static func noteUsed(_ theme: AppThemeColor, defaults: UserDefaults = .standard) {
        var list = recent(defaults: defaults)
        if !list.contains(theme) {
            list.insert(theme, at: 0)
            list = Array(list.prefix(recentCount))
        }
        defaults.set(list.map(\.rawValue).joined(separator: ","), forKey: recentKey)
    }
}

// MARK: - Caché de los ajustes del tema

/// El tema y sus dos interruptores, leídos de `UserDefaults` una sola vez.
///
/// Cada `Palette(scheme)` los pedía, y una fila de Movimientos crea varias:
/// decenas de lecturas de `UserDefaults` por fila, justo mientras la lista se
/// desliza y monta filas nuevas. Se vuelven a leer en cuanto cambia cualquier
/// ajuste (`didChangeNotification` llega en el mismo proceso al escribir, sea
/// desde `@AppStorage`, Ajustes o un respaldo restaurado), así que un cambio
/// de tema se sigue viendo al instante.
private enum ThemeDefaults {
    struct Values {
        let theme: AppThemeColor
        let intenseTint: Bool
        let themedCategoryColors: Bool
        let pro: ProTheme?
        /// Grados de la variante elegida de cada tema Pro.
        let proHues: [ProTheme: Double]
        let skyIntensity: Double
    }

    private static let lock = NSLock()
    private static var cached: Values?
    private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { _ in
        lock.withLock { cached = nil }
    }

    static var values: Values {
        _ = observer
        return lock.withLock {
            if let cached { return cached }
            let defaults = UserDefaults.standard
            let values = Values(
                theme: AppThemeColor(rawValue: defaults.string(forKey: AppThemeColor.storageKey) ?? "") ?? .blue,
                intenseTint: defaults.bool(forKey: AppThemeColor.intenseTintKey),
                themedCategoryColors: defaults.bool(forKey: AppThemeColor.themedCategoryColorsKey),
                pro: defaults.bool(forKey: ProStore.enabledKey)
                    ? ProTheme(rawValue: defaults.string(forKey: ProTheme.storageKey) ?? "") : nil,
                proHues: Dictionary(uniqueKeysWithValues: ProTheme.allCases.map {
                    ($0, $0.tone(named: defaults.string(forKey: $0.toneKey)).degrees)
                }),
                skyIntensity: (defaults.object(forKey: ProTheme.skyIntensityKey) as? Double)
                    .map { min(max($0, ProTheme.skyIntensityRange.lowerBound), 1) } ?? 1)
            cached = values
            return values
        }
    }
}
