import Foundation

/// Arma el `WidgetSnapshot` a partir de valores puros, sin SwiftData.
///
/// Mismo principio que `Accounting`: todo lo que depende de la base o de
/// `UserDefaults` lo resuelve `WidgetSnapshotWriter` y llega aquí ya como
/// valores, así el resumen se prueba igual que los totales. Las cifras salen
/// de `Accounting.totals` y `CategoryLimits.status`, las mismas que ve el
/// usuario en Resumen y Categorías.
enum WidgetSnapshotBuilder {

    struct Style: Equatable {
        var symbol: String
        var colorHex: String
    }

    struct Inputs {
        /// Todo el historial: los límites anuales y el sobrante del ciclo
        /// anterior necesitan más de dos meses.
        var expenses: [ExpenseSnapshot]
        var incomes: [IncomeSnapshot]
        var usdToPen: Double

        var monthlyBudget: Double
        var budgetEnabled: Bool
        var tracksIncome: Bool
        var hideAmounts: Bool

        /// Sólo los que tienen monto.
        var categoryBudgets: [CategoryBudget]
        var quickActions: [WidgetSnapshot.QuickAction]
        var pendingRecurringCount: Int
        var nextRecurring: WidgetSnapshot.UpcomingItem?
        var categoryNames: [String]
        var theme: WidgetSnapshot.Theme
        var style: (String) -> Style
        var penguin: PenguinLook? = nil
    }

    static let maxCategories = 4
    static let maxLimits = 6
    static let maxQuickActions = 4

    static func build(_ inputs: Inputs, now: Date) -> WidgetSnapshot {
        let period = Period(granularity: .mes, reference: now)
        let totals = Accounting.totals(expenses: inputs.expenses,
                                       incomes: inputs.incomes,
                                       period: period,
                                       usdToPen: inputs.usdToPen)
        let previous = Accounting.totals(expenses: inputs.expenses,
                                         incomes: inputs.incomes,
                                         period: period.previous,
                                         usdToPen: inputs.usdToPen)
        let interval = period.interval

        let top = totals.byCategory.prefix(maxCategories).map { category -> WidgetSnapshot.CategorySlice in
            let style = inputs.style(category.category)
            return WidgetSnapshot.CategorySlice(name: category.category,
                                                totalCents: Money.cents(category.total),
                                                symbol: style.symbol,
                                                colorHex: style.colorHex)
        }
        let topCents = top.reduce(0) { $0 + $1.totalCents }

        let budget = BudgetStore.target(monthlyBudget: inputs.monthlyBudget,
                                        enabled: inputs.budgetEnabled,
                                        for: period)
            .map { WidgetSnapshot.BudgetSummary(targetCents: Money.cents($0)) }

        return WidgetSnapshot(
            generatedAt: now,
            hideAmounts: inputs.hideAmounts,
            theme: inputs.theme,
            month: WidgetSnapshot.MonthSummary(
                start: interval.start,
                end: interval.end,
                spentCents: Money.cents(totals.spent),
                incomeCents: inputs.tracksIncome ? Money.cents(totals.income) : nil,
                dailySpentCents: totals.dailySpent.map { Money.cents($0.total) },
                previousDailySpentCents: previous.dailySpent.map { Money.cents($0.total) },
                expenseCount: totals.expenseCount,
                hasMixedCurrencies: totals.hasMixedCurrencies
            ),
            budget: budget,
            topCategories: top,
            otherCents: max(0, Money.cents(totals.spent) - topCents),
            limits: limits(inputs, now: now),
            attention: WidgetSnapshot.AttentionSummary(
                unclassifiedCount: totals.unclassifiedMerchantCount,
                debtOutstandingCents: debtOutstandingCents(inputs.expenses, usdToPen: inputs.usdToPen),
                debtCount: inputs.expenses.filter { $0.isDebt && Money.cents(Accounting.outstanding(of: $0)) > 0 }.count,
                pendingRecurringCount: inputs.pendingRecurringCount,
                nextRecurring: inputs.nextRecurring
            ),
            quickActions: Array(inputs.quickActions.prefix(maxQuickActions)),
            categoryNames: inputs.categoryNames,
            penguin: inputs.penguin
        )
    }

    /// Pasados primero y luego por fracción, como la lista de límites (`6d`).
    static func limits(_ inputs: Inputs, now: Date) -> [WidgetSnapshot.LimitSummary] {
        let summaries = inputs.categoryBudgets
            .filter(\.hasLimit)
            .map { budget -> WidgetSnapshot.LimitSummary in
                let status = CategoryLimits.status(category: budget.category,
                                                   budget: budget,
                                                   expenses: inputs.expenses,
                                                   on: now,
                                                   usdToPen: inputs.usdToPen)
                let style = inputs.style(budget.category)
                return WidgetSnapshot.LimitSummary(category: budget.category,
                                                   symbol: style.symbol,
                                                   colorHex: style.colorHex,
                                                   limitCents: Money.cents(status.limit),
                                                   spentCents: Money.cents(status.spent),
                                                   cycleStart: status.cycleStart,
                                                   cycleEnd: budget.interval(containing: now).end,
                                                   alertThreshold: status.alertThreshold)
            }
        return Array(summaries.sorted { lhs, rhs in
            if lhs.isOver != rhs.isOver { return lhs.isOver }
            return lhs.fraction == rhs.fraction ? lhs.category < rhs.category : lhs.fraction > rhs.fraction
        }.prefix(maxLimits))
    }

    /// Lo que aún te deben, de cualquier mes, en soles.
    static func debtOutstandingCents(_ expenses: [ExpenseSnapshot], usdToPen: Double) -> Int {
        expenses.filter(\.isDebt).reduce(0) { sum, expense in
            sum + Accounting.penCents(amount: Accounting.outstanding(of: expense),
                                      currency: expense.currency,
                                      fxRateAtCapture: expense.fxRateAtCapture,
                                      fallbackRate: usdToPen)
        }
    }

    // MARK: - Privacidad

    static let showAmountsKey = "widgetShowAmounts"

    /// «Montos en los widgets» (Configuración › Bloqueo). Si nunca se tocó,
    /// sigue la regla de antes: con el bloqueo encendido se ocultan, sin él se
    /// muestran — quien no protege la app tampoco espera que el widget la
    /// proteja.
    static func showsAmounts(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showAmountsKey) as? Bool ?? !defaults.bool(forKey: AppLock.enabledKey)
    }

    @MainActor
    static func hideAmounts(defaults: UserDefaults = .standard) -> Bool {
        !showsAmounts(defaults: defaults)
    }
}
