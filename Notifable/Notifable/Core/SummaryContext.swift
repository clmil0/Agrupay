import Foundation
import Observation

/// El mes que muestra el Resumen (`01` de «Soluciones del Resumen»).
///
/// El Resumen fija el contexto —mes, cuenta y ojito— y lo que se abre desde
/// él lo hereda. La cuenta ya es una sola para toda la app (`AccountFilter`)
/// y el ojito vive en `UserDefaults` (`AmountPrivacy`); el mes vivía en el
/// `@State` de `DashboardScreen` y Categorías no lo veía. Categorías abre con
/// este mes y luego tiene sus propias flechas: cambiarlo allá no mueve el
/// Resumen.
@Observable
final class SummaryContext {

    static let shared = SummaryContext()

    /// Meses hacia atrás desde el actual.
    var monthOffset = 0
}

/// El periodo al que llevan las hojas del Resumen (`03` y `05`): «Ver en
/// Movimientos» abre la lista con sólo los movimientos de ese día, semana o
/// mes.
///
/// Es de una visita: Movimientos lo quita al salir de la pestaña, para que
/// volver más tarde no encuentre la lista recortada sin saber por qué.
@Observable
final class MovementsPeriodFilter {

    static let shared = MovementsPeriodFilter()

    struct Selection: Equatable {
        /// Desde el inicio del primer día hasta el inicio del día siguiente
        /// al último.
        let interval: DateInterval
        /// «sábado 12 de setiembre», «12–18 set», «agosto 2026».
        let label: String
    }

    var selection: Selection?

    func contains(_ date: Date) -> Bool {
        guard let interval = selection?.interval else { return true }
        return date >= interval.start && date < interval.end
    }
}
