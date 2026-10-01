import SwiftUI
import SwiftData

/// `2b` — Dividir un gasto: el editor de partes.
///
/// Cada parte lleva su monto, su categoría —con el saldo del límite que le
/// quedaría— y sus etiquetas. La barra de arriba es la proporción de cada
/// parte con el color de su categoría. Las partes **siempre** suman el pago
/// al céntimo: al cambiar una, la siguiente (o la anterior, si es la última)
/// absorbe la diferencia. Un reparto que no cuadra cambiaría el total del mes
/// sin que nadie lo note.
struct SplitExpenseSheet: View {

    let parent: Expense

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("period") private var period = Period()

    @Query private var allExpenses: [Expense]
    @StateObject private var budgets = CategoryBudgetStore.shared
    @StateObject private var rates = ExchangeRateService.shared

    @State private var drafts: [Draft] = []
    @State private var openCategory: UUID?
    @State private var taggingPart: UUID?
    @FocusState private var focusedAmount: UUID?

    struct Draft: Identifiable, Equatable {
        let id = UUID()
        var amountText: String
        var category: String
        var tags: [String]
        /// Sube cuando el monto se recorta: rehace el campo, que si no sigue
        /// mostrando lo tecleado (un `TextField` enfocado no redibuja el texto
        /// que se le reescribe).
        var revision = 0

        var cents: Int { Money.cents(Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0) }
    }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var totalCents: Int { Money.cents(parent.amount) }
    private var sumCents: Int { drafts.reduce(0) { $0 + $1.cents } }
    private var restCents: Int { totalCents - sumCents }
    private var isBalanced: Bool { restCents == 0 && drafts.allSatisfy { $0.cents > 0 } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        proportion
                        ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                            partCard(index: index, draft: draft)
                        }
                        actions
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)

                footer
            }
            .background(palette.background)
            .navigationTitle("Dividir gasto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { focusedAmount = nil }
                }
            }
            .sheet(item: Binding(get: { taggingPart.map(TaggingTarget.init) },
                                 set: { taggingPart = $0?.id })) { target in
                TagPickerSheet(selected: drafts.first { $0.id == target.id }?.tags ?? []) { tag in
                    toggleTag(tag, in: target.id)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .onAppear(perform: prepare)
    }

    private struct TaggingTarget: Identifiable { let id: UUID }

    // MARK: - Datos

    /// Por uso, igual que el modal de categoría: la misma posición en los dos.
    private var orderedCategories: [String] {
        CategoryStyle.selectable(history: allExpenses)
    }

    private var suggestedCategory: String? {
        guard let hint = SuggestionEngine.suggest(for: parent.merchant, rules: MerchantRules.all()),
              hint.confidence >= 0.45 else { return nil }
        return hint.category
    }

    /// El historial sin este pago ni sus partes actuales: el saldo de cada
    /// límite se calcula como quedaría **después** de dividir.
    private var baseSnapshots: [ExpenseSnapshot] {
        let keys = Set(TransactionKey.lookupKeys(for: parent))
        return allExpenses
            .filter { $0.id != parent.id && $0.splitOf.map(keys.contains) != true }
            .map(\.accountingSnapshot)
    }

    private func status(for category: String, base: [ExpenseSnapshot]) -> CategoryLimitStatus {
        // Todas las partes de la misma categoría a la vez: dos partes en
        // Comida gastan el mismo límite.
        let mine = drafts.filter { $0.category == category && $0.cents > 0 }.map {
            ExpenseSnapshot(amount: Money.value($0.cents), currency: parent.currency, date: parent.date,
                            category: category, merchant: parent.merchant,
                            fxRateAtCapture: parent.fxRateAtCapture)
        }
        return CategoryLimits.status(category: category,
                                     budget: budgets.budget(for: category),
                                     expenses: base + mine,
                                     on: CategoryLimits.referenceDate(for: period),
                                     usdToPen: rates.usdToPenRate)
    }

    private func color(of category: String) -> Color {
        CategoryStyle.color(for: category, accent: accent.color)
    }

    private func prepare() {
        guard drafts.isEmpty else { return }
        let existing = ExpenseSplit.parts(of: parent, among: allExpenses)
        if existing.count >= 2 {
            drafts = existing.map {
                Draft(amountText: Self.text(Money.cents($0.amount)), category: $0.category, tags: $0.tags)
            }
            return
        }
        // Dos mitades para empezar: la primera con lo que ya sabía el pago.
        let first = parent.category != Accounting.unclassified
            ? parent.category
            : (suggestedCategory ?? orderedCategories.first ?? CategoryStyle.fallback)
        let second = orderedCategories.first { $0 != first } ?? CategoryStyle.fallback
        let half = totalCents / 2
        drafts = [
            Draft(amountText: Self.text(totalCents - half), category: first, tags: parent.tags),
            Draft(amountText: Self.text(half), category: second, tags: [])
        ]
    }

    private static func text(_ cents: Int) -> String {
        String(format: "%.2f", Money.value(cents))
    }

    private func format(_ cents: Int) -> String {
        Money.format(Money.value(cents), currency: parent.currency)
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            MovementIcon(icon: MovementStyle.icon(for: parent),
                         color: MovementStyle.color(for: parent, accent: accent.color, scheme: scheme),
                         size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(Accounting.displayName(parent.merchant))
                    .font(.title3.bold())
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(SplitStyle.subtitle(for: parent))
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(parent.amount, currency: parent.currency))
                .font(.title3.bold())
                .foregroundStyle(palette.label)
        }
    }

    private var proportion: some View {
        VStack(spacing: 8) {
            SplitBar(segments: drafts.map { (Money.value($0.cents), color(of: $0.category), 1) },
                     total: parent.amount,
                     height: 10)
                .animation(.easeInOut(duration: 0.25), value: drafts)

            HStack(alignment: .firstTextBaseline) {
                Text("REPARTIDO " + format(sumCents) + " DE " + format(totalCents))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
    }

    private var statusText: String {
        if restCents == 0 {
            return drafts.contains { $0.cents <= 0 } ? "Hay una parte en cero" : "Cuadra con el pago"
        }
        return restCents > 0 ? "Faltan " + format(restCents) : "Te pasaste " + format(-restCents)
    }

    private var statusColor: Color {
        if restCents == 0 { return drafts.contains { $0.cents <= 0 } ? palette.warning : palette.positive }
        return restCents > 0 ? palette.warning : palette.negative
    }

    // MARK: - Parte

    private func partCard(index: Int, draft: Draft) -> some View {
        let tint = color(of: draft.category)
        let isOpen = openCategory == draft.id
        let limit = status(for: draft.category, base: baseSnapshots)

        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint, in: Circle())
                Text("Parte \(index + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
                Spacer(minLength: 8)
                amountField(for: draft)
                if drafts.count > 2 {
                    Button { remove(draft.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Quitar parte \(index + 1)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            divider

            Button {
                withAnimation(.snappy(duration: 0.22)) { openCategory = isOpen ? nil : draft.id }
            } label: {
                HStack(spacing: 10) {
                    SplitCategoryIcon(category: draft.category, color: tint, size: 28)
                    Text(draft.category)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(limit.shortLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(limit.level.color(palette))
                        .lineLimit(1)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                categoryOptions(for: draft)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            divider

            tagsRow(for: draft)
        }
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private func amountField(for draft: Draft) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Money.symbol(for: parent.currency))
                .font(.system(size: 15))
                .foregroundStyle(palette.secondaryLabel)
            TextField("0.00", text: binding(for: draft.id))
                .keyboardType(.decimalPad)
                .focused($focusedAmount, equals: draft.id)
                .id(draft.revision)
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 84)
                .foregroundStyle(palette.label)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { drafts.first { $0.id == id }?.amountText ?? "" },
            set: { value in setAmount(value, for: id) }
        )
    }

    private func categoryOptions(for draft: Draft) -> some View {
        let suggested = suggestedCategory
        let categories = orderedCategories
        return VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                if index > 0 {
                    Rectangle().fill(palette.separator).frame(height: 0.5)
                }
                Button { pick(category, for: draft.id) } label: {
                    HStack(spacing: 10) {
                        SplitCategoryIcon(category: category, color: color(of: category), size: 24)
                        Text(category)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)
                        if category == suggested {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(accent.color)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(accent.onSurface(scheme))
                            .opacity(category == draft.category ? 1 : 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(category == suggested ? accent.color.opacity(0.06) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(palette.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func tagsRow(for draft: Draft) -> some View {
        TagFlowLayout {
            Image(systemName: "tag")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryLabel)
                .frame(height: 28)

            ForEach(draft.tags, id: \.self) { tag in
                TagChip(name: tag, showsRemove: true) { toggleTag(tag, in: draft.id) }
            }

            if draft.tags.count < TagCatalog.maxPerExpense {
                Button { taggingPart = draft.id } label: {
                    Label("Etiqueta", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .overlay(Capsule().stroke(palette.secondaryLabel.opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    // MARK: - Acciones

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: addPart) {
                Label("Añadir parte", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.secondaryLabel.opacity(0.6),
                                          style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)

            Button(action: equalize) {
                Label("Partes iguales", systemImage: "equal.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(accent.color.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("El pago de " + format(totalCents)
                 + " deja de sumar. Cuentan sus partes, cada una en su categoría.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: save) {
                Text(isBalanced ? "Dividir en \(drafts.count) gastos" : statusText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isBalanced ? .white : palette.secondaryLabel)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(isBalanced ? accent.color : palette.track,
                                in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!isBalanced)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
        }
    }

    private func pick(_ category: String, for id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.22)) {
            drafts[i].category = category
            openCategory = nil
        }
    }

    private func toggleTag(_ tag: String, in id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        let key = TagCatalog.normalized(tag)
        withAnimation(.snappy(duration: 0.2)) {
            if drafts[i].tags.contains(where: { TagCatalog.normalized($0) == key }) {
                drafts[i].tags.removeAll { TagCatalog.normalized($0) == key }
            } else if drafts[i].tags.count < TagCatalog.maxPerExpense {
                drafts[i].tags.append(tag)
            }
        }
    }

    /// Cambia el monto de una parte y compensa con su vecina: la siguiente, o
    /// la anterior si es la última. Sólo esa: las demás no se mueven. Lo que
    /// no cabe se recorta —la vecina no baja de cero—.
    private func setAmount(_ value: String, for id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        let text = value.filter { $0.isNumber || $0 == "." || $0 == "," }
        drafts[i].amountText = text
        guard drafts.count > 1 else { return }

        let partner = i < drafts.count - 1 ? i + 1 : i - 1
        let others = drafts.indices.filter { $0 != i && $0 != partner }.reduce(0) { $0 + drafts[$1].cents }
        let available = max(0, totalCents - others)
        let mine = drafts[i].cents
        drafts[partner].amountText = Self.text(available - min(mine, available))
        if mine > available {
            drafts[i].amountText = Self.text(available)
            drafts[i].revision += 1
            // El campo nuevo nace sin foco: se le devuelve.
            DispatchQueue.main.async { focusedAmount = id }
        }
    }

    /// La parte nueva sale de la mitad de la última: así sigue cuadrando.
    private func addPart() {
        let used = Set(drafts.map(\.category))
        let category = orderedCategories.first { !used.contains($0) } ?? CategoryStyle.fallback
        guard let last = drafts.indices.last else { return }
        let half = drafts[last].cents / 2
        withAnimation(.snappy(duration: 0.22)) {
            drafts[last].amountText = Self.text(drafts[last].cents - half)
            drafts.append(Draft(amountText: Self.text(half), category: category, tags: []))
        }
    }

    /// El céntimo que sobra va a la última parte, para que siempre cuadre.
    private func equalize() {
        let n = drafts.count
        guard n > 0 else { return }
        let base = totalCents / n
        withAnimation(.snappy(duration: 0.22)) {
            for i in drafts.indices {
                drafts[i].amountText = Self.text(i == n - 1 ? totalCents - base * (n - 1) : base)
            }
        }
    }

    /// Lo que tenía la parte quitada vuelve a su vecina.
    private func remove(_ id: UUID) {
        guard let i = drafts.firstIndex(where: { $0.id == id }), drafts.count > 2 else { return }
        let heir = i > 0 ? i - 1 : 1
        withAnimation(.snappy(duration: 0.22)) {
            drafts[heir].amountText = Self.text(drafts[heir].cents + drafts[i].cents)
            drafts.remove(at: i)
            if openCategory == id { openCategory = nil }
        }
    }

    private func save() {
        guard isBalanced else { return }
        let parts = drafts.map { SplitPart(amount: Money.value($0.cents), category: $0.category, tags: $0.tags) }
        if ExpenseSplit.apply(parts, to: parent, in: modelContext) {
            ProHaptics.play(.split)
            dismiss()
        }
    }
}

// MARK: - Piezas compartidas

/// Lo que comparten el editor, la lista y la ficha de una parte.
enum SplitStyle {

    /// «Hoy, 17 sep · 14:20 · Yape».
    static func subtitle(for expense: Expense) -> String {
        let calendar = Period.calendar
        let day = expense.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
            .replacingOccurrences(of: ".", with: "")
        let prefix = calendar.isDateInToday(expense.date) ? "Hoy, "
            : calendar.isDateInYesterday(expense.date) ? "Ayer, " : ""
        var parts = [prefix + day, expense.date.formatted(.dateTime.hour().minute())]
        if let source = MovementStyle.source(for: expense) { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// «Yape», «Plin», «BBVA» si el pago salió por uno; `nil` con tarjeta.
    static func channelName(for expense: Expense) -> String? {
        guard channelLogo(for: expense) != nil else { return nil }
        return MovementStyle.source(for: expense)
    }

    /// El logo del canal (Yape, Plin, BBVA) que se pega a cada parte, o `nil`
    /// si el pago no salió por uno.
    static func channelLogo(for expense: Expense) -> String? {
        let icon = MovementStyle.icon(for: expense)
        return ["plin_icon", "yape_icon", "bbva_icon"].contains(icon) ? icon : nil
    }
}

/// El cuadrado de categoría en pequeño, sin la lógica de canales de
/// `MovementIcon`.
struct SplitCategoryIcon: View {
    let category: String
    let color: Color
    var size: CGFloat = 28

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(color.opacity(scheme == .dark ? 0.22 : 0.18))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: CategoryStyle.icon(for: category))
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(color)
            )
    }
}

/// La barra de proporción: un tramo por parte, con el color de su categoría.
struct SplitBar: View {
    /// Monto, color y opacidad de cada tramo.
    let segments: [(amount: Double, color: Color, opacity: Double)]
    let total: Double
    var height: CGFloat = 10

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let gaps = CGFloat(max(0, segments.count - 1)) * 3
            let usable = max(0, geo.size.width - gaps)
            HStack(spacing: 3) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.color.opacity(segment.opacity))
                        .frame(width: usable * CGFloat(fraction(segment.amount)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Palette(scheme).track)
        .clipShape(Capsule())
    }

    /// Pasado del pago, la barra se reparte sobre la suma: si no, la primera
    /// parte la llenaba entera y las demás desaparecían.
    private func fraction(_ amount: Double) -> Double {
        let base = max(total, segments.reduce(0) { $0 + max($1.amount, 0) })
        guard base > 0 else { return 0 }
        return min(max(amount / base, 0), 1)
    }
}
