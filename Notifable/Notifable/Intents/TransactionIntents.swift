import AppIntents
import SwiftData
import Foundation

// MARK: - Valores elegibles

/// Fuente de un ingreso. Los mismos cinco chips del formulario
/// (`AddTransactionSheet.sources`); por ser una lista cerrada Siri la puede
/// reconocer dentro de la frase: "Registra un ingreso de Yape en AgruPay".
enum IncomeSourceOption: String, AppEnum {
    case transferencia = "Transferencia"
    case yape = "Yape"
    case plin = "Plin"
    case efectivo = "Efectivo"
    case otro = "Otro"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fuente"
    static var caseDisplayRepresentations: [IncomeSourceOption: DisplayRepresentation] = [
        .transferencia: DisplayRepresentation(title: "Transferencia", synonyms: ["transferencia bancaria", "depósito"]),
        .yape: DisplayRepresentation(title: "Yape", synonyms: ["yapeo", "un yape"]),
        .plin: DisplayRepresentation(title: "Plin", synonyms: ["un plin"]),
        .efectivo: DisplayRepresentation(title: "Efectivo", synonyms: ["cash", "billete"]),
        .otro: DisplayRepresentation(title: "Otro")
    ]
}

enum CurrencyOption: String, AppEnum {
    case soles = "PEN"
    case dolares = "USD"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Moneda"
    static var caseDisplayRepresentations: [CurrencyOption: DisplayRepresentation] = [
        .soles: DisplayRepresentation(title: "soles", synonyms: ["sol", "PEN"]),
        .dolares: DisplayRepresentation(title: "dólares", synonyms: ["dólar", "USD"])
    ]
}

/// Una categoría de gasto. Es una entidad y no un enum porque el usuario crea
/// las suyas; la lista sale de `CategoryStyle.selectable`, igual que en el formulario.
struct ExpenseCategoryEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Categoría"
    static var defaultQuery = ExpenseCategoryQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", image: .init(systemName: CategoryStyle.icon(for: id)))
    }
}

struct ExpenseCategoryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ExpenseCategoryEntity] {
        let known = Set(try await Self.names())
        return identifiers.filter(known.contains).map(ExpenseCategoryEntity.init(id:))
    }

    @MainActor
    func entities(matching string: String) async throws -> [ExpenseCategoryEntity] {
        try await Self.names()
            .filter { IntentText.matches($0, string) }
            .map(ExpenseCategoryEntity.init(id:))
    }

    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        try await Self.names().map(ExpenseCategoryEntity.init(id:))
    }

    /// Las categorías, las más usadas primero.
    ///
    /// iOS pide esto cada vez que la app actualiza sus frases de Siri —tras
    /// cada guardado—, a menudo mientras se usa la app. Leer todo el historial
    /// en el hilo principal eran ~160 ms de pantalla trabada; ahora se cuenta
    /// en segundo plano y sólo con la categoría de cada gasto.
    @MainActor
    static func names() async throws -> [String] {
        let container = AppModelContainer.shared
        let counts = try await Task.detached(priority: .userInitiated) {
            var descriptor = FetchDescriptor<Expense>()
            descriptor.propertiesToFetch = [\.category]
            return CategoryStyle.usageCounts(try ModelContext(container).fetch(descriptor))
        }.value
        return CategoryStyle.selectable(counts: counts)
    }
}

/// Un gasto rápido guardado ("Pasaje", "Café"). Ya tiene monto y categoría,
/// así que la frase queda completa sin que Siri pregunte nada.
struct QuickExpenseEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Gasto rápido"
    static var defaultQuery = QuickExpenseQuery()

    var id: UUID
    var label: String
    var amountText: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(amountText)")
    }

    init(_ quick: QuickExpense) {
        id = quick.id
        label = quick.label
        amountText = Money.format(quick.amount, currency: quick.currency)
    }
}

struct QuickExpenseQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [QuickExpenseEntity] {
        try Self.all().filter { identifiers.contains($0.id) }.map(QuickExpenseEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [QuickExpenseEntity] {
        try Self.all()
            .filter { IntentText.matches($0.label, string) || IntentText.matches($0.merchant, string) }
            .map(QuickExpenseEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [QuickExpenseEntity] {
        try Self.all().map(QuickExpenseEntity.init)
    }

    @MainActor
    static func all() throws -> [QuickExpense] {
        try AppModelContainer.shared.mainContext.fetch(FetchDescriptor<QuickExpense>(sortBy: [SortDescriptor(\.sortIndex)]))
    }
}

enum IntentText {
    /// Sin tildes ni mayúsculas: Siri transcribe "cafe" o "Café" según el día.
    static func matches(_ candidate: String, _ query: String) -> Bool {
        let fold: (String) -> String = {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_PE"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let q = fold(query)
        return !q.isEmpty && fold(candidate).contains(q)
    }
}

/// Un error que Siri lee tal cual.
struct IntentMessage: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    var localizedStringResource: LocalizedStringResource { "\(text)" }
}

// MARK: - Registrar ingreso

struct AddIncomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar ingreso"
    static var description = IntentDescription("Anota un ingreso en AgruPay: monto, fuente y moneda.")
    /// Con el iPhone bloqueado pide desbloquear: un ingreso toca tus cuentas.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Monto", requestValueDialog: IntentDialog("¿Cuánto recibiste?"))
    var amount: Double

    @Parameter(title: "Fuente", default: .transferencia)
    var source: IncomeSourceOption

    @Parameter(title: "Moneda", default: .soles)
    var currency: CurrencyOption

    @Parameter(title: "Concepto")
    var concept: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar ingreso de \(\.$amount) \(\.$currency) por \(\.$source)") {
            \.$concept
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var draft = TransactionDraft(type: .ingreso)
        draft.amountText = String(format: "%.2f", amount)
        draft.currency = currency.rawValue
        draft.source = source.rawValue
        draft.title = concept ?? ""
        try IntentSaving.check(draft)

        let formatted = Money.format(draft.amount, currency: draft.currency)
        try await requestConfirmation(actionName: .add,
                                      dialog: IntentDialog("¿Registro un ingreso de \(formatted) por \(source.rawValue)?"))

        guard let resolution = draft.resolveIncome() else { throw IntentMessage(text: "No pude registrar el ingreso.") }
        try IntentSaving.insert(resolution.income)
        return .result(dialog: IntentDialog("Listo: ingreso de \(formatted) por \(source.rawValue)."))
    }
}

// MARK: - Registrar gasto

struct AddExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar gasto"
    static var description = IntentDescription("Anota un gasto en AgruPay: monto, categoría y comercio.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Monto", requestValueDialog: IntentDialog("¿Cuánto gastaste?"))
    var amount: Double

    @Parameter(title: "Categoría", requestValueDialog: IntentDialog("¿En qué categoría?"))
    var category: ExpenseCategoryEntity

    @Parameter(title: "Moneda", default: .soles)
    var currency: CurrencyOption

    /// Opcional: por voz basta con la categoría, y el gasto se llama como ella.
    @Parameter(title: "Comercio")
    var merchant: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar gasto de \(\.$amount) \(\.$currency) en \(\.$category)") {
            \.$merchant
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var draft = TransactionDraft(type: .gasto)
        draft.amountText = String(format: "%.2f", amount)
        draft.currency = currency.rawValue
        draft.category = category.id
        let name = merchant?.trimmed ?? ""
        draft.merchant = name.isEmpty ? category.id : name
        try IntentSaving.check(draft)

        let formatted = Money.format(draft.amount, currency: draft.currency)
        try await requestConfirmation(actionName: .add,
                                      dialog: IntentDialog("¿Registro un gasto de \(formatted) en \(category.id)?"))

        guard let expense = draft.makeExpense() else { throw IntentMessage(text: "No pude registrar el gasto.") }
        try IntentSaving.insert(expense)
        return .result(dialog: IntentDialog("Listo: gasto de \(formatted) en \(category.id)."))
    }
}

// MARK: - Gasto rápido

struct LogQuickExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Registrar gasto rápido"
    static var description = IntentDescription("Registra uno de tus gastos rápidos con su monto guardado.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Gasto rápido", requestValueDialog: IntentDialog("¿Cuál gasto rápido?"))
    var quick: QuickExpenseEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar \(\.$quick)")
    }

    /// Sin confirmación: el monto no sale de lo que Siri entendió, sino de lo
    /// que el usuario guardó. Es el mismo gesto que el doble toque del formulario.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let stored = try QuickExpenseQuery.all().first(where: { $0.id == quick.id }) else {
            throw IntentMessage(text: "Ese gasto rápido ya no existe.")
        }
        let expense = stored.makeExpense()
        stored.useCount += 1
        stored.lastUsedAt = Date()
        try IntentSaving.insert(expense)
        let formatted = Money.format(expense.amount, currency: expense.currency)
        return .result(dialog: IntentDialog("Listo: \(stored.label), \(formatted)."))
    }
}

// MARK: - Resumen del mes

struct MonthSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Gasto del mes"
    static var description = IntentDescription("Te dice cuánto llevas gastado este mes y cuánto te queda.")
    /// Lee montos en voz alta: nada de eso con el iPhone bloqueado.
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Double> {
        let now = Date()
        let snapshot = try WidgetSnapshotWriter.makeSnapshot(context: AppModelContainer.shared.mainContext, now: now)
        let d = WidgetDerived(snapshot, at: now)
        return .result(value: Money.value(d.spentCents), dialog: IntentDialog(stringLiteral: Self.sentence(snapshot, d, now: now)))
    }

    static func sentence(_ snapshot: WidgetSnapshot, _ d: WidgetDerived, now: Date) -> String {
        let month = Period.spanishMonthName(for: now).lowercased()
        var text = "Llevas " + Money.format(Money.value(d.spentCents)) + " en " + month + "."
        if let remaining = d.remainingCents, let status = d.status {
            switch status {
            case .over:
                text += " Ya pasaste tu presupuesto."
            case .ok, .warning:
                text += " Te quedan " + Money.format(Money.value(remaining))
                if let perDay = d.availablePerDayCents {
                    text += ", unos " + Money.format(Money.value(perDay)) + " por día"
                }
                text += status == .warning ? ", y vas por encima del ritmo." : "."
            }
        }
        if d.todayCents > 0 {
            text += " Hoy: " + Money.format(Money.value(d.todayCents)) + "."
        }
        return text
    }
}

// MARK: - Guardado compartido

@MainActor
enum IntentSaving {

    /// La misma validación del formulario: Siri no puede guardar lo que la
    /// pantalla no dejaría guardar.
    static func check(_ draft: TransactionDraft) throws {
        switch draft.validation {
        case .ready: return
        case .blocked(let message), .invalid(let message):
            throw IntentMessage(text: message)
        }
    }

    static func insert(_ model: some PersistentModel) throws {
        let context = AppModelContainer.shared.mainContext
        context.insert(model)
        try context.save()
        if let expense = model as? Expense {
            Analytics.track(.movementCreated, ["source": "siri", "kind": "expense",
                                               "category_source": expense.category == Accounting.unclassified ? "none" : "user",
                                               "category": Analytics.categoryLabel(expense.category)])
        } else if model is Income {
            Analytics.track(.movementCreated, ["source": "siri", "kind": "income"])
        }
        Analytics.featureUsed(.siri)
        Analytics.milestone(.firstMovement)
        // Siri puede suspender la app al terminar: que salga ya.
        Analytics.shared.flush()
        // Sin esperar la ráfaga: Siri puede suspender la app al terminar.
        WidgetSnapshotWriter.shared.refreshNow()
    }
}
