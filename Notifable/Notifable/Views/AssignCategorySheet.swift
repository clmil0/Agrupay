import SwiftUI

/// Contexto del movimiento que se está clasificando.
///
/// Un solo componente sirve a los tres puntos de entrada —detalle del gasto,
/// Bandeja y modal de alta—; lo único que cambia entre ellos es esta cabecera.
/// Si el sheet acabara duplicado, la sugerencia y el saldo del límite se
/// desincronizarían entre puntos de entrada, que es justo el problema que
/// venimos a resolver.
struct AssignCategoryContext: Equatable, Identifiable {

    var id: String { (merchant ?? "") + "|" + title }

    /// `nil` en el modal de alta cuando aún no se escribió el comercio: sin
    /// comercio no hay regla que crear.
    var merchant: String?
    var title: String
    var subtitle: String
    var amount: Double?
    var currency: String = "PEN"
    /// Categoría actual, para preseleccionarla.
    var current: String?
    /// Qué ofrece el interruptor del pie. Ver `RuleScope`.
    var ruleScope: RuleScope = .forward

    /// Desde un movimiento suelto (Actividad reciente, detalle, alta) el
    /// interruptor sólo decide lo que llegue: tocar el historial desde una fila
    /// suelta sería una sorpresa. Desde Pendientes el usuario ya está
    /// ordenando el comercio entero, así que ahí se ofrece arrastrar el pasado.
    enum RuleScope: Equatable {
        /// "No volver a preguntar": regla para lo que llegue, apagado por defecto.
        case forward
        /// "Asignar también los anteriores": apagado por defecto; reclasificar
        /// el historial es algo que se pide, no que se descubre después.
        case past
        /// Desde Pendientes: los dos a la vez y los dos apagados — «también
        /// los anteriores» (lo pendiente de esos comercios, más antiguo que lo
        /// elegido) y «también los que lleguen» (la regla). Vale para uno o
        /// varios comercios.
        case pending(merchants: [String], selected: Int, earlier: Int)
    }

    static func expense(_ expense: Expense) -> AssignCategoryContext {
        AssignCategoryContext(
            merchant: expense.merchant,
            title: Accounting.displayName(expense.merchant),
            subtitle: expense.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "es_ES"))),
            amount: expense.amount,
            currency: expense.currency,
            current: expense.category == Accounting.unclassified ? nil : expense.category
        )
    }

    /// Desde la Bandeja: el "movimiento" es el grupo entero del comercio.
    static func merchant(_ merchant: String, movements: Int, total: Double) -> AssignCategoryContext {
        let count = movements == 1 ? "1 movimiento" : "\(movements) movimientos"
        return AssignCategoryContext(
            merchant: merchant,
            title: Accounting.displayName(merchant),
            subtitle: count + " · " + Money.format(total),
            amount: nil,
            ruleScope: .past
        )
    }

    /// Desde el modal de alta: todavía no existe el gasto.
    static func draft(merchant: String, amount: Double, currency: String, current: String?) -> AssignCategoryContext {
        let clean = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        return AssignCategoryContext(
            merchant: clean.isEmpty ? nil : clean,
            title: clean.isEmpty ? "Nuevo gasto" : Accounting.displayName(clean),
            subtitle: "Sin guardar todavía",
            amount: Money.cents(amount) > 0 ? amount : nil,
            currency: currency,
            current: (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : current
        )
    }

    /// Desde la selección múltiple de Pendientes ("bolita").
    static func selection(title: String, amount: Double) -> AssignCategoryContext {
        AssignCategoryContext(
            merchant: nil,
            title: title,
            subtitle: Money.format(amount) + " en total",
            amount: amount > 0 ? amount : nil,
            currency: "PEN",
            current: nil
        )
    }
}

/// Lo que el usuario pidió además de clasificar lo elegido.
struct AssignCategoryRules: Equatable {
    /// Reclasificar también los anteriores del comercio.
    var past = false
    /// Crear la regla: lo que llegue irá directo a la categoría.
    var future = false
}

/// `1a` — Asignar categoría: una sola columna, elegir y confirmar con el botón.
///
/// Sin tarjeta de sugerencia y sin buscador. Las categorías van por uso, de
/// más a menos; la sugerida se queda **en su lugar** dentro de la lista,
/// resaltada con el acento y el rayo, y llega ya marcada. Cada fila lleva el
/// saldo de su límite —asignar es el único momento en que ese dato cambia
/// algo— y «Nueva categoría» cierra la lista. Al pie, la regla opcional para
/// que el comercio no vuelva a preguntar.
struct AssignCategorySheet: View {

    let context: AssignCategoryContext
    let history: [Expense]
    private let onAssign: (String, AssignCategoryRules) -> Void
    /// Dejar el movimiento sin categoría. Sólo se ofrece si ya tiene una y
    /// quien llama sabe qué hacer con eso (detalle del gasto, alta).
    private var onClear: (() -> Void)?

    /// Se llama con la categoría elegida y el estado del interruptor, cuyo
    /// significado depende de `context.ruleScope`: en `.forward`, crear la
    /// regla sólo para lo que llegue; en `.past`, reclasificar también el
    /// historial del comercio.
    init(context: AssignCategoryContext, history: [Expense],
         onClear: (() -> Void)? = nil,
         onAssign: @escaping (String, Bool) -> Void) {
        self.context = context
        self.history = history
        self.onClear = onClear
        self.onAssign = { category, rules in onAssign(category, rules.past || rules.future) }
    }

    /// Para `.pending`: los dos interruptores por separado.
    init(context: AssignCategoryContext, history: [Expense], onAssignRules: @escaping (String, AssignCategoryRules) -> Void) {
        self.context = context
        self.history = history
        self.onAssign = onAssignRules
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage("period") private var period = Period()

    @StateObject private var budgets = CategoryBudgetStore.shared
    @StateObject private var catalog = CategoryCatalog.shared
    @StateObject private var rates = ExchangeRateService.shared

    @State private var selected: String?
    @State private var ruleEnabled = false
    /// Sólo en `.pending`: los dos interruptores del pie.
    @State private var rules = AssignCategoryRules()
    @State private var creating: String?
    /// Modo edición: cada categoría propia lleva su papelera y tocarla abre
    /// su ficha en vez de elegirla.
    @State private var isEditing = false
    @State private var editingCategory: String?
    @State private var deleting: String?
    @State private var isDeleting = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        trackedBody.trackScreen("assign_category")
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        listSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }

                footer
            }
            .background(palette.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isEditing ? "Listo" : "Editar") {
                        withAnimation(.easeInOut(duration: 0.2)) { isEditing.toggle() }
                    }
                    .fontWeight(isEditing ? .semibold : .regular)
                }
            }
            .alert(deleting.map { "¿Eliminar \($0)?" } ?? "",
                   isPresented: Binding(get: { deleting != nil },
                                        set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { name in
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) { delete(name) }
            } message: { name in
                Text(CategoryDeletion.message(for: name, in: history))
            }
            .overlay {
                if isDeleting {
                    ProgressView().controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .navigationDestination(item: $editingCategory) { name in
                CategorySettingsView(category: name, history: history) { finalName in
                    if selected == name { selected = finalName }
                }
            }
            .navigationDestination(item: $creating) { name in
                CategorySettingsView(category: name,
                                     isNew: true,
                                     history: history) { finalName in
                    selected = finalName
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .onAppear(perform: prepare)
    }

    // MARK: - Estado

    private var referenceDate: Date { CategoryLimits.referenceDate(for: period) }

    private var snapshots: [ExpenseSnapshot] { history.map(\.accountingSnapshot) }

    /// La sugerencia del motor, sólo si es lo bastante segura para marcarla.
    private var suggestion: CategorySuggestion? {
        guard let merchant = context.merchant,
              let hint = SuggestionEngine.suggest(for: merchant, rules: MerchantRules.all()),
              hint.confidence >= 0.45 else { return nil }
        return hint
    }

    /// Movimientos pasados del mismo comercio: lo que la regla reclasificaría.
    private var pastCount: Int {
        guard let merchant = context.merchant else { return 0 }
        return history.reduce(0) { $0 + ($1.merchant == merchant ? 1 : 0) }
    }

    /// Por uso, de más a menos (empates alfabéticos). **No** se ordena por
    /// saldo ni sube la sugerida: la posición tiene que ser la misma entre
    /// aperturas o la memoria muscular no se forma.
    private var orderedCategories: [String] {
        CategoryStyle.selectable(history: history)
    }

    private func status(for category: String) -> CategoryLimitStatus {
        CategoryLimits.status(category: category,
                              budget: budgets.budget(for: category),
                              expenses: snapshots,
                              on: referenceDate,
                              usdToPen: rates.usdToPenRate)
    }

    private func prepare() {
        // Sin categoría, la sugerida llega marcada: aceptarla es un toque.
        selected = context.current ?? suggestion?.category
        ruleEnabled = false
        rules = AssignCategoryRules()
    }

    // MARK: - Cabecera

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(palette.track)
                .frame(width: 44, height: 44)
                .overlay(headerIcon)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.title)
                    .font(.title3.bold())
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(context.subtitle)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let amount = context.amount {
                Text(Money.format(amount, currency: context.currency))
                    .font(.title3.bold())
                    .foregroundStyle(palette.label)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var headerIcon: some View {
        let merchant = context.merchant ?? ""
        if merchant.hasPrefix("PLIN - ") {
            channelLogo("plin_icon")
        } else if merchant.hasPrefix("YAPE - ") {
            channelLogo("yape_icon")
        } else {
            Image(systemName: "bag.fill")
                .foregroundStyle(palette.secondaryLabel)
        }
    }

    private func channelLogo(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFill()
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Lista

    private var listSection: some View {
        let suggested = suggestion
        let categories = orderedCategories
        return VStack(alignment: .leading, spacing: 9) {
            Text(listTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    if index > 0 { rowSeparator }
                    categoryRow(category, suggested: suggested)
                }

                // Sin categorías (se pueden eliminar todas) sólo queda crear.
                if !categories.isEmpty { rowSeparator }
                newCategoryRow
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )

            Text(isEditing ? "Toca una categoría para cambiarle nombre, color o ícono, o la papelera para eliminarla."
                           : "Mantén presionada una categoría para editarla o eliminarla.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 4)
        }
    }

    private func categoryRow(_ category: String, suggested: CategorySuggestion?) -> some View {
        let deletable = !CategoryCatalog.isSystem(category)
        return HStack(spacing: 0) {
            Button {
                if isEditing { editingCategory = category } else { select(category) }
            } label: {
                CategoryLimitRow(category: category,
                                 status: status(for: category),
                                 color: color(of: category),
                                 isSelected: selected == category,
                                 suggestionReason: category == suggested?.category ? suggested?.reason : nil,
                                 accent: accent.color,
                                 showsRadio: !isEditing)
            }
            .buttonStyle(.plain)

            if isEditing {
                Button {
                    deleting = category
                } label: {
                    Image(systemName: deletable ? "trash" : "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(deletable ? palette.negative : palette.tertiaryLabel)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!deletable)
                .padding(.trailing, 6)
                .accessibilityLabel(deletable ? "Eliminar " + category : category + " no se puede eliminar")
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contextMenu {
            Button {
                editingCategory = category
            } label: { Label("Editar", systemImage: "pencil") }
            if deletable {
                Button(role: .destructive) {
                    deleting = category
                } label: { Label("Eliminar", systemImage: "trash") }
            }
        }
    }

    private func delete(_ category: String) {
        if selected == category { selected = nil }
        isDeleting = true
        Task {
            await CategoryEditor.delete(category, in: history)
            try? modelContext.save()
            isDeleting = false
        }
    }

    private var listTitle: String {
        "MÁS USADAS PRIMERO · LÍMITE DE " + monthName.uppercased()
    }

    private var monthName: String {
        Period.spanishMonthName(for: referenceDate)
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 0.5)
    }

    private var newCategoryRow: some View {
        Button { creating = "" } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.secondaryLabel.opacity(0.5), lineWidth: 0.5)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.label)
                    )
                Text("Nueva categoría")
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func color(of category: String) -> Color {
        CategoryStyle.color(for: category, accent: accent.color)
    }

    // MARK: - Pie

    private var footer: some View {
        VStack(spacing: 11) {
            if case let .pending(merchants, count, earlier) = context.ruleScope {
                pendingRules(merchants: merchants, selected: count, earlier: earlier)
            } else if showsRuleToggle {
                ruleToggle
            }
            primaryButton
            if context.current != nil, let onClear {
                Button {
                    onClear()
                    dismiss()
                } label: {
                    Text("Quitar categoría")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.negative)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(palette.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.5)
        }
    }

    /// Sin comercio no hay regla. En `.forward` basta el comercio —la regla
    /// vale aunque sea el primer movimiento—; en `.past` además tiene que
    /// haber historial que arrastrar.
    private var showsRuleToggle: Bool {
        guard context.merchant != nil else { return false }
        switch context.ruleScope {
        case .forward: return true
        case .past: return pastCount > 0
        case .pending: return false
        }
    }

    private var ruleToggle: some View {
        Toggle(isOn: $ruleEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ruleTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.label)
                Text(ruleDetail)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .tint(palette.positive)
    }

    private var ruleTitle: String {
        switch context.ruleScope {
        case .forward: return "No volver a preguntar por " + context.title
        case .past, .pending: return "Asignar también los anteriores"
        }
    }

    private var ruleDetail: String {
        switch context.ruleScope {
        case .forward:
            return "Los próximos movimientos irán a esta categoría"
        case .past, .pending:
            return pastCount == 1
                ? "Reclasifica el movimiento de " + context.title
                : "Reclasifica los \(pastCount) movimientos de " + context.title
        }
    }

    // MARK: - Pie de Pendientes

    /// Una línea de tiempo en pequeño: «antes» ← lo elegido → «después».
    /// Cada lado es un interruptor apagado, con su propio ícono y una frase
    /// que dice qué movimientos toca; debajo, en una línea, el resultado de
    /// la combinación, para no tener que deducirlo de los dos interruptores.
    private func pendingRules(merchants: [String], selected count: Int, earlier: Int) -> some View {
        let target = selected ?? "la categoría"
        let who = merchants.count == 1 ? Accounting.displayName(merchants[0])
                                       : "estos \(merchants.count) comercios"

        return VStack(alignment: .leading, spacing: 8) {
            Text("APLICAR TAMBIÉN A")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                pendingRuleRow(icon: "clock.arrow.circlepath",
                               title: "Los anteriores",
                               detail: earlier == 0
                                   ? "No hay más de " + who + " sin categoría"
                                   : (earlier == 1 ? "1 movimiento anterior" : "\(earlier) movimientos anteriores")
                                       + " de " + who + " sin categoría",
                               isOn: $rules.past,
                               enabled: earlier > 0)
                rowSeparator.padding(.leading, 52)
                pendingRuleRow(icon: "arrow.forward.circle",
                               title: "Los que lleguen",
                               detail: "Lo próximo de " + who + " irá directo a " + target,
                               isOn: $rules.future,
                               enabled: true)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )

            Text(pendingSummary(selected: count, earlier: earlier, who: who))
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: rules)
        }
    }

    private func pendingRuleRow(icon: String, title: String, detail: String,
                                isOn: Binding<Bool>, enabled: Bool) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? palette.positive : palette.secondaryLabel)
                    .frame(width: 28, height: 28)
                    .background((isOn.wrappedValue ? palette.positive : palette.secondaryLabel).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.label)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(2)
                }
            }
        }
        .tint(palette.positive)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// El resultado en una frase: con los dos apagados, sólo lo elegido.
    private func pendingSummary(selected count: Int, earlier: Int, who: String) -> String {
        let past = rules.past && earlier > 0
        let chosen = count == 1 ? "el movimiento elegido"
                   : past ? "los \(count) elegidos" : "los \(count) movimientos elegidos"
        var text = (past || rules.future ? "Se clasifica" : "Solo se clasifica")
            + (count == 1 ? " " : "n ") + chosen
        if past { text += " y \(earlier) anterior" + (earlier == 1 ? "" : "es") }
        if rules.future { text += ", y lo próximo de " + who + " ya vendrá clasificado" }
        return text + "."
    }

    private var primaryButton: some View {
        Button { if let selected { confirm(selected) } } label: {
            Text(primaryTitle)
                .font(.body.weight(.semibold))
                .foregroundStyle(primaryTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(primaryFill)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(selected == nil)
    }

    private var primaryTitle: String {
        guard let selected else { return "Elige una categoría" }
        return "Asignar a " + selected
    }

    private var primaryFill: Color {
        guard let selected else { return palette.track }
        return color(of: selected)
    }

    private var primaryTextColor: Color {
        guard selected != nil else { return palette.secondaryLabel }
        return scheme == .dark ? Color(white: 0.06) : .white
    }

    // MARK: - Acciones

    private func select(_ category: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            selected = selected == category ? nil : category
        }
    }

    /// Asignar no advierte nada antes, aunque la categoría ya esté pasada de
    /// límite: avisar antes convertiría el límite en un obstáculo. El aviso va
    /// después, en el toast que compone quien llama.
    private func confirm(_ category: String) {
        // Sólo si el comercio todavía no tenía categoría: reabrir la hoja de
        // algo ya clasificado no es una sugerencia nueva.
        if let hint = suggestion, context.current == nil || context.current == Accounting.unclassified {
            var props = Analytics.suggestionProps(hint)
            props["screen"] = "assign_sheet"
            Analytics.track(category == hint.category ? .suggestionAccepted : .suggestionDismissed, props)
        }
        if case .pending = context.ruleScope {
            onAssign(category, rules)
        } else {
            let on = ruleEnabled && context.merchant != nil
            switch context.ruleScope {
            case .forward: onAssign(category, AssignCategoryRules(future: on))
            case .past, .pending: onAssign(category, AssignCategoryRules(past: on))
            }
        }
        ProHaptics.play(.categorized)
        dismiss()
    }
}

// MARK: - Fila

/// Una categoría con el saldo de su límite (`1a`): ícono, nombre, saldo con
/// una barra corta y el círculo de selección. La sugerida lleva el rayo, una
/// línea con el porqué y el fondo con el filo del acento. Fuera del cuerpo del
/// sheet: el comprobador de tipos de Swift no termina una expresión con la
/// lista y la fila juntas.
struct CategoryLimitRow: View {

    let category: String
    let status: CategoryLimitStatus
    let color: Color
    let isSelected: Bool
    /// El porqué de la sugerencia; `nil` si esta fila no es la sugerida.
    var suggestionReason: String?
    var accent: Color
    /// En el modo edición del selector la papelera ocupa su sitio.
    var showsRadio = true

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    private var isSuggested: Bool { suggestionReason != nil }
    private var levelColor: Color { status.level.color(palette) }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(scheme == .dark ? 0.22 : 0.18))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: CategoryStyle.icon(for: category))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(color)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(category)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    if isSuggested {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }

                if let suggestionReason {
                    Text("Sugerida · " + suggestionReason)
                        .font(.system(size: 12))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(status.shortLabel)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(levelColor)
                        .lineLimit(1)
                        .fixedSize()
                    bar
                }
            }

            Spacer(minLength: 8)

            if showsRadio { radio }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isSuggested ? accent.opacity(scheme == .dark ? 0.14 : 0.08) : .clear)
        .overlay(alignment: .leading) {
            if isSuggested {
                Rectangle().fill(accent).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category + ", " + status.shortLabel + (isSuggested ? ", sugerida" : ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Sin límite la barra no se dibuja, pero conserva su sitio: así el
    /// texto de todas las filas arranca a la misma altura.
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule()
                    .fill(levelColor)
                    .frame(width: max(2, geo.size.width * CGFloat(status.fraction)))
            }
        }
        .frame(maxWidth: 90)
        .frame(height: 4)
        .opacity(status.hasLimit ? 1 : 0)
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? color : palette.secondaryLabel.opacity(0.45), lineWidth: 1.5)
            if isSelected {
                Circle().fill(color)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
