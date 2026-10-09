import Foundation

// MARK: - Snapshots

/// Un gasto reducido a lo que la contabilidad necesita, sin SwiftData.
///
/// Existe para que `Accounting` sea una función pura sobre valores: se puede
/// probar sin `ModelContainer` y se comporta igual en la app y en los tests.
struct ExpenseSnapshot {
    var amount: Double
    var currency: String
    var date: Date
    var category: String
    var merchant: String
    /// Etiquetas del gasto. Viajan en el snapshot para que los cortes por
    /// etiqueta se puedan calcular y probar sin `ModelContainer`, igual que
    /// los de categoría.
    var tags: [String]
    var isDebt: Bool
    /// Soles por 1 USD el día del movimiento. `nil` en registros antiguos.
    var fxRateAtCapture: Double?
    /// Abonos **en la misma moneda del gasto**, ya sumados.
    var paymentsInOwnCurrency: Double
    /// Hay abonos en otra moneda: el saldo no se puede calcular. Se avisa en la UI.
    var hasForeignPayments: Bool
    /// Dinero que va a una cuenta tuya (`TransferDetector`): no es gasto. No
    /// suma en ningún total ni en ningún corte.
    var isTransfer: Bool
    /// Compra anulada por el banco, o el propio aviso de anulación: no es un
    /// gasto. Cuenta cero igual que un traslado.
    var isVoided: Bool
    /// «Compartir gasto»: lo que pusiste tú. Con valor, el gasto cuenta sólo
    /// esto más lo perdonado; lo demás es de tus amigos (`netCost`).
    var ownShare: Double?
    /// Lo perdonado de las partes de los demás: es gasto tuyo.
    var forgivenAmount: Double

    init(amount: Double,
         currency: String = "PEN",
         date: Date,
         category: String = "Otros",
         merchant: String = "",
         tags: [String] = [],
         isDebt: Bool = false,
         fxRateAtCapture: Double? = nil,
         paymentsInOwnCurrency: Double = 0,
         hasForeignPayments: Bool = false,
         isTransfer: Bool = false,
         isVoided: Bool = false,
         ownShare: Double? = nil,
         forgivenAmount: Double = 0) {
        self.amount = amount
        self.currency = currency
        self.date = date
        self.category = category
        self.merchant = merchant
        self.tags = tags
        self.isDebt = isDebt
        self.fxRateAtCapture = fxRateAtCapture
        self.paymentsInOwnCurrency = paymentsInOwnCurrency
        self.hasForeignPayments = hasForeignPayments
        self.isTransfer = isTransfer
        self.isVoided = isVoided
        self.ownShare = ownShare
        self.forgivenAmount = forgivenAmount
    }
}

struct IncomeSnapshot {
    var amount: Double
    var currency: String
    var date: Date
    /// `true` si es abono a una deuda (`debtReference != nil`): liquidación de un
    /// pasivo, no ingreso.
    var isDebtPayment: Bool
    var fxRateAtCapture: Double?
    /// Llega desde una cuenta tuya: no es ingreso nuevo, es el mismo dinero
    /// cambiando de sitio (ver `TransferDetector`).
    var isTransfer: Bool

    init(amount: Double,
         currency: String = "PEN",
         date: Date,
         isDebtPayment: Bool = false,
         fxRateAtCapture: Double? = nil,
         isTransfer: Bool = false) {
        self.amount = amount
        self.currency = currency
        self.date = date
        self.isDebtPayment = isDebtPayment
        self.fxRateAtCapture = fxRateAtCapture
        self.isTransfer = isTransfer
    }
}

// MARK: - PeriodTotals

/// Totales de un periodo. **Única** fuente de verdad para Resumen, Categorías y Ritmo.
///
/// Antes cada vista calculaba sus propios totales, y no coincidían entre sí:
/// - Resumen sumaba `unpaidAmount`, Categorías sumaba `amount` → el mismo mes
///   mostraba dos totales distintos si había una deuda con abonos.
/// - Resumen excluía los ingresos con `debtReference`, Tendencias los incluía
///   → un abono a deuda se contaba como ingreso en una pestaña y no en la otra.
/// - Cada movimiento en USD se convertía y luego se sumaba, redondeando N veces.
struct PeriodTotals {

    /// Lo que el periodo te **costó** de verdad, en soles: el importe de cada
    /// gasto menos lo que te hayan devuelto de él.
    ///
    /// Antes usaba el importe completo, con el argumento de que "un gasto de
    /// S/ 100 con S/ 40 abonados sigue siendo un gasto de S/ 100". Eso
    /// contradecía lo que la app promete en el onboarding —"lo marcas como por
    /// cobrar y no cuenta en tu mes"— y dejaba la función sin efecto visible:
    /// marcar algo por cobrar y recibir el dinero no movía ninguna cifra.
    /// Ahora un gasto reembolsado por completo aporta cero, y uno reembolsado a
    /// medias aporta lo que te quedaste sin recuperar.
    ///
    /// La resta se aplica a **todos** los desgloses (categorías, comercios,
    /// días) con el mismo criterio, para que sigan sumando exactamente `spent`.
    /// Lo que aún te deben es `debtOutstanding`, una cifra distinta.
    let spent: Double
    let spentBag: MoneyBag

    /// Ingresos reales: excluye los `Income` que son abono a una deuda,
    /// que son liquidación de un pasivo, no ingreso.
    let income: Double
    let incomeBag: MoneyBag

    /// Abonos a deudas hechos en el periodo. Se informan aparte; no son ingreso
    /// ni reducen el gasto del periodo en que se abonan.
    let debtPayments: Double

    /// Saldo pendiente de las deudas activas cuyo gasto cae en el periodo.
    let debtOutstanding: Double

    let byCategory: [CategoryTotal]
    let byMerchant: [MerchantTotal]

    /// Gasto por día del periodo, en orden. Base del scrubber y del gráfico de Ritmo.
    let dailySpent: [DayTotal]

    /// Movimientos sin clasificar del periodo.
    let unclassifiedTotal: Double
    let unclassifiedMerchantCount: Int

    let expenseCount: Int
    let hasMixedCurrencies: Bool
    /// Alguna deuda del periodo tiene abonos en otra moneda: su saldo es una
    /// aproximación y la UI debe decirlo.
    let hasForeignDebtPayments: Bool

    /// Gasto medio por día transcurrido.
    let averagePerDay: Double

    /// Balance sólo si el usuario registra ingresos. `nil` apaga la tarjeta
    /// en lugar de mostrar un "Restante" igual al gasto en negativo.
    var balance: Double? {
        Money.isZero(income) ? nil : Money.subtract(income, spent)
    }

    var busiestCategory: CategoryTotal? { byCategory.first }

    var maxDailySpent: Double { dailySpent.map(\.total).max() ?? 0 }

    func share(of category: CategoryTotal) -> Double? {
        Money.ratio(category.total, to: spent)
    }

    struct CategoryTotal: Identifiable, Equatable {
        let category: String
        let total: Double
        let merchantCount: Int
        var id: String { category }
    }

    struct MerchantTotal: Identifiable, Equatable {
        let merchant: String
        let total: Double
        let count: Int
        var id: String { merchant }
    }

    struct DayTotal: Identifiable, Equatable {
        let date: Date
        let total: Double
        var id: Date { date }
    }

    static let empty = PeriodTotals(
        spent: 0, spentBag: MoneyBag(), income: 0, incomeBag: MoneyBag(),
        debtPayments: 0, debtOutstanding: 0, byCategory: [], byMerchant: [],
        dailySpent: [], unclassifiedTotal: 0, unclassifiedMerchantCount: 0,
        expenseCount: 0, hasMixedCurrencies: false, hasForeignDebtPayments: false,
        averagePerDay: 0
    )
}

// MARK: - Accounting

enum Accounting {

    static let unclassified = "Sin Clasificar"

    // MARK: Conversión

    /// Céntimos de sol de un movimiento, convertidos **una sola vez** con el tipo
    /// de cambio del día en que ocurrió.
    ///
    /// Es la pieza que hace que los totales sean aditivos. El handoff convertía
    /// por grupo (una `MoneyBag` por categoría, otra por día, otra por comercio)
    /// y convertía cada bolsa al final; como cada conversión redondea, la suma de
    /// las categorías podía diferir del total en un céntimo — justo la igualdad
    /// que exige el punto 1 del checklist. Convirtiendo por movimiento, cada
    /// gasto aporta un entero fijo de céntimos a **todos** los desgloses, así que
    /// las sumas coinciden exactamente y un periodo siempre es igual a la suma de
    /// sus subperiodos.
    ///
    /// Además resuelve ACCOUNTING.md §9: con `fxRateAtCapture` guardado, el total
    /// de un mes cerrado deja de moverse cada vez que se actualiza el tipo de
    /// cambio. `fallbackRate` es sólo el respaldo para los registros antiguos.
    static func penCents(amount: Double,
                         currency: String,
                         fxRateAtCapture: Double?,
                         fallbackRate: Double) -> Int {
        let cents = Money.cents(amount)
        guard currency != "PEN" else { return cents }
        let rate = fxRateAtCapture ?? fallbackRate
        return Money.multiplyCents(cents, by: rate)
    }

    static func penCents(_ expense: ExpenseSnapshot, fallbackRate: Double) -> Int {
        penCents(amount: expense.amount, currency: expense.currency,
                 fxRateAtCapture: expense.fxRateAtCapture, fallbackRate: fallbackRate)
    }

    static func penCents(_ income: IncomeSnapshot, fallbackRate: Double) -> Int {
        penCents(amount: income.amount, currency: income.currency,
                 fxRateAtCapture: income.fxRateAtCapture, fallbackRate: fallbackRate)
    }

    /// Monto de un movimiento en soles, para mostrar una fila suelta.
    static func amountInPEN(_ expense: ExpenseSnapshot, fallbackRate: Double) -> Double {
        Money.value(penCents(expense, fallbackRate: fallbackRate))
    }

    // MARK: Totales

    /// Calcula todos los totales del periodo en una sola pasada, sobre valores puros.
    static func totals(expenses: [ExpenseSnapshot],
                       incomes: [IncomeSnapshot],
                       period: Period,
                       usdToPen: Double) -> PeriodTotals {

        let interval = period.interval
        // Intervalo semiabierto [start, end) — ACCOUNTING.md §1. Los traslados
        // entre tus cuentas no entran: ni gasto, ni ingreso, ni categoría
        // (ver `TransferDetector`).
        let periodExpenses = expenses.filter {
            !$0.isTransfer && !$0.isVoided && $0.date >= interval.start && $0.date < interval.end
        }
        let periodIncomes = incomes.filter { !$0.isTransfer && $0.date >= interval.start && $0.date < interval.end }

        let cal = Period.calendar

        var spentCents = 0
        var spentBag = MoneyBag()
        var categoryCents: [String: Int] = [:]
        var categoryMerchants: [String: Set<String>] = [:]
        var merchantCents: [String: Int] = [:]
        var merchantCounts: [String: Int] = [:]
        var dayCents: [Date: Int] = [:]
        var unclassifiedCents = 0
        var unclassifiedMerchants: Set<String> = []
        var outstandingCents = 0
        var foreignDebtPayments = false

        for e in periodExpenses {
            // Neto: importe menos lo devuelto en su misma moneda. Para un gasto
            // sin devoluciones es el importe tal cual, así que el caso normal
            // no cambia.
            let net = netCost(of: e)
            let c = penCents(amount: net,
                             currency: e.currency,
                             fxRateAtCapture: e.fxRateAtCapture,
                             fallbackRate: usdToPen)
            spentCents += c
            spentBag.add(net, currency: e.currency)

            categoryCents[e.category, default: 0] += c
            categoryMerchants[e.category, default: []].insert(e.merchant)
            merchantCents[e.merchant, default: 0] += c
            merchantCounts[e.merchant, default: 0] += 1
            dayCents[cal.startOfDay(for: e.date), default: 0] += c

            if e.category == unclassified {
                unclassifiedCents += c
                unclassifiedMerchants.insert(e.merchant)
            }

            if e.isDebt {
                outstandingCents += penCents(amount: outstanding(of: e),
                                             currency: e.currency,
                                             fxRateAtCapture: e.fxRateAtCapture,
                                             fallbackRate: usdToPen)
                if e.hasForeignPayments { foreignDebtPayments = true }
            }
        }

        // Ingreso real vs. abono a deuda — ACCOUNTING.md §3 y §4.
        var incomeCents = 0
        var debtPaymentCents = 0
        var incomeBag = MoneyBag()
        for i in periodIncomes {
            let c = penCents(i, fallbackRate: usdToPen)
            if i.isDebtPayment {
                debtPaymentCents += c
            } else {
                incomeCents += c
                incomeBag.add(i.amount, currency: i.currency)
            }
        }

        let byCategory = categoryCents
            .map { key, cents in
                PeriodTotals.CategoryTotal(category: key,
                                           total: Money.value(cents),
                                           merchantCount: categoryMerchants[key]?.count ?? 0)
            }
            .sorted { lhs, rhs in
                Money.cents(lhs.total) == Money.cents(rhs.total)
                    ? lhs.category < rhs.category
                    : Money.cents(lhs.total) > Money.cents(rhs.total)
            }

        let byMerchant = merchantCents
            .map { key, cents in
                PeriodTotals.MerchantTotal(merchant: key,
                                           total: Money.value(cents),
                                           count: merchantCounts[key] ?? 0)
            }
            .sorted { lhs, rhs in
                Money.cents(lhs.total) == Money.cents(rhs.total)
                    ? lhs.merchant < rhs.merchant
                    : Money.cents(lhs.total) > Money.cents(rhs.total)
            }

        let dailySpent = period.days.map { day in
            PeriodTotals.DayTotal(date: day, total: Money.value(dayCents[day] ?? 0))
        }

        let spent = Money.value(spentCents)

        return PeriodTotals(
            spent: spent,
            spentBag: spentBag,
            income: Money.value(incomeCents),
            incomeBag: incomeBag,
            debtPayments: Money.value(debtPaymentCents),
            debtOutstanding: Money.value(outstandingCents),
            byCategory: byCategory,
            byMerchant: byMerchant,
            dailySpent: dailySpent,
            unclassifiedTotal: Money.value(unclassifiedCents),
            unclassifiedMerchantCount: unclassifiedMerchants.count,
            expenseCount: periodExpenses.count,
            hasMixedCurrencies: spentBag.isMixed,
            hasForeignDebtPayments: foreignDebtPayments,
            averagePerDay: Money.divide(spent, by: max(1, period.elapsedDays))
        )
    }

    // MARK: Saldos de deuda

    /// Saldo pendiente de un gasto marcado como deuda.
    ///
    /// **Corrección (ACCOUNTING.md §5):** `Expense.unpaidAmount` sumaba los abonos
    /// sin mirar la moneda, así que un abono de $ 40 restaba 40 soles a una deuda
    /// en soles. Aquí sólo cuentan los abonos de la misma moneda del gasto; si hay
    /// abonos en otra moneda, `hasForeignPayments` lo delata para avisar en la UI
    /// en lugar de calcular mal en silencio.
    /// Lo que un gasto te costó de verdad: su importe menos lo devuelto.
    ///
    /// Numéricamente coincide con `outstanding` —las dos son `importe −
    /// devuelto`— pero responden a preguntas distintas: ésta es "cuánto me
    /// costó" y sirve para cualquier gasto; `outstanding` es "cuánto me deben"
    /// y sólo tiene sentido en uno marcado por cobrar. Se dejan separadas para
    /// que cambiar una no arrastre a la otra sin querer.
    ///
    /// Un traslado cuesta cero: el dinero sigue siendo tuyo. Así lo excluye
    /// cualquier suma que pase por aquí —límites, etiquetas, detalle de
    /// categoría—, no sólo `totals`.
    ///
    /// Compartido («Soluciones de cobro»): cuenta tu parte más lo que
    /// perdonaste, nunca más que el importe. Los pagos de tus amigos no lo
    /// bajan: ya no eran gasto tuyo.
    static func netCost(of expense: ExpenseSnapshot) -> Double {
        guard !expense.isTransfer, !expense.isVoided else { return 0 }
        if let own = expense.ownShare {
            return min(Money.normalized(expense.amount),
                       Money.clampedToZero(Money.normalized(own + expense.forgivenAmount)))
        }
        return Money.clampedToZero(Money.subtract(expense.amount, expense.paymentsInOwnCurrency))
    }

    /// Compartido: lo de los demás que falta, sin lo perdonado.
    static func outstanding(of expense: ExpenseSnapshot) -> Double {
        if let own = expense.ownShare {
            let others = Money.subtract(expense.amount, Money.normalized(own + expense.forgivenAmount))
            return Money.clampedToZero(Money.subtract(others, expense.paymentsInOwnCurrency))
        }
        return Money.clampedToZero(Money.subtract(expense.amount, expense.paymentsInOwnCurrency))
    }

    static func paid(of expense: ExpenseSnapshot) -> Double {
        Money.normalized(expense.paymentsInOwnCurrency)
    }

    /// Un abono no puede exceder el saldo — ACCOUNTING.md §6: `max(0, …)` escondía
    /// los sobrepagos, y un abono mal tecleado (400 en vez de 40) no se detectaba.
    static func clampPayment(_ amount: Double, to expense: ExpenseSnapshot) -> Double {
        min(Money.normalized(amount), outstanding(of: expense))
    }

    /// Nombre de comercio limpio para mostrar.
    static func displayName(_ merchant: String) -> String {
        merchant
            .replacingOccurrences(of: "PLIN - ", with: "")
            .replacingOccurrences(of: "YAPE - ", with: "")
    }
}
