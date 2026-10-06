import Foundation
import SwiftData

/// Una ocurrencia programada esperando resolución.
struct PendingOccurrence: Identifiable, Equatable {

    let ruleID: UUID
    let merchant: String
    let category: String
    let currency: String
    /// Fechas programadas agrupadas de la misma regla (ej. dos almuerzos).
    let dates: [Date]
    /// Monto esperado por ocurrencia.
    let expectedAmount: Double

    enum Status: Equatable {
        /// Esperando confirmación del usuario.
        case awaiting
        /// El banco ya envió el cobro real: la regla se marca cumplida y **no**
        /// se inserta nada. El monto que cuenta es el del banco.
        case satisfiedByBank(expenseID: UUID, bankAmount: Double, daysApart: Int)
    }

    let status: Status

    var id: String { ruleID.uuidString + "-" + String(dates.first?.timeIntervalSince1970 ?? 0) }

    var totalAmount: Double { Money.multiply(expectedAmount, by: Double(dates.count)) }

    var isAwaiting: Bool { status == .awaiting }
}

/// Resuelve qué gastos recurrentes toca proponer, y evita duplicar lo que ya
/// llegó por correo del banco.
///
/// **La deduplicación es el punto crítico.** Sin ella, una regla de Netflix el
/// día 10 y el correo del banco del día 10 producen dos gastos de S/ 44.90 y el
/// mes queda inflado. La regla busca un `Expense` real con comercio compatible
/// y monto cercano dentro de una ventana de ±`toleranceDays` alrededor de la
/// fecha programada; si lo encuentra, se marca cumplida sin insertar nada.
enum RecurringEngine {

    /// Ventana de búsqueda para la deduplicación.
    static let toleranceDays = 3
    /// Diferencia de monto aceptada para considerar que es el mismo cobro (15%).
    static let amountTolerance = 0.15

    /// Tramo del historial que `pending(rules:expenses:)` llega a mirar.
    ///
    /// Existe para que Resumen pueda acotar su `@Query` sin romper la
    /// deduplicación: si la ventana se quedara corta, un cobro real del banco
    /// no encontraría su ocurrencia y la regla se anunciaría como pendiente
    /// estando ya cobrada. Se calcula con el **mismo** criterio que `pending`
    /// (desde la última ocurrencia resuelta, o desde el inicio de la regla) más
    /// el margen de `bankMatch` a cada lado.
    ///
    /// `nil` si no hay ninguna regla activa: entonces no hace falta historial.
    static func matchWindow(rules: [RecurringExpense],
                            horizon: Int = 0,
                            now: Date = Date()) -> DateInterval? {

        let cal = Period.calendar
        let today = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day,
                                 value: horizon + 1 + toleranceDays,
                                 to: today) else { return nil }

        var earliest: Date?
        for rule in rules where !rule.isPaused && rule.frequency != .never {
            let from = rule.lastResolvedOccurrence
                .flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }
                ?? cal.startOfDay(for: rule.startDate)
            guard from < end else { continue }
            if earliest == nil || from < earliest! { earliest = from }
        }

        guard let earliest else { return nil }
        let start = cal.date(byAdding: .day, value: -toleranceDays, to: earliest) ?? earliest
        return DateInterval(start: start, end: end)
    }

    /// Ocurrencias vencidas y no resueltas, hasta hoy inclusive.
    ///
    /// - Parameter horizon: días hacia adelante a incluir. 0 = sólo lo vencido.
    ///   Con 3 el usuario puede confirmar por adelantado.
    static func pending(rules: [RecurringExpense],
                        expenses: [Expense],
                        horizon: Int = 0,
                        now: Date = Date()) -> [PendingOccurrence] {

        let cal = Period.calendar
        let today = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: horizon + 1, to: today) else { return [] }

        var result: [PendingOccurrence] = []

        for rule in rules where !rule.isPaused && rule.frequency != .never {
            let from = rule.lastResolvedOccurrence
                .flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }
                ?? cal.startOfDay(for: rule.startDate)
            guard from < end else { continue }

            let dates = rule.occurrences(in: DateInterval(start: from, end: end))
            guard !dates.isEmpty else { continue }

            // Cada fecha se evalúa contra el historial real.
            var awaiting: [Date] = []
            for date in dates {
                if let match = bankMatch(for: rule, on: date, in: expenses) {
                    result.append(PendingOccurrence(
                        ruleID: rule.id,
                        merchant: rule.merchant,
                        category: rule.category,
                        currency: rule.currency,
                        dates: [date],
                        expectedAmount: rule.amount,
                        status: .satisfiedByBank(
                            expenseID: match.expense.id,
                            bankAmount: match.expense.amount,
                            daysApart: match.daysApart
                        )
                    ))
                } else {
                    awaiting.append(date)
                }
            }

            if !awaiting.isEmpty {
                result.append(PendingOccurrence(
                    ruleID: rule.id,
                    merchant: rule.merchant,
                    category: rule.category,
                    currency: rule.currency,
                    dates: awaiting,
                    expectedAmount: rule.amount,
                    status: .awaiting
                ))
            }
        }

        return result.sorted { ($0.dates.first ?? .distantFuture) < ($1.dates.first ?? .distantFuture) }
    }

    /// Busca en el historial un gasto real que corresponda a esta ocurrencia.
    private static func bankMatch(for rule: RecurringExpense,
                                  on date: Date,
                                  in expenses: [Expense]) -> (expense: Expense, daysApart: Int)? {
        let cal = Period.calendar
        let day = cal.startOfDay(for: date)
        guard let lower = cal.date(byAdding: .day, value: -toleranceDays, to: day),
              let upper = cal.date(byAdding: .day, value: toleranceDays + 1, to: day) else { return nil }

        let expected = Money.cents(rule.amount)
        let margin = Int(Double(expected) * amountTolerance)

        let candidates = expenses.filter { expense in
            guard expense.date >= lower, expense.date < upper else { return false }
            guard expense.currency == rule.currency else { return false }
            guard matches(merchant: expense.merchant, rule: rule.merchant) else { return false }
            // Un monto de cero en la regla (variable) acepta cualquier importe.
            guard expected > 0 else { return true }
            return abs(Money.cents(expense.amount) - expected) <= margin
        }

        guard let best = candidates.min(by: {
            abs($0.date.timeIntervalSince(day)) < abs($1.date.timeIntervalSince(day))
        }) else { return nil }

        let daysApart = abs(cal.dateComponents([.day], from: day, to: cal.startOfDay(for: best.date)).day ?? 0)
        return (best, daysApart)
    }

    /// Compara nombres de comercio con la misma tolerancia que las reglas de
    /// categoría: los parsers de banco añaden número de local.
    private static func matches(merchant: String, rule: String) -> Bool {
        let a = normalize(Accounting.displayName(merchant))
        let b = normalize(Accounting.displayName(rule))
        guard b.count >= 3 else { return a == b }
        return a.hasPrefix(b) || b.hasPrefix(a) || a.contains(b)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "es_PE"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Acciones

    /// Confirma una ocurrencia: inserta un `Expense` por cada fecha y avanza
    /// el marcador de la regla.
    @discardableResult
    static func confirm(_ occurrence: PendingOccurrence,
                        rule: RecurringExpense,
                        amountOverride: Double? = nil,
                        in context: ModelContext) -> [Expense] {
        let amount = amountOverride.map { Money.normalized($0) } ?? rule.amount
        guard Money.cents(amount) > 0 else { return [] }

        var created: [Expense] = []
        for date in occurrence.dates {
            let expense = Expense(
                amount: amount,
                merchant: rule.merchant,
                date: date,
                category: rule.category,
                isSubscription: rule.frequency != .never,
                currency: rule.currency
            )
            context.insert(expense)
            created.append(expense)
            if expense.category != Accounting.unclassified {
                ClassificationLedger.record(expense.id, engine: .recurring)
            }
            Analytics.track(.movementCreated, ["source": "recurring", "kind": "expense",
                                               "category_source": expense.category == Accounting.unclassified ? "none" : "recurring",
                                               "category": Analytics.categoryLabel(expense.category),
                                               "auto_confirm": rule.autoConfirm])
        }
        advance(rule, to: occurrence.dates.max())
        return created
    }

    /// Omite esta ocurrencia sin registrar nada (el gimnasio que no se pagó).
    static func skip(_ occurrence: PendingOccurrence, rule: RecurringExpense) {
        advance(rule, to: occurrence.dates.max())
    }

    /// Marca cumplida la ocurrencia que el banco ya cubrió.
    static func acknowledgeBankMatch(_ occurrence: PendingOccurrence, rule: RecurringExpense) {
        advance(rule, to: occurrence.dates.max())
    }

    private static func advance(_ rule: RecurringExpense, to date: Date?) {
        guard let date else { return }
        if let current = rule.lastResolvedOccurrence, current >= date { return }
        rule.lastResolvedOccurrence = date
    }

    /// Aplica automáticamente las reglas con `autoConfirm`. Llamar en
    /// `onAppear` de la raíz, una vez por sesión.
    static func applyAutomatic(rules: [RecurringExpense],
                               expenses: [Expense],
                               in context: ModelContext,
                               now: Date = Date()) {
        let auto = rules.filter { $0.autoConfirm && !$0.isPaused }
        guard !auto.isEmpty else { return }
        for occurrence in pending(rules: auto, expenses: expenses, now: now) {
            guard let rule = auto.first(where: { $0.id == occurrence.ruleID }) else { continue }
            switch occurrence.status {
            case .awaiting:
                confirm(occurrence, rule: rule, in: context)
            case .satisfiedByBank:
                acknowledgeBankMatch(occurrence, rule: rule)
            }
        }
    }

    /// Total mensual comprometido por todas las reglas activas, en soles.
    static func monthlyCommitted(rules: [RecurringExpense], usdToPen: Double) -> Double {
        var bag = MoneyBag()
        for rule in rules where !rule.isPaused {
            bag.add(rule.monthlyEquivalent, currency: rule.currency)
        }
        return bag.totalInPEN(usdToPen: usdToPen)
    }
}
