import Foundation

/// Todas las preferencias del usuario que viven en `UserDefaults`, en una sola
/// lista.
///
/// Antes cada ajuste nuevo exigía tres cambios coordinados —una columna en
/// Supabase, un campo en el payload y una línea en `applySettings`— y bastaba
/// olvidar uno para que ese ajuste se perdiera en silencio al cambiar de
/// teléfono. Aquí se declara **una vez**, en `syncable`, y viaja en un único
/// `jsonb`.
///
/// Lo que NO entra: tokens y credenciales (que son de este dispositivo), la
/// caché de correos leídos (se rehace sola), los filtros de pantalla (son de
/// este momento, no una preferencia) y el estado del onboarding (quien estrena
/// un teléfono merece verlo).
enum AppPreferences {

    /// Una preferencia sincronizable. El tipo importa porque `UserDefaults`
    /// distingue `Bool` de `Int` y restaurar un booleano como número lo
    /// silenciaría.
    enum Kind {
        case bool, int, double, string
    }

    struct Entry {
        let key: String
        let kind: Kind
        /// Para qué sirve — sale en el documento de qué se respalda.
        let note: String
    }

    static let syncable: [Entry] = [
        // Apariencia
        .init(key: "appAppearance", kind: .string, note: "Tema: claro, oscuro o automático"),
        .init(key: "appAccentColor", kind: .string, note: "Color de acento"),
        .init(key: "appTextSize", kind: .string, note: "Tamaño de letra"),
        .init(key: AppFontDesign.storageKey, kind: .string, note: "Tipo de letra"),
        .init(key: "circularReveal", kind: .bool, note: "Animación al cambiar de tema"),
        .init(key: AppThemeColor.intenseTintKey, kind: .bool, note: "Tinte intenso del color de acento"),
        .init(key: AppThemeColor.themedCategoryColorsKey, kind: .bool, note: "Categorías con el color del tema"),
        .init(key: WidgetSnapshotBuilder.showAmountsKey, kind: .bool, note: "Montos visibles en los widgets"),
        // El tema Pro elegido. Sin Pro no se aplica, pero se recuerda para
        // cuando vuelva (el plan en sí no viaja: es del dispositivo/cuenta).
        .init(key: ProTheme.storageKey, kind: .string, note: "Tema Pro del Resumen"),
        .init(key: ProTheme.nebula.toneKey, kind: .string, note: "Variante de Nebulosa"),
        .init(key: ProTheme.obsidian.toneKey, kind: .string, note: "Variante de Obsidiana"),
        .init(key: ProTheme.aurora.toneKey, kind: .string, note: "Variante de Aurora"),
        .init(key: ProTheme.sunset.toneKey, kind: .string, note: "Variante de Atardecer"),
        .init(key: ProTheme.abyss.toneKey, kind: .string, note: "Variante de Abismo"),
        .init(key: ProTheme.pearl.toneKey, kind: .string, note: "Variante de Perla"),
        .init(key: ProTheme.dawn.toneKey, kind: .string, note: "Variante de Alba"),
        .init(key: ProTheme.glacier.toneKey, kind: .string, note: "Variante de Glaciar"),
        .init(key: ProTheme.ivory.toneKey, kind: .string, note: "Variante de Marfil"),
        .init(key: ProTheme.sage.toneKey, kind: .string, note: "Variante de Salvia"),
        .init(key: ProTheme.skyIntensityKey, kind: .double, note: "Intensidad del cielo de los temas Pro"),

        // Privacidad
        .init(key: AmountPrivacy.hideOnLaunchKey, kind: .bool, note: "Empezar con los montos ocultos"),
        .init(key: PrivacyShield.coverKey, kind: .bool, note: "Tapar la app al cambiar de app"),

        // Asistente
        .init(key: AssistantSettings.briefDotKey, kind: .bool, note: "Punto en ✦ cuando hay resumen nuevo"),
        .init(key: AssistantSettings.suggestionsKey, kind: .bool, note: "Sugerencias de categoría"),
        .init(key: AssistantSettings.unusualKey, kind: .bool, note: "Avisos de gastos raros"),

        // Presupuesto
        .init(key: "monthlyBudget", kind: .double, note: "Presupuesto mensual"),
        .init(key: "budgetEnabled", kind: .bool, note: "Presupuesto activo"),
        .init(key: "trackIncome", kind: .bool, note: "Contar ingresos en el balance"),

        // Bancos que se leen
        .init(key: "syncBCP", kind: .bool, note: "Leer avisos del BCP"),
        .init(key: "syncBBVA", kind: .bool, note: "Leer avisos del BBVA"),
        .init(key: "syncYape", kind: .bool, note: "Leer avisos de Yape"),
        .init(key: "syncInterbank", kind: .bool, note: "Leer avisos de Interbank"),
        .init(key: "syncScotiabank", kind: .bool, note: "Leer avisos de Scotiabank"),

        // Notificaciones
        .init(key: "notificationsEnabled", kind: .bool, note: "Aviso de presupuesto"),
        .init(key: "remindRecurring", kind: .bool, note: "Aviso de recurrentes por confirmar"),
        .init(key: "categoryLimitAlerts", kind: .bool, note: "Aviso al pasar el límite de una categoría"),
        .init(key: "notifyImportedMovements", kind: .bool, note: "Aviso por cada pago registrado del correo"),
        .init(key: "debtReminderEnabled", kind: .bool, note: "Aviso de cobros pendientes"),
        .init(key: "debtReminderHour", kind: .int, note: "Hora del aviso de cobros"),
        .init(key: "debtReminderMinute", kind: .int, note: "Minuto del aviso de cobros"),
        .init(key: "debtNotificationFrequency", kind: .string, note: "Cada cuánto avisa de los cobros"),
        .init(key: NotificationSettings.debtWeekdayKey, kind: .int, note: "Día de la semana del aviso de cobros"),
        .init(key: NotificationSettings.debtMonthDayKey, kind: .int, note: "Día del mes del aviso de cobros"),
        .init(key: NotificationSettings.reminderIntensityKey, kind: .string, note: "Intensidad al cobrarle a un amigo"),

        // Lectura del correo
        .init(key: "readPeriodMonths", kind: .int, note: "Desde cuándo leer el correo"),
        .init(key: GmailLookback.allHistoryKey, kind: .bool, note: "Leer todo el historial (Pro)"),

        // Preferencias de vista que sí son una elección duradera
        .init(key: DictationStyle.storageKey, kind: .string, note: "Animación del dictado por voz"),
        .init(key: "categoriesSegment", kind: .string, note: "Pestaña por defecto en Categorías"),
        .init(key: DashboardStatsSettings.key, kind: .string, note: "Stats del dashboard y su orden"),
        // Las etiquetas del usuario, en un solo JSON. Las que lleva cada gasto
        // viajan con el gasto (`ManualTransactionBackup`) o con su edición
        // (`ExpenseEdit`); esto es sólo la lista y su color.
        .init(key: TagCatalog.key, kind: .string, note: "Etiquetas creadas y su color"),
        // Movimientos › Tus cuentas: cuáles son tuyas (lo que va a ellas es
        // traslado), cómo se llaman y su orden en el carrusel.
        .init(key: AccountBook.key, kind: .string, note: "Tus cuentas: cuáles son tuyas, nombres y orden"),

        // Amigos. La sesión y los ids viven en el servidor; lo de aquí es lo
        // que sólo existe en este teléfono: cómo me presento y cómo llamo yo a
        // cada amigo. Las notas por amigo van en un solo JSON —apodo, color,
        // emoji y lo que le comparto— para no abrir una clave por campo.
        .init(key: SocialProfileStore.Keys.displayName, kind: .string, note: "Tu nombre en Amigos"),
        .init(key: SocialProfileStore.Keys.status, kind: .string, note: "Tu estado en Amigos"),
        .init(key: SocialProfileStore.Keys.avatarEmoji, kind: .string, note: "Emoji de tu avatar en Amigos"),
        .init(key: SocialProfileStore.Keys.bannerIndex, kind: .int, note: "Cabecera de tu perfil en Amigos"),
        .init(key: SocialProfileStore.Keys.penguin, kind: .string, note: "Tu personaje en Amigos"),
        .init(key: SocialProfileStore.Keys.style, kind: .string, note: "Cielo, aura, marco y entrada de tu perfil Pro"),
        .init(key: SocialProfileStore.Keys.friendPreferences, kind: .string,
              note: "Apodo, color y qué compartes con cada amigo")
    ]

    // MARK: - Fotografía

    /// Sólo las claves que el usuario ha tocado de verdad: mandar los valores
    /// por defecto de todo obligaría a que el otro teléfono los adopte, y un
    /// ajuste que nunca se cambió no es una preferencia.
    static func snapshot(_ defaults: UserDefaults = .standard) -> [String: AnyCodableValue] {
        var result: [String: AnyCodableValue] = [:]
        for entry in syncable {
            guard let raw = defaults.object(forKey: entry.key) else { continue }
            switch entry.kind {
            case .bool:   if let v = raw as? Bool { result[entry.key] = .bool(v) }
            case .int:    if let v = raw as? Int { result[entry.key] = .int(v) }
            case .double: if let v = raw as? Double { result[entry.key] = .double(v) }
            case .string: if let v = raw as? String { result[entry.key] = .string(v) }
            }
        }
        return result
    }

    /// Escribe de vuelta sólo lo conocido: una clave que no esté en la lista
    /// —de una versión más nueva, por ejemplo— se ignora en vez de acabar en
    /// `UserDefaults` con un tipo que nadie sabe leer.
    static func apply(_ values: [String: AnyCodableValue], _ defaults: UserDefaults = .standard) {
        let byKey = Dictionary(uniqueKeysWithValues: syncable.map { ($0.key, $0) })
        for (key, value) in values {
            guard let entry = byKey[key] else { continue }
            switch (entry.kind, value) {
            case (.bool, .bool(let v)):     defaults.set(v, forKey: key)
            case (.int, .int(let v)):       defaults.set(v, forKey: key)
            case (.double, .double(let v)): defaults.set(v, forKey: key)
            case (.double, .int(let v)):    defaults.set(Double(v), forKey: key)
            case (.string, .string(let v)): defaults.set(v, forKey: key)
            default: continue
            }
        }
    }
}

/// Un valor de preferencia: sólo los cuatro tipos que `UserDefaults` guarda
/// bien y que Postgres entiende como `jsonb` sin inventarse nada.
enum AnyCodableValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // El orden importa: en JSON `true` también decodifica como número en
        // algunas implementaciones, así que el booleano va primero.
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "Preferencia de tipo desconocido")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let v):   try container.encode(v)
        case .int(let v):    try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        }
    }

    /// Para armar el cuerpo del RPC sin volver a serializar.
    var jsonValue: Any {
        switch self {
        case .bool(let v):   return v
        case .int(let v):    return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
}
