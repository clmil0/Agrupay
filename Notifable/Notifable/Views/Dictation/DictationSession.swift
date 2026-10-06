import Foundation
import SwiftData
import SwiftUI

/// Una tarjeta del dictado: lo entendido y en qué punto está.
struct DictationCard: Identifiable, Equatable {
    enum Status: Equatable {
        /// Contando los segundos antes de registrarse; se puede cancelar o editar.
        case pending
        /// Pausado: nada se registra hasta que se guarde.
        case editing
        case saved
        case cancelled
    }

    let id = UUID()
    var movement: VoiceMovement
    var status: Status = .pending
    /// Cambia en cada cuenta atrás: una vieja que termina tarde no registra.
    var countdown = UUID()
}

/// La lógica del dictado, aparte de su hoja: frases → movimientos → tarjetas
/// → registros.
@MainActor
final class DictationSession: ObservableObject {

    /// Lo que falta del movimiento que quedó a medias.
    enum Question: Equatable {
        case amount
        case title

        var text: String {
            switch self {
            case .amount: return "¿De cuánto?"
            case .title:  return "¿En qué?"
            }
        }
    }

    @Published private(set) var cards: [DictationCard] = []
    @Published private(set) var question: Question?
    /// La última frase ya entendida, para que no desaparezca de golpe.
    @Published private(set) var lastPhrase = ""
    @Published private(set) var isThinking = false
    /// Lo dicho hasta ahora sin monto: el relato de quien da vueltas antes de
    /// llegar al gasto. Se interpreta junto con la frase que traiga el monto.
    @Published private(set) var story = ""

    let speech = SpeechDictation()

    static let countdownSeconds = 5
    static let countdown: Duration = .seconds(countdownSeconds)

    private var context: ModelContext?
    /// Tarjetas cuya categoría cambió el usuario: ya no es la de la voz.
    private var editedCategories: Set<DictationCard.ID> = []
    private var incomplete: VoiceMovement?
    private var queue: Task<Void, Never>?
    /// Si tras el relato no llega ningún monto, se interpreta igual (y se
    /// pregunta «¿De cuánto?»).
    private var patience: Task<Void, Never>?
    static let contextPatience: Duration = .milliseconds(3_500)
    static let whatPatience: Duration = .milliseconds(2_000)

    /// Un solo movimiento, con monto y sin nada que diga en qué.
    private static func lacksWhat(_ text: String) -> Bool {
        let parsed = VoiceMovementParser.parse(text)
        return parsed.count == 1 && parsed[0].amount != nil && parsed[0].title == nil
    }
    private(set) var categories: [String] = CategoryStyle.defaults

    var savedCount: Int { cards.filter { $0.status == .saved }.count }

    init() {
        speech.onPhrase = { [weak self] text in self?.enqueue(text) }
    }

    func start(context: ModelContext) async {
        self.context = context
        categories = Self.availableCategories(context: context)
        await speech.start()
    }

    /// Lo que estaba contando se registra —nadie lo canceló—; lo que estaba
    /// en edición se descarta, porque no se guardó.
    func finish() {
        speech.stop(flush: false)
        queue?.cancel()
        patience?.cancel()
        for card in cards where card.status == .pending { commit(card.id, token: card.countdown) }
        for index in cards.indices where cards[index].status == .editing {
            cards[index].status = .cancelled
        }
    }

    /// «Listo». Si hay algo dicho que todavía no se entendió, eso marca el
    /// final del movimiento: se interpreta ya, su tarjeta aparece y se sigue
    /// escuchando. Si no queda nada por entender, devuelve `true` y la hoja se
    /// cierra (lo que estaba contando se registra en `finish`).
    func done() -> Bool {
        if isThinking { return false }
        let spoken = speech.takePhrase()
        let pending = [story, spoken ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        guard !pending.isEmpty else { return true }
        patience?.cancel()
        story = ""
        process(pending)
        return false
    }

    // MARK: - Frases

    private func enqueue(_ text: String) {
        patience?.cancel()
        let combined = story.isEmpty ? text : story + " " + text

        // Sin monto todavía y sin pregunta abierta: es contexto, no un gasto.
        // Se guarda y se espera a que la persona llegue al número.
        //
        // Con monto pero sin el qué («he gastado 500 soles» … «en comida»)
        // también se espera un momento: la pausa suele ser a media frase, y
        // preguntar «¿En qué?» ahí partía el gasto en dos y lo dejaba sin
        // categoría.
        let noAmount = VoiceMovementParser.allAmounts(in: combined).isEmpty
        if question == nil, noAmount || Self.lacksWhat(combined) {
            story = combined
            lastPhrase = combined
            let wait = noAmount ? Self.contextPatience : Self.whatPatience
            patience = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self, !self.story.isEmpty else { return }
                let told = self.story
                self.story = ""
                self.process(told)
            }
            return
        }

        story = ""
        process(combined)
    }

    /// Frases en cola o interpretándose. Mientras haya alguna, «Listo» no
    /// cierra: se perdería el movimiento que está por aparecer.
    private var inFlight = 0 {
        didSet { isThinking = inFlight > 0 }
    }

    private func process(_ text: String) {
        inFlight += 1
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await self?.handle(text)
            self?.inFlight -= 1
        }
    }

    private func handle(_ text: String) async {
        lastPhrase = text

        // Primero, ¿contesta la pregunta pendiente? Sólo si la frase no es un
        // movimiento propio: «Gasté 24 en el almuerzo» después de «¿De
        // cuánto?» es un gasto nuevo, no el monto del anterior.
        let isOwnMovement = VoiceMovementParser.parse(text) { _, _ in nil }
            .contains { $0.amount != nil && $0.title != nil }
        if !isOwnMovement, var pending = incomplete, let question {
            switch question {
            case .amount:
                pending.amount = VoiceMovementParser.amount(in: text)
            case .title:
                if let title = VoiceMovementParser.title(in: text) {
                    pending.title = title
                    if pending.kind == .gasto {
                        pending.category = VoiceMovementParser.defaultCategory(title: title, whole: text)
                            ?? Accounting.unclassified
                    }
                }
            }
            if pending.isComplete {
                clearQuestion()
                add(pending)
                return
            }
        }

        let movements = await VoiceMovementAI.parse(text, categories: categories)
        guard !movements.isEmpty else { return }

        // Algo nuevo reemplaza a la pregunta que no se contestó.
        clearQuestion()
        for var movement in movements {
            if movement.title == nil, movement.kind == .ingreso { movement.title = "Ingreso" }

            if movement.isComplete {
                add(movement)
            } else if question == nil {
                // Una pregunta a la vez; primero el monto.
                withAnimation(.easeInOut(duration: 0.2)) {
                    incomplete = movement
                    question = movement.amount == nil ? .amount : .title
                }
            }
        }
    }

    private func clearQuestion() {
        withAnimation(.easeInOut(duration: 0.2)) {
            incomplete = nil
            question = nil
        }
    }

    private func add(_ movement: VoiceMovement) {
        let card = DictationCard(movement: movement)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            cards.insert(card, at: 0)
        }
        startCountdown(card.id)
    }

    // MARK: - Tarjetas

    private func startCountdown(_ id: DictationCard.ID) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let token = UUID()
        cards[index].countdown = token
        cards[index].status = .pending
        Task { [weak self] in
            try? await Task.sleep(for: Self.countdown)
            self?.commit(id, token: token)
        }
    }

    func cancel(_ id: DictationCard.ID) {
        update(id) { $0.status = .cancelled }
    }

    func edit(_ id: DictationCard.ID) {
        update(id) { $0.status = .editing }
    }

    /// Guardar tras editar vuelve a contar: se ve el cambio antes de que quede.
    func saveEdit(_ id: DictationCard.ID, amount: Double, category: String) {
        if let card = cards.first(where: { $0.id == id }), card.movement.category != category {
            editedCategories.insert(id)
        }
        update(id) {
            $0.movement.amount = amount
            if $0.movement.kind == .gasto { $0.movement.category = category }
        }
        startCountdown(id)
    }

    private func update(_ id: DictationCard.ID, _ change: (inout DictationCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { change(&cards[index]) }
    }

    private func commit(_ id: DictationCard.ID, token: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == id }),
              cards[index].status == .pending,
              cards[index].countdown == token,
              let context else { return }

        let movement = cards[index].movement
        guard let amount = movement.amount, Money.cents(amount) > 0 else {
            update(id) { $0.status = .cancelled }
            return
        }
        let title = movement.title ?? (movement.kind == .gasto ? "Gasto" : "Ingreso")

        switch movement.kind {
        case .gasto:
            let expense = Expense(amount: amount,
                                  merchant: title,
                                  date: movement.date,
                                  category: movement.category,
                                  currency: movement.currency)
            context.insert(expense)
            // La categoría la puso la voz si el usuario no la cambió en la
            // tarjeta: si luego la corrige, es una corrección de la voz.
            let source: String
            if movement.category == Accounting.unclassified {
                source = "none"
            } else if editedCategories.contains(id) {
                source = "user"
            } else {
                source = "voice"
                ClassificationLedger.record(expense.id, engine: .voice)
            }
            Analytics.track(.movementCreated, ["source": "voice", "kind": "expense",
                                               "category_source": source,
                                               "category": Analytics.categoryLabel(movement.category)])
        case .ingreso:
            context.insert(Income(amount: amount,
                                  currency: movement.currency,
                                  source: movement.source ?? "Transferencia",
                                  title: title,
                                  date: movement.date))
            Analytics.track(.movementCreated, ["source": "voice", "kind": "income"])
        }
        try? context.save()
        Analytics.milestone(.firstMovement)
        update(id) { $0.status = .saved }
    }

    // MARK: - Categorías

    /// Las de fábrica, las creadas y las que ya se usaron: lo mismo que se
    /// puede elegir al editar, y la lista cerrada que se le da al modelo.
    private static func availableCategories(context: ModelContext) -> [String] {
        var descriptor = FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 400
        let used = ((try? context.fetch(descriptor)) ?? []).map(\.category)

        var seen = Set<String>()
        return (CategoryStyle.defaults + CategoryCatalog.shared.names.sorted() + used)
            .filter { $0 != Accounting.unclassified && !$0.isEmpty && seen.insert($0).inserted }
    }
}
