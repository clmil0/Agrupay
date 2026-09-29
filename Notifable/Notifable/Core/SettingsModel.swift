import SwiftUI

/// Tema de la app. Reemplaza a `@AppStorage("isDarkMode") Bool`.
///
/// El booleano no podía seguir al sistema: la app quedaba clavada en claro u
/// oscuro aunque iOS cambiara al atardecer.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system = "Automático"
    case light = "Claro"
    case dark = "Oscuro"

    var id: String { rawValue }

    static let storageKey = "appAppearance"

    /// `nil` deja que SwiftUI use el ajuste de iOS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Migración desde `isDarkMode`. Llamar una vez al arrancar.
    ///
    /// Se conserva la elección previa en lugar de mandar a todos a
    /// "Automático": cambiar el aspecto de la app sin avisar es hostil.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: storageKey) == nil else { return }
        if defaults.object(forKey: "isDarkMode") != nil {
            let wasDark = defaults.bool(forKey: "isDarkMode")
            defaults.set((wasDark ? AppAppearance.dark : .light).rawValue, forKey: storageKey)
        } else {
            defaults.set(AppAppearance.dark.rawValue, forKey: storageKey)
        }
    }
}

/// Resumen del estado de la app para la tarjeta superior de Configuración.
///
/// Existe porque el dato más importante — si la lectura automática funciona y
/// cuándo corrió por última vez — estaba a dos niveles de profundidad, dentro
/// de una pantalla llamada "Bancos y Sincronización Automática".
struct SettingsStatus {

    let isConnected: Bool
    /// Ver `GmailAuthService.missingGmailScope`.
    var missingGmailScope = false
    let account: String?
    let lastSync: Date?
    let activeBankCount: Int
    let totalBankCount: Int
    let expensesThisMonth: Int
    let unclassifiedMerchants: Int
    let pendingRecurring: Int

    enum Level { case ok, attention, disconnected }

    var level: Level {
        guard isConnected else { return .disconnected }
        if missingGmailScope { return .attention }
        if activeBankCount == 0 { return .attention }
        if let lastSync, lastSync < Date().addingTimeInterval(-60 * 60 * 48) { return .attention }
        return .ok
    }

    var headline: String {
        switch level {
        case .ok:           return "Lectura automática activa"
        case .attention:
            if missingGmailScope { return "Falta el permiso de Gmail" }
            return activeBankCount == 0 ? "Ningún banco activo" : "Sin leer hace más de 2 días"
        case .disconnected: return "Conecta tu correo"
        }
    }

    var subhead: String {
        switch level {
        case .disconnected:
            return "AgruPay lee los avisos de tu banco para registrar gastos solo."
        default:
            return account ?? "—"
        }
    }

    /// "hace 12 min" / "Hoy, 9:29" / "Nunca".
    var lastSyncLabel: String {
        guard let lastSync else { return "Nunca" }
        let elapsed = Date().timeIntervalSince(lastSync)
        if elapsed < 60 { return "ahora mismo" }
        if elapsed < 60 * 60 {
            return "hace \(Int(elapsed / 60)) min"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        if Period.calendar.isDateInToday(lastSync) {
            f.dateFormat = "'Hoy,' H:mm"
        } else if Period.calendar.isDateInYesterday(lastSync) {
            f.dateFormat = "'Ayer,' H:mm"
        } else {
            f.dateFormat = "d MMM, H:mm"
        }
        return f.string(from: lastSync)
    }

    var bankLabel: String { "\(activeBankCount) de \(totalBankCount)" }
}

/// Los bancos que la app sabe leer, con lo que detecta cada uno.
///
/// Antes esto vivía como cinco `Toggle` con `.tint()` distinto (azul, naranja,
/// morado, verde, rojo) y un `Button` con `info.circle` **dentro** del label
/// del toggle: tocar el texto alternaba el banco en vez de abrir la info.
/// Ahora la descripción es un subtítulo y todo usa el acento del usuario.
struct BankSource: Identifiable, Hashable {

    let id: String
    let name: String
    /// Qué avisos detecta el parser. Va como subtítulo, no en un alert.
    let detects: String
    /// Limitación conocida, si la hay.
    let caveat: String?
    let storageKey: String
    /// Nombre del asset en `Assets.xcassets` con el logo del banco.
    let logoAsset: String

    static let all: [BankSource] = [
        BankSource(id: "bbva", name: "BBVA",
                   detects: "Plin, pagos automáticos, tarjeta física y en línea",
                   caveat: nil,
                   storageKey: "syncBBVA",
                   logoAsset: "bbva_icon"),
        BankSource(id: "bcp", name: "BCP",
                   detects: "Pagos con tarjeta y transferencias",
                   caveat: nil,
                   storageKey: "syncBCP",
                   logoAsset: "bcp_icon"),
        BankSource(id: "yape", name: "Yape",
                   detects: "Yapeos recibidos y enviados",
                   caveat: "No detecta montos bajo S/ 10.",
                   storageKey: "syncYape",
                   logoAsset: "yape_icon"),
        BankSource(id: "interbank", name: "Interbank",
                   detects: "Pagos con tarjeta y transferencias",
                   caveat: nil,
                   storageKey: "syncInterbank",
                   logoAsset: "interbank_icon"),
        BankSource(id: "scotiabank", name: "Scotiabank",
                   detects: "Pagos con tarjeta y transferencias",
                   caveat: nil,
                   storageKey: "syncScotiabank",
                   logoAsset: "scotiabank_icon")
    ]

    var subtitle: String {
        guard let caveat else { return detects }
        return detects + ". " + caveat
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    static var activeCount: Int { all.filter { $0.isEnabled }.count }

    /// "BBVA, BCP +2" para la fila de resumen en la raíz.
    static var summaryLabel: String {
        let active = all.filter { $0.isEnabled }
        guard !active.isEmpty else { return "Ninguno" }
        let shown = active.prefix(2).map { $0.name }.joined(separator: ", ")
        let rest = active.count - min(2, active.count)
        return rest > 0 ? shown + " +\(rest)" : shown
    }
}

/// Índice de ajustes buscables. Con seis subpantallas y ~25 ajustes, la
/// búsqueda es la única forma realista de encontrar algo concreto.
struct SettingsEntry: Identifiable, Hashable {

    let id: String
    let title: String
    /// Términos por los que también debe encontrarse (sinónimos, dónde estaba
    /// antes). Ej. "presupuesto" debe aparecer buscando "meta" o "límite".
    let keywords: [String]
    let section: String
    let destination: String

    static let all: [SettingsEntry] = [
        SettingsEntry(id: "profile", title: "Perfil",
                      keywords: ["avatar", "pingüino", "apodo", "nombre", "estado", "amigos"],
                      section: "Cuenta", destination: "profile"),
        SettingsEntry(id: "email", title: "Correo",
                      keywords: ["gmail", "google", "cuenta", "desvincular", "permisos"],
                      section: "Cuenta", destination: "email"),
        SettingsEntry(id: "phone", title: "Celular",
                      keywords: ["número", "whatsapp", "verificar", "teléfono"],
                      section: "Cuenta", destination: "phone"),
        SettingsEntry(id: "devices", title: "Dispositivos",
                      keywords: ["ipad", "mac", "laptop", "sincronizar", "pro"],
                      section: "Cuenta", destination: "devices"),
        SettingsEntry(id: "budget", title: "Presupuesto y categorías",
                      keywords: ["meta", "límite", "mensual", "ritmo", "presupuesto"],
                      section: "Tu dinero", destination: "budget"),
        SettingsEntry(id: "income", title: "Registrar ingresos",
                      keywords: ["sueldo", "balance", "ingreso"],
                      section: "Tu dinero", destination: "budget"),
        SettingsEntry(id: "recurring", title: "Recurrentes y atajos",
                      keywords: ["suscripción", "alquiler", "repetir", "efectivo", "rápido"],
                      section: "Tu dinero", destination: "recurring"),
        SettingsEntry(id: "rules", title: "Categorías y reglas",
                      keywords: ["comercio", "clasificar", "bandeja", "fusionar"],
                      section: "Tu dinero", destination: "rules"),
        SettingsEntry(id: "gmail", title: "Gmail y bancos",
                      keywords: ["correo", "sincronizar", "bbva", "bcp", "yape", "interbank", "scotiabank", "cuánto atrás"],
                      section: "Captura automática", destination: "gmail"),
        SettingsEntry(id: "range", title: "Leer un rango de fechas",
                      keywords: ["histórico", "importar", "fechas", "rango pasado", "historial"],
                      section: "Captura automática", destination: "range"),
        SettingsEntry(id: "appearance", title: "Apariencia y resumen",
                      keywords: ["tema", "oscuro", "claro", "color", "acento", "texto", "tamaño", "categorías",
                                 "nebulosa", "obsidiana", "aurora", "atardecer", "premium"],
                      section: "Personalización", destination: "appearance"),
        SettingsEntry(id: "stats", title: "Estadísticas",
                      keywords: ["stats", "tiras", "dashboard", "resumen", "racha", "neto", "ritmo", "carrusel"],
                      section: "Personalización", destination: "stats"),
        SettingsEntry(id: "assistant", title: "Asistente",
                      keywords: ["memoria", "ia", "inteligencia", "sugerencias", "gastos raros", "resumen del día"],
                      section: "Personalización", destination: "assistant"),
        SettingsEntry(id: "notifications", title: "Notificaciones",
                      keywords: ["aviso", "recordatorio", "deuda", "cobro", "presupuesto", "intensa"],
                      section: "Personalización", destination: "notifications"),
        SettingsEntry(id: "lock", title: "Bloqueo",
                      keywords: ["face id", "faceid", "touch id", "huella", "cara", "ojito", "widgets",
                                 "privacidad", "seguridad", "contraseña", "código"],
                      section: "Privacidad y datos", destination: "lock"),
        SettingsEntry(id: "data", title: "Datos y respaldo",
                      keywords: ["csv", "exportar", "backup", "nube", "borrar", "caché", "restaurar", "archivo"],
                      section: "Privacidad y datos", destination: "data"),
        SettingsEntry(id: "diagnostics", title: "Diagnóstico",
                      keywords: ["registros", "logs", "soporte", "error", "fallo"],
                      section: "Datos y respaldo", destination: "diagnostics")
    ]

    /// Lo que se puede buscar, más las pruebas de desarrollo en DEBUG.
    static var searchable: [SettingsEntry] {
        #if DEBUG
        return all + [SettingsEntry(id: "financekit", title: "FinanceKit (POC)",
                                    keywords: ["financekit", "wallet", "apple card", "debug"],
                                    section: "Desarrollo", destination: "financekit")]
        #else
        return all
        #endif
    }

    static func matching(_ query: String) -> [SettingsEntry] {
        let q = query.folding(options: [.diacriticInsensitive, .caseInsensitive],
                              locale: Locale(identifier: "es_PE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return searchable.filter { entry in
            let haystack = ([entry.title, entry.section] + entry.keywords)
                .joined(separator: " ")
                .folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "es_PE"))
            return haystack.contains(q)
        }
    }
}

/// Aplica el tema elegido. Mismo patrón que `.appTextSize()`: se pone en la raíz
/// y en cada sheet, porque un sheet crea su propia jerarquía de presentación.
///
/// `preferredColorScheme(nil)` en "Automático" deja que SwiftUI herede el
/// aspecto de iOS, así que el cambio al atardecer llega sin reiniciar la app.
struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var raw = AppAppearance.dark.rawValue
    @AppStorage(ProTheme.storageKey) private var proThemeRaw = ""
    @AppStorage(ProStore.enabledKey) private var isPro = false

    func body(content: Content) -> some View {
        // Los temas Pro son de noche: con uno puesto, la app va en oscuro.
        let forcesDark = isPro && ProTheme(rawValue: proThemeRaw) != nil
        content.preferredColorScheme(forcesDark ? .dark : AppAppearance(rawValue: raw)?.colorScheme)
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}
