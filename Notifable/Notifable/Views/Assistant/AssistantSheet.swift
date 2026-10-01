import SwiftUI
import SwiftData

// MARK: - Datos

/// Arma `AssistantInputs` desde la base: los cuatro últimos meses de
/// movimientos, los cobros programados que vienen, lo que te deben y los
/// límites de categoría.
enum AssistantData {

    @MainActor
    static func inputs(context: ModelContext, usdToPen: Double, now: Date = Date()) -> AssistantInputs {
        var start = Period(granularity: .mes, reference: now)
        for _ in 0..<3 { start = start.previous }
        let from = start.interval.start

        let expenses = (try? context.fetch(FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= from }))) ?? []
        let incomes = (try? context.fetch(FetchDescriptor<Income>(
            predicate: #Predicate { $0.date >= from }))) ?? []
        let snapshots = expenses.map(\.accountingSnapshot)

        let debts = ((try? context.fetch(FetchDescriptor<Expense>(
            predicate: #Predicate { $0.isDebt && !$0.isTransfer }))) ?? [])
            .map { OpenDebt(id: $0.id, name: Accounting.displayName($0.merchant),
                            outstanding: Accounting.outstanding(of: $0), date: $0.date) }
            .filter { Money.cents($0.outstanding) > 0 }

        let rules = ((try? context.fetch(FetchDescriptor<RecurringExpense>())) ?? [])
            .filter { !$0.isPaused && $0.frequency != .never }
        let today = Period.calendar.startOfDay(for: now)
        let horizon = Period.calendar.date(byAdding: .day, value: 31, to: today) ?? today
        let upcoming = rules.flatMap { rule in
            rule.occurrences(in: DateInterval(start: today, end: horizon))
                .filter { date in rule.lastResolvedOccurrence.map { $0 < date } ?? true }
                .map { UpcomingCharge(id: rule.id, name: Accounting.displayName(rule.merchant),
                                      amount: rule.amount, currency: rule.currency, date: $0) }
        }

        // Los límites miran su propio ciclo, que puede ir más atrás que los
        // cuatro meses de arriba (un ciclo anual).
        let budgets = CategoryBudgetStore.shared.budgets.values
            .filter { $0.hasLimit && $0.category != Accounting.unclassified }
        let limitHistory = budgets.isEmpty ? []
            : ((try? context.fetch(FetchDescriptor<Expense>())) ?? []).map(\.accountingSnapshot)
        let limits = budgets.map {
            CategoryLimits.status(category: $0.category, budget: $0, expenses: limitHistory, on: now, usdToPen: usdToPen)
        }

        let defaults = UserDefaults.standard
        return AssistantInputs(now: now,
                               expenses: snapshots,
                               incomes: incomes.map(\.accountingSnapshot),
                               usdToPen: usdToPen,
                               monthlyBudget: defaults.double(forKey: BudgetStore.monthlyBudgetKey),
                               budgetEnabled: defaults.bool(forKey: BudgetStore.enabledKey),
                               limits: limits,
                               upcoming: upcoming,
                               debts: debts)
    }

    @MainActor
    static func categories(context: ModelContext) -> [String] {
        let history = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        return CategoryStyle.selectable(history: history)
    }
}

// MARK: - Botón del header

/// Si el ✦ lleva punto. Aparte del dashboard: cambiarlo no debe volver a
/// evaluar su cuerpo, que calcula los totales del mes.
@Observable
final class AssistantDot {
    static let shared = AssistantDot()
    var hasNews = false
}

/// ✦ en el header del dashboard, con punto cuando hay un resumen sin abrir.
struct AssistantHeaderButton: View {
    let action: () -> Void

    private var hasNews: Bool { AssistantDot.shared.hasNews }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    @AppStorage(ProStore.enabledKey) private var isPro = false
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    /// Pro en el tema básico: el ✦ y su aro en el degradado del acento.
    private var proTouches: Bool { ProTouches.isActive(isPro: isPro, theme: proTheme) }

    private var iconStyle: AnyShapeStyle {
        guard proTouches else { return AnyShapeStyle(accent.onSurface(scheme)) }
        return AnyShapeStyle(LinearGradient(colors: ProTouches.accentGradient(accent, scheme),
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var ringStyle: AnyShapeStyle {
        guard proTouches else { return AnyShapeStyle(palette.hairline) }
        return AnyShapeStyle(LinearGradient(colors: ProTouches.accentGradient(accent, scheme).map { $0.opacity(0.55) },
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(iconStyle)
                .frame(width: ShellMetrics.circleButton, height: ShellMetrics.circleButton)
                .background(palette.surface, in: Circle())
                .overlay(Circle().stroke(ringStyle, lineWidth: proTouches ? 1 : 0.5))
                .overlay(alignment: .topTrailing) {
                    if hasNews {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(palette.background, lineWidth: 2))
                            .offset(x: -6, y: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tu resumen")
        .accessibilityValue(hasNews ? "Hay novedades" : "")
    }
}

// MARK: - Hoja «Tu resumen»

/// `1f`: las tarjetas del día y, debajo, la conversación con el asistente.
/// Los botones cierran la hoja y llevan a la pantalla real (`onAction`).
struct AssistantSheet: View {
    let cards: [BriefCard]
    let inputs: AssistantInputs
    let categories: [String]
    let onAction: (AssistantAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var chat = AssistantChat()
    @StateObject private var speech = SpeechDictation()
    @State private var polished: [BriefCard]?
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    /// Horas sin escribir tras las que se limpia el chat a la vista.
    @AppStorage(AssistantChatMemory.lifetimeKey) private var lifetime = AssistantChatMemory.defaultLifetime

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var canChat: Bool { AssistantAI.isAvailable }
    private var isListening: Bool { speech.phase == .listening || speech.phase == .starting }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(polished ?? cards) { card in
                            cardView(card)
                        }

                        if canChat {
                            conversation
                                .padding(.top, 8)
                        } else {
                            Text("Para hacerle preguntas al asistente necesitas Apple Intelligence en este iPhone.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(palette.secondaryLabel)
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: chat.isThinking) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            if canChat { inputBar }
        }
        .background(palette.background.ignoresSafeArea())
        .presentationDetents([.fraction(0.88), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .task {
            chat.update(inputs: inputs, categories: categories)
            let result = await AssistantAI.polish(cards)
            withAnimation(.easeInOut(duration: 0.25)) { polished = result }
        }
        .onDisappear { speech.stop(flush: false) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Tu resumen")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(palette.label)
                Text(AssistantBrief.headerDate(inputs.now))
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer()
            if canChat {
                lifetimeMenu
                    .padding(.top, 6)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 30, height: 30)
                    .background(palette.track, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
            .padding(.top, 6)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// Cuándo se borra el chat a la vista. El asistente recuerda 24 h igual.
    private var lifetimeMenu: some View {
        Menu {
            Picker("Borrar el chat tras", selection: $lifetime) {
                ForEach(AssistantChatMemory.lifetimeOptions, id: \.self) { hours in
                    Text(hours == 1 ? "1 hora sin escribir" : "\(hours) horas sin escribir").tag(hours)
                }
            }
            .pickerStyle(.inline)
            Text("Aunque se borre, el asistente recuerda lo hablado en las últimas 24 horas.")
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: 30, height: 30)
                .background(palette.track, in: Circle())
        }
        .accessibilityLabel("Borrar el chat tras \(lifetime) h sin escribir")
        .onChange(of: lifetime) { _, _ in chat.lifetimeChanged() }
    }

    private func cardView(_ card: BriefCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: card.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                Text(card.title)
                    .font(.system(size: 11.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Text(card.text)
                .font(.system(size: 15))
                .foregroundStyle(palette.label)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
            if let cta = card.cta, let action = card.action {
                chip(cta) { perform(action) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent.onSurface(scheme))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(accent.softFill(scheme), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: AssistantAction) {
        onAction(action)
        dismiss()
    }

    // MARK: Conversación

    @ViewBuilder
    private var conversation: some View {
        ForEach(chat.messages) { message in
            switch message.role {
            case .user:
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(accent.color, in: UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18,
                        style: .continuous))
                    .frame(maxWidth: 300, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if !message.actions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(message.actions, id: \.self) { chip in
                                self.chip(chip.label) { perform(chip.action) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(palette.surface, in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous))
                .overlay(UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18,
                    style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if chat.isThinking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Pensando…")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 4)
        }

        if chat.messages.isEmpty {
            FlowRow(spacing: 6) {
                ForEach(chat.suggestions(budgetEnabled: inputs.budgetEnabled), id: \.self) { suggestion in
                    Button { send(suggestion) } label: {
                        Text(suggestion)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.label)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .overlay(Capsule().stroke(palette.label.opacity(0.14), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Pregunta algo sobre tu dinero", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .foregroundStyle(palette.label)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))

            Button(action: primaryAction) {
                ZStack {
                    Circle().fill(accent.color)
                    if isListening {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            .scaleEffect(1 + min(0.25, speech.level * 0.4))
                            .padding(4)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: draft.trimmingCharacters(in: .whitespaces).isEmpty ? "mic.fill" : "arrow.up")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(chat.isThinking)
            .accessibilityLabel(isListening ? "Terminar de dictar" : (draft.isEmpty ? "Dictar pregunta" : "Enviar"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Rectangle().fill(palette.separator).frame(height: 0.5) }
        .onChange(of: speech.partial) { _, text in
            if isListening, !text.isEmpty { draft = text }
        }
    }

    /// Micrófono con el campo vacío, enviar con texto. Dictando, el botón
    /// cierra la frase y la manda.
    private func primaryAction() {
        if isListening {
            let spoken = speech.takePhrase() ?? draft
            speech.stop(flush: false)
            send(spoken)
        } else if draft.trimmingCharacters(in: .whitespaces).isEmpty {
            fieldFocused = false
            speech.onPhrase = { phrase in
                speech.stop(flush: false)
                send(phrase)
            }
            Task { await speech.start() }
        } else {
            send(draft)
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        Task { await chat.ask(question) }
    }
}

// MARK: - Fila que se parte

/// Chips que pasan a la línea siguiente cuando no caben.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
