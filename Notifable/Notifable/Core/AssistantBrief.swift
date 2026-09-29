import Foundation

// MARK: - Datos de entrada

/// Todo lo que el asistente sabe de tu dinero, ya leído de la base y
/// convertido en valores: las reglas de abajo y el chat no tocan SwiftData.
struct AssistantInputs {
    var now: Date = Date()
    /// Al menos el mes en curso y los tres anteriores.
    var expenses: [ExpenseSnapshot]
    var incomes: [IncomeSnapshot]
    var usdToPen: Double
    var monthlyBudget: Double = 0
    var budgetEnabled: Bool = false
    var limits: [CategoryLimitStatus] = []
    /// Cobros programados que todavía no llegan, de hoy en adelante.
    var upcoming: [UpcomingCharge] = []
    /// Gastos por cobrar con saldo pendiente.
    var debts: [OpenDebt] = []
}

struct UpcomingCharge: Equatable {
    let id: UUID
    let name: String
    let amount: Double
    let currency: String
    let date: Date
}

struct OpenDebt: Equatable {
    let id: UUID
    let name: String
    let outstanding: Double
    let date: Date
}

/// A dónde lleva un botón del asistente: siempre a una pantalla real.
enum AssistantAction: Hashable, Codable {
    case section(Int)          // `AppSection.rawValue`
    case category(String)
    case recurring
    case reminder(UUID)

    static func open(_ section: AppSection) -> AssistantAction { .section(section.rawValue) }
}

// MARK: - Tarjetas

struct BriefCard: Identifiable, Equatable {
    enum Kind: String { case rhythm, limits, comparison, committed, friends, unusual }

    let kind: Kind
    let icon: String
    let title: String
    /// La frase de plantilla. Es la que se ve sin Apple Intelligence y la
    /// base que el modelo reescribe.
    var text: String
    let cta: String?
    let action: AssistantAction?
    /// Qué la hace «nueva»: si cambia, el ✦ vuelve a llevar punto.
    let signature: String

    var id: String { kind.rawValue }
}

/// «Tu resumen»: las reglas deciden qué se cuenta y con qué cifras; la IA,
/// como mucho, lo redacta (`AssistantAI`).
///
/// Ritmo y la comparación con el mes anterior salen siempre. Comprometido,
/// sólo si hay un cobro en los próximos `committedDays` días; Amigos, sólo si
/// alguien te debe desde hace `debtAgeDays` días o más; Límites, sólo si una
/// categoría va cerca o pasada.
enum AssistantBrief {

    static let committedDays = 3
    static let debtAgeDays = 7

    static func cards(_ input: AssistantInputs) -> [BriefCard] {
        [rhythm(input), limits(input), unusual(input), comparison(input), committed(input), friends(input)]
            .compactMap { $0 }
            .map { card in
                var card = card
                card.text = tidy(card.text)
                return card
            }
    }

    /// `Money.format` separa el símbolo con espacio ancho («S/  2.50»): en
    /// una frase se lee como un error.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"[\s\u00A0\u202F]+"#, with: " ", options: .regularExpression)
    }

    // MARK: Ritmo

    static func rhythm(_ input: AssistantInputs) -> BriefCard {
        let month = Period(granularity: .mes, reference: input.now)
        let totals = Accounting.totals(expenses: input.expenses, incomes: input.incomes,
                                       period: month, usdToPen: input.usdToPen)
        let name = Period.spanishMonthName(for: input.now).lowercased()
        let day = dayKey(input.now)
        let text: String

        if let pace = BudgetStore.pace(monthlyBudget: input.monthlyBudget, enabled: input.budgetEnabled,
                                       for: month, spent: totals.spent) {
            if let perDay = pace.availablePerDay, Money.cents(perDay) > 0 {
                text = "Hoy puedes gastar \(Money.formatCompact(perDay)) y seguir dentro de tu presupuesto."
            } else if Money.cents(pace.remaining) == 0 {
                text = "Ya usaste tu presupuesto de \(name): vas \(Money.formatCompact(Money.subtract(pace.spent, pace.target))) por encima."
            } else {
                text = "Te quedan \(Money.formatCompact(pace.remaining)) de tu presupuesto de \(name)."
            }
        } else if month.elapsedDays < 3 || Money.cents(totals.spent) == 0 {
            text = Money.cents(totals.spent) == 0
                ? "Todavía no hay gastos en \(name)."
                : "Llevas \(Money.formatCompact(totals.spent)) en \(name). Aún es pronto para proyectar el mes."
        } else {
            let projection = totals.spent / max(month.elapsedFraction, 0.01)
            let perDay = Money.divide(totals.spent, by: month.elapsedDays)
            var sentence = "A este paso cerrarías \(name) en \(Money.formatCompact(projection)), unos \(Money.formatCompact(perDay)) por día."
            let previous = Accounting.totals(expenses: input.expenses, incomes: input.incomes,
                                             period: month.previous, usdToPen: input.usdToPen).spent
            if Money.cents(previous) > 0 {
                let delta = Money.subtract(projection, previous)
                let previousName = Period.spanishMonthName(for: month.previous.reference).lowercased()
                if abs(Money.cents(delta)) >= 100 * 100 || Money.ratio(abs(delta), to: previous).map({ $0 >= 0.05 }) == true {
                    sentence += Money.cents(delta) > 0
                        ? " Serían \(Money.formatCompact(abs(delta))) más que en \(previousName)."
                        : " Serían \(Money.formatCompact(abs(delta))) menos que en \(previousName)."
                }
            }
            text = sentence
        }

        return BriefCard(kind: .rhythm, icon: "speedometer", title: "RITMO", text: text,
                         cta: "Ver análisis", action: .open(.analysis), signature: "rhythm:" + day)
    }

    // MARK: Límites

    static func limits(_ input: AssistantInputs) -> BriefCard? {
        let flagged = input.limits
            .filter { $0.hasLimit && ($0.level == .pasado || $0.level == .cerca) }
            .sorted { ($0.isOver ? 1 : 0, $0.fraction) > ($1.isOver ? 1 : 0, $1.fraction) }
        guard let first = flagged.first else { return nil }

        var text: String
        if first.isOver {
            text = "Pasaste el límite de \(first.category) por \(Money.formatCompact(first.overBy))."
        } else {
            let percent = Int((first.fraction * 100).rounded())
            text = "\(first.category) va al \(percent)% de su límite; quedan \(Money.formatCompact(first.remaining))"
                + (first.daysLeft > 0 ? " para \(first.daysLeft) \(first.daysLeft == 1 ? "día" : "días")." : ".")
        }
        if flagged.count > 1 {
            let others = flagged.count - 1
            text += others == 1 ? " Otra categoría también va cerca." : " Otras \(others) también van cerca."
        }
        let signature = "limits:" + flagged.map { "\($0.category)=\($0.level == .pasado ? "p" : "c")" }.joined(separator: ",")
        return BriefCard(kind: .limits, icon: "gauge.with.dots.needle.67percent", title: "LÍMITES", text: text,
                         cta: "Ver " + first.category, action: .category(first.category), signature: signature)
    }

    // MARK: Contra el mes anterior

    /// A la misma altura del mes: del 1 a hoy contra del 1 al mismo día del
    /// mes anterior (o su último día, si es más corto).
    static func comparison(_ input: AssistantInputs) -> BriefCard {
        let cal = Period.calendar
        let month = Period(granularity: .mes, reference: input.now)
        let previousMonth = month.previous
        let name = Period.spanishMonthName(for: previousMonth.reference).lowercased()
        let today = cal.startOfDay(for: input.now)
        let dayOfMonth = cal.component(.day, from: today)
        let previousStart = previousMonth.interval.start
        let previousLength = cal.range(of: .day, in: .month, for: previousStart)?.count ?? 30
        let previousEnd = cal.date(byAdding: .day, value: min(dayOfMonth, previousLength) - 1, to: previousStart) ?? previousStart

        let now = Accounting.totals(expenses: input.expenses, incomes: input.incomes,
                                    period: Period(granularity: .rango, customStart: month.interval.start, customEnd: today),
                                    usdToPen: input.usdToPen)
        let before = Accounting.totals(expenses: input.expenses, incomes: input.incomes,
                                       period: Period(granularity: .rango, customStart: previousStart, customEnd: previousEnd),
                                       usdToPen: input.usdToPen)
        let day = dayKey(input.now)

        guard Money.cents(before.spent) > 0 else {
            return BriefCard(kind: .comparison, icon: "arrow.left.arrow.right", title: "VS. \(name.uppercased())",
                             text: "Aún no hay gastos de \(name) para comparar.",
                             cta: nil, action: nil, signature: "comparison:" + day)
        }

        let delta = Money.subtract(now.spent, before.spent)
        let changes = categoryChanges(now: now, before: before)
        var text: String
        var focus: String?

        if abs(Money.cents(delta)) < 1_000 {
            text = "Vas casi igual que en \(name) a esta altura: \(Money.formatCompact(now.spent))."
        } else if Money.cents(delta) > 0 {
            text = "Llevas \(Money.formatCompact(delta)) más que en \(name) a esta altura."
            if let top = changes.first(where: { Money.cents($0.delta) > 0 }) {
                focus = top.category
                text += " \(Money.formatCompact(top.delta)) vienen de \(top.category)."
            }
        } else {
            text = "Llevas \(Money.formatCompact(abs(delta))) menos que en \(name) a esta altura."
            if let top = changes.last(where: { Money.cents($0.delta) < 0 }) {
                focus = top.category
                text += " Lo que más bajó es \(top.category), \(Money.formatCompact(abs(top.delta))) menos."
            }
        }

        return BriefCard(kind: .comparison, icon: "arrow.left.arrow.right", title: "VS. \(name.uppercased())",
                         text: text,
                         cta: focus.map { "Ver " + $0 } ?? "Ver categorías",
                         action: focus.map { .category($0) } ?? .open(.categories),
                         signature: "comparison:" + day)
    }

    struct CategoryChange: Equatable {
        let category: String
        let now: Double
        let before: Double
        var delta: Double { Money.subtract(now, before) }
    }

    /// De la que más subió a la que más bajó. Sin «Sin Clasificar»: no es
    /// una categoría que se pueda explicar.
    static func categoryChanges(now: PeriodTotals, before: PeriodTotals) -> [CategoryChange] {
        var names = Set(now.byCategory.map(\.category))
        names.formUnion(before.byCategory.map(\.category))
        names.remove(Accounting.unclassified)
        let current = Dictionary(now.byCategory.map { ($0.category, $0.total) }, uniquingKeysWith: +)
        let previous = Dictionary(before.byCategory.map { ($0.category, $0.total) }, uniquingKeysWith: +)
        return names
            .map { CategoryChange(category: $0, now: current[$0] ?? 0, before: previous[$0] ?? 0) }
            .sorted { Money.cents($0.delta) > Money.cents($1.delta) }
    }

    // MARK: Comprometido

    static func committed(_ input: AssistantInputs) -> BriefCard? {
        let cal = Period.calendar
        let today = cal.startOfDay(for: input.now)
        guard let limit = cal.date(byAdding: .day, value: committedDays + 1, to: today) else { return nil }
        let soon = input.upcoming
            .filter { $0.date >= today && $0.date < limit }
            .sorted { $0.date < $1.date }
        guard let first = soon.first else { return nil }

        let text: String
        if soon.count == 1 {
            text = "\(relativeDay(first.date, now: input.now).capitalizedFirst) te cobran \(first.name), \(Money.format(first.amount, currency: first.currency))."
        } else {
            let total = Money.sum(soon.map { $0.currency == "USD" ? Money.multiply($0.amount, by: input.usdToPen) : $0.amount })
            let list = soon.prefix(3).map { "\($0.name) \(relativeDay($0.date, now: input.now))" }.joined(separator: ", ")
            text = "En los próximos \(committedDays) días te cobran \(soon.count) cosas por \(Money.formatCompact(total)): \(list)."
        }
        let signature = "committed:" + soon.map { "\($0.id.uuidString.prefix(8))@\(dayKey($0.date))" }.joined(separator: ",")
        return BriefCard(kind: .committed, icon: "calendar.badge.clock", title: "COMPROMETIDO", text: text,
                         cta: "Ver suscripciones", action: .recurring, signature: signature)
    }

    // MARK: Amigos

    static func friends(_ input: AssistantInputs) -> BriefCard? {
        let cal = Period.calendar
        let today = cal.startOfDay(for: input.now)
        let old = input.debts
            .filter { Money.cents($0.outstanding) > 0 }
            .filter { (cal.dateComponents([.day], from: cal.startOfDay(for: $0.date), to: today).day ?? 0) >= debtAgeDays }
            .sorted { $0.date < $1.date }
        guard let first = old.first else { return nil }

        let days = cal.dateComponents([.day], from: cal.startOfDay(for: first.date), to: today).day ?? 0
        var text = "Te deben \(Money.formatCompact(first.outstanding)) de «\(first.name)» desde hace \(days) días."
        if old.count > 1 {
            let rest = Money.sum(old.dropFirst().map(\.outstanding))
            text += old.count == 2
                ? " Y \(Money.formatCompact(rest)) más en otro cobro."
                : " Y \(Money.formatCompact(rest)) más en otros \(old.count - 1) cobros."
        }
        let signature = "friends:" + old.map { String($0.id.uuidString.prefix(8)) }.joined(separator: ",")
        return BriefCard(kind: .friends, icon: "person.2.fill", title: "AMIGOS", text: text,
                         cta: "Enviar recordatorio", action: .reminder(first.id), signature: signature)
    }

    // MARK: Gastos raros

    /// Cuántos días atrás se mira en busca de un gasto fuera de lo habitual.
    static let unusualDays = 3

    /// Un gasto de los últimos días que es varias veces lo que sueles gastar
    /// en esa categoría (Configuración › Asistente › Avisos de gastos raros).
    /// Hace falta historia: al menos cinco gastos de la categoría en los tres
    /// meses anteriores, y que el monto sea de verdad llamativo.
    static func unusual(_ input: AssistantInputs) -> BriefCard? {
        guard AssistantSettings.unusualAlerts else { return nil }
        let cal = Period.calendar
        let today = cal.startOfDay(for: input.now)
        guard let recentStart = cal.date(byAdding: .day, value: -unusualDays, to: today),
              let historyStart = cal.date(byAdding: .month, value: -3, to: recentStart) else { return nil }

        let spending = input.expenses.filter {
            !$0.isTransfer && !$0.isVoided && !$0.isDebt && $0.category != Accounting.unclassified
        }
        func pen(_ expense: ExpenseSnapshot) -> Double {
            Accounting.amountInPEN(expense, fallbackRate: input.usdToPen)
        }

        var best: (expense: ExpenseSnapshot, ratio: Double)?
        for expense in spending where expense.date >= recentStart && expense.date <= input.now {
            let past = spending
                .filter { $0.category == expense.category && $0.date >= historyStart && $0.date < recentStart }
                .map(pen)
                .sorted()
            guard past.count >= 5 else { continue }
            let median = past[past.count / 2]
            let amount = pen(expense)
            guard median > 0, amount >= 50 else { continue }
            let ratio = amount / median
            guard ratio >= 3, ratio > (best?.ratio ?? 0) else { continue }
            best = (expense, ratio)
        }
        guard let found = best else { return nil }

        let name = Accounting.displayName(found.expense.merchant)
        let times = Int(found.ratio.rounded())
        let text = "«\(name)» te cobró \(Money.formatCompact(pen(found.expense))) \(relativePast(found.expense.date, now: input.now)): "
            + "unas \(times) veces lo que sueles gastar en \(found.expense.category)."
        let signature = "unusual:\(dayKey(found.expense.date)):\(found.expense.merchant):\(Money.cents(found.expense.amount))"
        return BriefCard(kind: .unusual, icon: "exclamationmark.triangle.fill", title: "GASTO RARO", text: text,
                         cta: "Ver " + found.expense.category, action: .category(found.expense.category),
                         signature: signature)
    }

    /// «hoy», «ayer», «el martes».
    static func relativePast(_ date: Date, now: Date) -> String {
        let cal = Period.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "hoy"
        case 1: return "ayer"
        default:
            let names = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
            return "el " + names[(cal.component(.weekday, from: date) - 1) % 7]
        }
    }

    // MARK: Utilidades

    static func dayKey(_ date: Date) -> String {
        let c = Period.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// «hoy», «mañana», «pasado mañana», «el jueves».
    static func relativeDay(_ date: Date, now: Date) -> String {
        let cal = Period.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "hoy"
        case 1: return "mañana"
        case 2: return "pasado mañana"
        default:
            let names = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"]
            return "el " + names[(cal.component(.weekday, from: date) - 1) % 7]
        }
    }

    /// «Miércoles 24 de setiembre».
    static func headerDate(_ date: Date) -> String {
        let cal = Period.calendar
        let names = ["Domingo", "Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado"]
        return names[(cal.component(.weekday, from: date) - 1) % 7] + " "
            + String(cal.component(.day, from: date)) + " de "
            + Period.spanishMonthName(for: date).lowercased()
    }
}

// MARK: - Punto de novedades

/// El ✦ lleva punto cuando hay un resumen sin abrir: el primero del día, o
/// una tarjeta que no estaba la última vez que se abrió.
struct AssistantSeenState {
    static let key = "assistantSeenSignatures"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var seen: Set<String> { Set(defaults.stringArray(forKey: Self.key) ?? []) }

    func hasNews(_ cards: [BriefCard]) -> Bool {
        let seen = seen
        return cards.contains { !seen.contains($0.signature) }
    }

    /// Guarda sólo las firmas vigentes: las de días pasados sobran.
    func markSeen(_ cards: [BriefCard]) {
        defaults.set(cards.map(\.signature), forKey: Self.key)
    }
}

// MARK: - Ajustes del asistente

/// Configuración › Asistente (`4i`): qué propone y qué avisa. Todo encendido
/// por defecto, que es como funcionaba antes de tener interruptores.
enum AssistantSettings {
    /// «Resumen del día»: el punto en ✦ cuando hay algo nuevo.
    static let briefDotKey = "assistantBriefDot"
    /// «Sugerencias de categoría»: proponer categoría y regla para comercios.
    static let suggestionsKey = "assistantCategorySuggestions"
    /// «Avisos de gastos raros»: la tarjeta de montos fuera de lo habitual.
    static let unusualKey = "assistantUnusualAlerts"

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static var briefDot: Bool { flag(briefDotKey) }
    static var suggestions: Bool { flag(suggestionsKey) }
    static var unusualAlerts: Bool { flag(unusualKey) }
}
