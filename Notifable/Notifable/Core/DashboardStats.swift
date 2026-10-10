import Foundation

/// Las tiras de stats del dashboard: cuáles salen y en qué orden.
///
/// Ajustes › Estadísticas las elige. Cuántas quedan decide cómo se dibujan
/// (`DashboardView.statsBlock`): una sola va en grande con su gráfico, dos se
/// reparten la fila, tres la llenan y con más la fila se vuelve carrusel.
///
/// Elegir una no garantiza verla: Neto necesita ingresos, Ritmo un
/// presupuesto y Límites superados alguna categoría con límite. Una tira que
/// siempre dice «nada» es ruido.
enum DashboardStat: String, CaseIterable, Identifiable {
    case net, pace, perDay, biggest, topDay, noSpendStreak, limitsOver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .net:           return "Neto"
        case .pace:          return "Ritmo"
        case .perDay:        return "Por día"
        case .biggest:       return "Mayor gasto"
        case .topDay:        return "Día de más gasto"
        case .noSpendStreak: return "Racha sin gastar"
        case .limitsOver:    return "Límites superados"
        }
    }

    /// Lo que dice Ajustes debajo del nombre.
    var summary: String {
        switch self {
        case .net:           return "Ingresos menos gastos. Sólo si registras ingresos."
        case .pace:          return "Cuánto del presupuesto llevas. Sólo con presupuesto."
        case .perDay:        return "Tu gasto promedio diario del mes."
        case .biggest:       return "El gasto más grande del mes."
        case .topDay:        return "El día del mes en que más gastaste."
        case .noSpendStreak: return "Días del mes sin gastar, hasta hoy."
        case .limitsOver:    return "Categorías que pasaron su límite. Sólo con límites."
        }
    }

    var icon: String {
        switch self {
        case .net:           return "plusminus"
        case .pace:          return "gauge.with.dots.needle.33percent"
        case .perDay:        return "calendar"
        case .biggest:       return "arrow.up.right"
        case .topDay:        return "star.fill"
        case .noSpendStreak: return "flame.fill"
        case .limitsOver:    return "exclamationmark.triangle.fill"
        }
    }
}

/// La selección guardada: los elegidos, en su orden, como texto separado por
/// comas en `UserDefaults` (viaja con las demás preferencias, ver
/// `AppPreferences`).
enum DashboardStatsSettings {

    static let key = "dashboardStats"

    /// Sin nada guardado salen tres —Neto, Ritmo y Por día—, las que llenan
    /// la fila. Las demás se encienden en Ajustes y asoman por el borde.
    static let defaultValue = encode([.net, .pace, .perDay])

    static func decode(_ raw: String) -> [DashboardStat] {
        var seen = Set<DashboardStat>()
        return raw.split(separator: ",").compactMap { DashboardStat(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    static func encode(_ stats: [DashboardStat]) -> String {
        stats.map(\.rawValue).joined(separator: ",")
    }
}
