import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// La parte del asistente que usa el modelo de Apple Intelligence del iPhone
/// (iOS 26+): gratis, sin red, y tus datos no salen del equipo.
///
/// **El modelo nunca pone cifras.** En el resumen sólo reescribe la frase que
/// ya armaron las reglas, y la reescritura se descarta si le falta o le
/// sobra algún monto. En el chat responde con lo que devuelven las
/// herramientas, que calculan las cifras con `Accounting`.
enum AssistantAI {

    static var isAvailable: Bool { VoiceMovementAI.isAvailable }

    // MARK: - Resumen

    /// Las tarjetas con la frase redactada por el modelo. Sin modelo —o si
    /// algo falla— quedan tal cual. Se guarda por firma y día: abrir el
    /// resumen dos veces no vuelve a esperar al modelo.
    static func polish(_ cards: [BriefCard], defaults: UserDefaults = .standard) async -> [BriefCard] {
        var cache = defaults.dictionary(forKey: polishCacheKey) as? [String: String] ?? [:]
        var result: [BriefCard] = []
        for var card in cards {
            let key = card.signature + "|" + card.text
            if let cached = cache[key] {
                card.text = cached
            } else if let rewritten = await rewrite(card.text) {
                cache[key] = rewritten
                card.text = rewritten
            }
            result.append(card)
        }
        // Sólo lo de las tarjetas vigentes.
        let live = Set(cards.map { $0.signature + "|" + $0.text })
        defaults.set(cache.filter { live.contains($0.key) }, forKey: polishCacheKey)
        return result
    }

    private static let polishCacheKey = "assistantPolishCache"

    private static func rewrite(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            let instructions = """
            Reescribes avisos cortos de una app de gastos personales para que suenen naturales y cercanos,
            en español peruano, tuteando. Máximo dos frases. No agregues consejos, saludos ni emojis.
            Conserva exactamente cada monto (con «S/» o «$»), cada porcentaje, cada fecha y cada nombre.
            No agregues cifras nuevas.
            """
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(to: "Aviso: \(text)") else { return nil }
            let candidate = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return keepsFigures(original: text, rewritten: candidate) ? candidate : nil
        }
        #endif
        return nil
    }

    /// Los mismos montos y números, ni uno más ni uno menos.
    static func keepsFigures(original: String, rewritten: String) -> Bool {
        guard !rewritten.isEmpty, rewritten.count <= max(240, original.count * 2) else { return false }
        return figures(in: original) == figures(in: rewritten)
    }

    static func figures(in text: String) -> [String] {
        let pattern = #"\d[\d,]*(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: ",", with: "") } }
            .sorted()
    }
}

// MARK: - Chat

/// Un mensaje del chat. Se guarda en `UserDefaults` y dura el día.
struct AssistantMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    var text: String
    var actions: [ActionChip] = []
    /// Cuándo se dijo: decide qué se sigue viendo y qué recuerda el modelo.
    var date = Date()

    struct ActionChip: Codable, Equatable, Hashable {
        let label: String
        let action: AssistantAction
    }
}

/// Cuánto dura el chat a la vista y cuánto recuerda el asistente.
///
/// Son dos plazos distintos: lo que se ve se borra tras unas horas sin
/// escribir (3 por defecto, se elige en la hoja), pero el asistente sigue
/// recordando lo hablado en las últimas 24 horas, así que «¿y lo de ayer?»
/// sigue teniendo respuesta aunque la pantalla ya esté limpia.
enum AssistantChatMemory {
    static let lifetimeKey = "assistantChatLifetimeHours"
    static let defaultLifetime = 3
    static let lifetimeOptions = [1, 2, 3, 5, 10, 15, 24]

    /// Lo que el asistente recuerda hacia atrás: 7 días gratis, 30 con Pro
    /// (Configuración › Asistente). Antes eran 24 horas para todos.
    static var memoryWindow: TimeInterval { TimeInterval(ProStore.assistantMemoryDays) * 24 * 3600 }
    /// Cuántos mensajes de esa memoria viajan al modelo. El de Apple
    /// Intelligence tiene un contexto chico (unos 4 000 tokens, con
    /// instrucciones, datos del mes y respuesta), así que van los últimos.
    static let contextLimit = 10
    /// Y cortados: una respuesta larga no puede comerse el contexto.
    static let contextCharacters = 280

    /// Lo que recuerda ahora mismo, leído de lo guardado (para Configuración
    /// › Asistente › Ver lo que recuerda).
    static func stored(_ defaults: UserDefaults = .standard, now: Date = Date()) -> [AssistantMessage] {
        pruned(AssistantChat.storedMessages(defaults), now: now)
    }

    /// Cuántos días de la ventana ya ocupa la memoria (del más viejo a hoy).
    static func daysUsed(_ memory: [AssistantMessage], now: Date = Date()) -> Int {
        guard let oldest = memory.map(\.date).min() else { return 0 }
        let cal = Period.calendar
        let days = (cal.dateComponents([.day], from: cal.startOfDay(for: oldest), to: cal.startOfDay(for: now)).day ?? 0) + 1
        return min(days, ProStore.assistantMemoryDays)
    }

    /// «Borrar memoria»: se olvida todo lo hablado.
    static func erase(_ defaults: UserDefaults = .standard) {
        AssistantChat.eraseStored(defaults)
    }

    static func lifetimeHours(_ defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: lifetimeKey)
        return lifetimeOptions.contains(stored) ? stored : defaultLifetime
    }

    /// Sólo lo que cabe en la ventana de memoria.
    static func pruned(_ messages: [AssistantMessage], now: Date,
                       window: TimeInterval = memoryWindow) -> [AssistantMessage] {
        messages.filter { now.timeIntervalSince($0.date) < window }
    }

    /// Desde cuándo se ve el chat. Si pasaron `lifetimeHours` desde el último
    /// mensaje a la vista, la conversación se da por terminada y la pantalla
    /// se limpia (se cuenta desde el último mensaje, no desde el primero: así
    /// nunca se borra a mitad de una conversación).
    static func clearedAt(_ messages: [AssistantMessage], clearedAt: Date?,
                          lifetimeHours: Int, now: Date) -> Date? {
        let shown = visible(messages, clearedAt: clearedAt)
        guard let last = shown.last,
              now.timeIntervalSince(last.date) >= TimeInterval(lifetimeHours) * 3600 else { return clearedAt }
        return now
    }

    static func visible(_ messages: [AssistantMessage], clearedAt: Date?) -> [AssistantMessage] {
        guard let clearedAt else { return messages }
        return messages.filter { $0.date > clearedAt }
    }

    /// La memoria como texto para las instrucciones del modelo, con cuánto
    /// hace de cada mensaje.
    static func context(_ memory: [AssistantMessage], now: Date) -> String {
        memory.suffix(contextLimit).map { message in
            let hours = Int(now.timeIntervalSince(message.date) / 3600)
            let when = hours < 1 ? "hace un rato" : hours == 1 ? "hace 1 h"
                : hours < 48 ? "hace \(hours) h" : "hace \(hours / 24) días"
            let text = message.text.count > contextCharacters
                ? String(message.text.prefix(contextCharacters)) + "…" : message.text
            return (message.role == .user ? "Usuario" : "Asistente") + " (" + when + "): " + text
        }
        .joined(separator: "\n")
    }
}

/// La conversación con el asistente.
@MainActor
final class AssistantChat: ObservableObject {

    /// Lo que se ve: la conversación en curso.
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var isThinking = false

    /// Lo que recuerda: 24 horas hacia atrás, se vea o no.
    private var memory: [AssistantMessage] = []
    /// Desde cuándo se limpió la pantalla.
    private var clearedAt: Date?

    private let defaults: UserDefaults
    /// Otra clave que la del chat del día: el formato cambió (fechas por
    /// mensaje) y el guardado viejo sólo tenía lo de un día.
    private static let storageKey = "assistantChat.v2"
    private var inputs: AssistantInputs?
    private var categories: [String] = []
    #if canImport(FoundationModels)
    private var sessionBox: AnyObject?
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // El guardado de antes (sólo el día, sin fechas por mensaje).
        defaults.removeObject(forKey: "assistantChat")
        restore()
    }

    /// Los datos frescos cada vez que se abre la hoja; la sesión del modelo
    /// se arma de nuevo con ellos.
    func update(inputs: AssistantInputs, categories: [String]) {
        self.inputs = inputs
        self.categories = categories
        #if canImport(FoundationModels)
        sessionBox = nil
        #endif
        restore()
    }

    func suggestions(budgetEnabled: Bool) -> [String] {
        [budgetEnabled ? "¿Cuánto puedo gastar hoy?" : "¿Cuánto gasté esta semana?",
         "¿Qué me cobran esta semana?",
         "¿Quién me debe?"]
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking, let inputs else { return }
        // La hoja pudo quedarse abierta horas: lo viejo se limpia antes de
        // seguir, y el modelo se vuelve a armar con la memoria al día.
        if expire() {
            #if canImport(FoundationModels)
            sessionBox = nil
            #endif
        }
        append(AssistantMessage(role: .user, text: trimmed))
        persist()
        isThinking = true
        defer { isThinking = false; persist() }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), AssistantAI.isAvailable {
            do {
                let reply = try await respond(to: trimmed, inputs: inputs)
                append(reply)
                return
            } catch {
                Diagnostics.shared.log("Asistente: \(error)")
                append(AssistantMessage(role: .assistant,
                                        text: "No pude responder eso ahora. Prueba a preguntarlo de otra forma."))
                return
            }
        }
        #endif
        append(AssistantMessage(role: .assistant,
                                text: "Las preguntas necesitan Apple Intelligence en este iPhone."))
    }

    /// Se eligió otro plazo en la hoja: puede que lo de la vista ya venza.
    func lifetimeChanged() {
        if expire() { persist() }
    }

    private func append(_ message: AssistantMessage) {
        memory.append(message)
        messages.append(message)
    }

    /// Recorta la memoria a 24 h y limpia la vista si venció. Dice si la
    /// vista cambió.
    @discardableResult
    private func expire(now: Date = Date()) -> Bool {
        memory = AssistantChatMemory.pruned(memory, now: now)
        clearedAt = AssistantChatMemory.clearedAt(memory, clearedAt: clearedAt,
                                                  lifetimeHours: AssistantChatMemory.lifetimeHours(defaults),
                                                  now: now)
        let shown = AssistantChatMemory.visible(memory, clearedAt: clearedAt)
        guard shown != messages else { return false }
        messages = shown
        return true
    }

    // MARK: Persistencia

    private struct Stored: Codable {
        let messages: [AssistantMessage]
        let clearedAt: Date?
    }

    private func restore() {
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            memory = stored.messages
            clearedAt = stored.clearedAt
        } else {
            memory = []
            clearedAt = nil
        }
        messages = AssistantChatMemory.visible(memory, clearedAt: clearedAt)
        let stored = (memory.count, clearedAt)
        expire()
        if memory.count != stored.0 || clearedAt != stored.1 { persist() }
    }

    nonisolated static func storedMessages(_ defaults: UserDefaults) -> [AssistantMessage] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.messages
    }

    nonisolated static func eraseStored(_ defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }

    private func persist() {
        let stored = Stored(messages: memory, clearedAt: clearedAt)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.storageKey) }
    }

    // MARK: Modelo

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func session(for inputs: AssistantInputs) -> LanguageModelSession {
        if let existing = sessionBox as? LanguageModelSession { return existing }
        let facts = AssistantFacts(inputs: inputs)
        let tools: [any Tool] = [
            MovementsTool(facts: facts),
            CommittedTool(facts: facts),
            DebtsTool(facts: facts),
            LimitsTool(facts: facts)
        ]
        // Lo hablado en las últimas 24 horas viaja como contexto, aunque ya no
        // se vea: la sesión del modelo no sobrevive a cerrar la app.
        let earlier = AssistantChatMemory.context(Array(memory.dropLast()), now: inputs.now)
        let instructions = """
        Eres el asistente de AgruPay, una app peruana de gastos personales. Respondes preguntas sobre el dinero \
        del usuario en español peruano, tuteando, en una a tres frases cortas.
        Hoy es \(AssistantBrief.headerDate(inputs.now)). Moneda: soles (S/).
        \(AssistantBrief.tidy(facts.overview))
        Usa las herramientas para cualquier cifra que no esté arriba. Nunca inventes montos, fechas ni nombres: \
        si no lo sabes, dilo. Sólo lees datos: no puedes registrar, editar ni borrar movimientos.
        \(earlier.isEmpty ? "" : "Lo que hablaron en las últimas 24 horas:\n" + earlier)
        """
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        sessionBox = session
        return session
    }

    @available(iOS 26.0, *)
    private func respond(to question: String, inputs: AssistantInputs) async throws -> AssistantMessage {
        let session = session(for: inputs)
        let response = try await session.respond(to: question, generating: AssistantReply.self)
        let reply = response.content
        var chips: [AssistantMessage.ActionChip] = []
        if let category = reply.category,
           let match = categories.first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) {
            chips.append(.init(label: "Ver en " + match, action: .category(match)))
        }
        switch reply.destination {
        case .categorias where chips.isEmpty: chips.append(.init(label: "Ver categorías", action: .open(.categories)))
        case .historial: chips.append(.init(label: "Ver movimientos", action: .open(.movements)))
        case .pendientes: chips.append(.init(label: "Ver pendientes", action: .open(.pending)))
        case .amigos: chips.append(.init(label: "Ver amigos", action: .open(.social)))
        case .suscripciones: chips.append(.init(label: "Ver suscripciones", action: .recurring))
        default: break
        }
        return AssistantMessage(role: .assistant, text: reply.answer, actions: chips)
    }
    #endif
}

// MARK: - Hechos para el chat

/// Cortes ya calculados que el chat entrega al modelo. Todas las cifras
/// salen de `Accounting`, igual que en el resto de la app.
struct AssistantFacts {
    let inputs: AssistantInputs

    private var month: Period { Period(granularity: .mes, reference: inputs.now) }

    func totals(_ period: Period) -> PeriodTotals {
        Accounting.totals(expenses: inputs.expenses, incomes: inputs.incomes, period: period, usdToPen: inputs.usdToPen)
    }

    /// Lo que va en las instrucciones: el mes, el anterior y las categorías.
    var overview: String {
        let current = totals(month)
        let previous = totals(month.previous)
        let name = Period.spanishMonthName(for: inputs.now).lowercased()
        let previousName = Period.spanishMonthName(for: month.previous.reference).lowercased()
        var lines = [
            "En \(name) (hasta hoy) llevas \(Money.formatCompact(current.spent)) gastados en \(current.expenseCount) gastos e \(Money.formatCompact(current.income)) de ingresos.",
            "En \(previousName) gastaste \(Money.formatCompact(previous.spent)) en total."
        ]
        let top = current.byCategory.prefix(8).map { "\($0.category) \(Money.formatCompact($0.total))" }
        if !top.isEmpty { lines.append("Categorías de \(name): " + top.joined(separator: ", ") + ".") }
        if let pace = BudgetStore.pace(monthlyBudget: inputs.monthlyBudget, enabled: inputs.budgetEnabled,
                                       for: month, spent: current.spent) {
            lines.append("Presupuesto del mes: \(Money.formatCompact(pace.target)); quedan \(Money.formatCompact(pace.remaining))"
                + (pace.availablePerDay.map { ", \(Money.formatCompact($0)) por día" } ?? "") + ".")
        } else {
            lines.append("No tiene presupuesto mensual.")
        }
        return lines.joined(separator: "\n")
    }

    /// El mes pedido: «setiembre», «agosto 2025», «este mes», «el mes pasado»,
    /// «esta semana», «hoy». Sin nada, el mes en curso.
    func period(named raw: String?) -> Period {
        let text = (raw ?? "").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if text.isEmpty || text.contains("este mes") { return month }
        if text.contains("pasado") || text.contains("anterior") { return month.previous }
        if text.contains("semana") { return Period(granularity: .semana, reference: inputs.now) }
        if text.contains("hoy") { return Period(granularity: .dia, reference: inputs.now) }
        if text.contains("ayer"),
           let yesterday = Period.calendar.date(byAdding: .day, value: -1, to: inputs.now) {
            return Period(granularity: .dia, reference: yesterday)
        }
        var candidate = month
        for _ in 0..<24 {
            let name = Period.spanishMonthName(for: candidate.reference)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            let alias = name == "setiembre" ? "septiembre" : name
            if text.contains(name) || text.contains(alias) {
                let year = Period.calendar.component(.year, from: candidate.reference)
                if let digits = text.range(of: #"\d{4}"#, options: .regularExpression), Int(text[digits]) != year {
                    candidate = candidate.previous
                    continue
                }
                return candidate
            }
            candidate = candidate.previous
        }
        return month
    }

    func movements(period: Period, category: String?, merchant: String?, tag: String?) -> String {
        let fold: (String) -> String = { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let wantedCategory = category.map(fold).flatMap { $0.isEmpty ? nil : $0 }
        let wantedMerchant = merchant.map(fold).flatMap { $0.isEmpty ? nil : $0 }
        let wantedTag = tag.map(fold).flatMap { $0.isEmpty ? nil : $0 }

        let filtered = inputs.expenses.filter { e in
            (wantedCategory.map { fold(e.category) == $0 } ?? true)
                && (wantedMerchant.map { fold(Accounting.displayName(e.merchant)).contains($0) } ?? true)
                && (wantedTag.map { t in e.tags.contains { fold($0) == t } } ?? true)
        }
        let totals = Accounting.totals(expenses: filtered, incomes: [], period: period, usdToPen: inputs.usdToPen)
        guard totals.expenseCount > 0 else { return "No hay gastos que coincidan en \(period.title)." }

        var lines = ["\(period.title): \(Money.format(totals.spent)) en \(totals.expenseCount) gastos."]
        if wantedCategory == nil {
            lines.append("Por categoría: " + totals.byCategory.prefix(6)
                .map { "\($0.category) \(Money.formatCompact($0.total))" }.joined(separator: ", ") + ".")
        }
        lines.append("Comercios principales: " + totals.byMerchant.prefix(5)
            .map { "\(Accounting.displayName($0.merchant)) \(Money.formatCompact($0.total)) (\($0.count))" }
            .joined(separator: ", ") + ".")
        if let busiest = totals.dailySpent.max(by: { $0.total < $1.total }), Money.cents(busiest.total) > 0 {
            lines.append("Día con más gasto: \(AssistantBrief.headerDate(busiest.date)), \(Money.formatCompact(busiest.total)).")
        }
        return lines.joined(separator: "\n")
    }

    var committed: String {
        let cal = Period.calendar
        let today = cal.startOfDay(for: inputs.now)
        let horizon = cal.date(byAdding: .day, value: 31, to: today) ?? today
        let soon = inputs.upcoming.filter { $0.date >= today && $0.date < horizon }.sorted { $0.date < $1.date }
        guard !soon.isEmpty else { return "No hay cobros programados en los próximos 30 días." }
        return soon.prefix(12)
            .map { "\($0.name): \(Money.format($0.amount, currency: $0.currency)), \(AssistantBrief.relativeDay($0.date, now: inputs.now)) (\(AssistantBrief.headerDate($0.date)))" }
            .joined(separator: "\n")
    }

    var debts: String {
        let cal = Period.calendar
        let today = cal.startOfDay(for: inputs.now)
        let open = inputs.debts.filter { Money.cents($0.outstanding) > 0 }.sorted { $0.date < $1.date }
        guard !open.isEmpty else { return "Nadie te debe nada ahora." }
        let total = Money.sum(open.map(\.outstanding))
        return "Te deben \(Money.format(total)) en \(open.count) cobros:\n" + open.prefix(12).map { debt in
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: debt.date), to: today).day ?? 0
            return "«\(debt.name)»: \(Money.format(debt.outstanding)), hace \(days) días"
        }.joined(separator: "\n")
    }

    var limits: String {
        let active = inputs.limits.filter(\.hasLimit)
        guard !active.isEmpty else { return "No hay límites por categoría." }
        return active.map { s in
            let state = s.isOver ? "pasado por \(Money.formatCompact(s.overBy))" : "quedan \(Money.formatCompact(s.remaining))"
            return "\(s.category): límite \(Money.formatCompact(s.limit)), gastado \(Money.formatCompact(s.spent)), \(state)"
        }.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)

// MARK: - Respuesta guiada

@available(iOS 26.0, *)
@Generable
enum AssistantDestination {
    case ninguna, categorias, historial, pendientes, amigos, suscripciones
}

@available(iOS 26.0, *)
@Generable
struct AssistantReply {
    @Guide(description: "La respuesta para el usuario, de una a tres frases cortas, con las cifras tal como vinieron de los datos.")
    var answer: String
    @Guide(description: "La categoría de gasto principal de la que habla la respuesta, si hay una. Vacío si no.")
    var category: String?
    @Guide(description: "La pantalla de la app que ayuda a ver más detalle de la respuesta.")
    var destination: AssistantDestination
}

// MARK: - Herramientas

@available(iOS 26.0, *)
struct MovementsTool: Tool {
    let facts: AssistantFacts
    let name = "consultarGastos"
    let description = "Total, cantidad, categorías y comercios de los gastos de un periodo, opcionalmente filtrados por categoría, comercio o etiqueta."

    @Generable
    struct Arguments {
        @Guide(description: "Periodo: «este mes», «el mes pasado», «esta semana», «hoy», «ayer» o el nombre de un mes, como «julio» o «julio 2025».")
        var periodo: String?
        @Guide(description: "Categoría exacta, por ejemplo Comida. Vacío para todas.")
        var categoria: String?
        @Guide(description: "Parte del nombre del comercio, por ejemplo Rappi. Vacío para todos.")
        var comercio: String?
        @Guide(description: "Etiqueta. Vacío para todas.")
        var etiqueta: String?
    }

    func call(arguments: Arguments) async throws -> String {
        AssistantBrief.tidy(facts.movements(period: facts.period(named: arguments.periodo),
                                            category: arguments.categoria, merchant: arguments.comercio,
                                            tag: arguments.etiqueta))
    }
}

@available(iOS 26.0, *)
struct CommittedTool: Tool {
    let facts: AssistantFacts
    let name = "consultarCobrosProgramados"
    let description = "Suscripciones y gastos recurrentes que se cobrarán en los próximos 30 días, con fecha y monto."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String { AssistantBrief.tidy(facts.committed) }
}

@available(iOS 26.0, *)
struct DebtsTool: Tool {
    let facts: AssistantFacts
    let name = "consultarDeudas"
    let description = "Lo que le deben al usuario: gastos por cobrar con saldo pendiente y hace cuántos días."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String { AssistantBrief.tidy(facts.debts) }
}

@available(iOS 26.0, *)
struct LimitsTool: Tool {
    let facts: AssistantFacts
    let name = "consultarLimites"
    let description = "Los límites de gasto por categoría: cuánto es el límite, cuánto se gastó y cuánto queda."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String { AssistantBrief.tidy(facts.limits) }
}
#endif
