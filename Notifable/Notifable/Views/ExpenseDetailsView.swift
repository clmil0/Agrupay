import SwiftUI
import SwiftData

/// Detalle de un movimiento (`4e`): cabecera con el monto grande y el resto
/// como una lista de una fila por dato. Editar vive en la barra; «Por cobrar»
/// es una fila más; borrar, al pie. El estado del cobro sólo existe si el
/// gasto está marcado como deuda.
struct ExpenseDetailsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    /// `@State`, no `@Bindable`: nada aquí usa `$expense.algo` como binding.
    @State private var expense: Expense

    init(expense: Expense) {
        self._expense = State(initialValue: expense)
    }

    @Query private var allExpenses: [Expense]

    @State private var showingCategoryPicker = false
    @State private var showingEditor = false
    @State private var showingCollect = false
    @State private var showingReminder = false
    @State private var showingDeleteConfirmation = false
    @State private var showingTagPicker = false
    @State private var showingRecurrence = false
    @State private var splitEditorParent: Expense?
    @State private var showingUndoSplit = false
    @State private var focusedPart: Expense?
    @State private var editingRule: RecurringExpense?
    @State private var recurrence = RecurrenceDraft()
    @Query private var recurringRules: [RecurringExpense]
    @ScaledAmountFont(40) private var amountSize

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var themeColor: Color { accent.color }
    private var palette: Palette { Palette(colorScheme) }

    /// Por cobrar, con abonos, o dada por saldada: hay estado de cobro que
    /// mostrar.
    private var showsPayments: Bool {
        expense.isDebt || expense.debtSettled || !(expense.payments ?? []).isEmpty
    }

    /// Un aviso de anulación no tiene ficha: tocarlo es elegir qué compra se
    /// anuló.
    var body: some View {
        if expense.isDeleted || expense.modelContext == nil {
            // Borrado mientras la hoja se cierra (el aviso ya resuelto).
            Color.clear
        } else if expense.isReversal {
            ReversalResolveView(reversal: expense)
        } else {
            details
        }
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if expense.isVoided { voidedBanner }
                    foreignPaymentsWarning
                    if let split = splitContext { splitCard(split) }
                    properties

                    if showsPayments {
                        paymentsSection
                            .transition(.opacity)
                    }

                    if splitContext == nil, ExpenseSplit.canSplit(expense) {
                        splitEntryRow
                    }

                    if splitContext != nil {
                        undoSplitButton
                    }
                    // Una parte no se borra suelta: las demás dejarían de
                    // cuadrar con el pago.
                    if expense.splitOf == nil {
                        deleteButton
                    }

                    Spacer(minLength: 24)
                }
                .padding(.top, 24)
                // Atada a `value`, no sólo al `withAnimation` del botón: así el
                // alto de la sección se anima siempre que el estado cambie,
                // sin depender de qué transacción disparó el cambio.
                .animation(.spring(response: 0.4, dampingFraction: 0.86),
                          value: showsPayments)
            }
            .background(palette.background)
            .navigationTitle("Movimiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                // Editar sube a la barra (`4e`): la fila de tres botones
                // grandes ocupaba el sitio de los datos para ofrecer acciones
                // que se usan de vez en cuando.
                ToolbarItem(placement: .primaryAction) {
                    Button("Editar") { showingEditor = true }
                }
            }
            .sheet(isPresented: $showingRecurrence, onDismiss: saveRecurrence) {
                RecurrenceSheet(draft: $recurrence,
                                merchant: expense.merchant,
                                amount: expense.amount,
                                currency: expense.currency)
            }
            .sheet(item: $editingRule) { RecurringExpenseEditor(rule: $0) }
            .sheet(isPresented: $showingCategoryPicker) {
                // `6a`: el mismo componente que la Bandeja y el modal de alta.
                ExpenseCategorySheet(expense: expense)
            }
            .sheet(isPresented: $showingEditor) {
                EditExpenseSheet(expense: expense)
            }
            .sheet(isPresented: $showingTagPicker) {
                // `toggleTag` ya anota la edición y guarda: etiquetar un gasto
                // que vino del correo tiene que sobrevivir a la relectura.
                TagPickerSheet(selected: expense.tags) { tag in
                    withAnimation(.snappy(duration: 0.2)) {
                        expense.toggleTag(tag, in: modelContext)
                    }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
            }
            .sheet(isPresented: $showingCollect) {
                AddTransactionSheet(collecting: expense)
            }
            .sheet(isPresented: $showingReminder) {
                ReminderComposerSheet(initialDebt: expense)
            }
            .sheet(item: $splitEditorParent) { SplitExpenseSheet(parent: $0) }
            .sheet(item: $focusedPart) { ExpenseDetailsView(expense: $0) }
            .alert("¿Deshacer la división?", isPresented: $showingUndoSplit) {
                Button("Cancelar", role: .cancel) {}
                Button("Deshacer", role: .destructive) { undoSplit() }
            } message: {
                Text("Se borran sus partes y el pago vuelve a contar entero en su categoría.")
            }
            .alert("¿Eliminar movimiento?", isPresented: $showingDeleteConfirmation) {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) { delete() }
            } message: {
                Text("Se borrará de tus cuentas. Esto no se puede deshacer.")
            }
        }
        .appAppearance()
            .appTextSize()
        .presentationCornerRadius(32)
        // El fondo de la hoja, no sólo el del `ScrollView`: en oscuro, donde
        // el contenido no llegaba, se veía el gris de la hoja del sistema.
        .presentationBackground(palette.background)
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(spacing: 8) {
            // `MovementStyle`, no un `switch` propio: antes esta cabecera tenía
            // cuatro categorías fijas, así que una categoría creada por el
            // usuario salía con una bolsa verde aquí y con su ícono real en la
            // lista de la que venías.
            headerIcon
                .padding(.bottom, 4)

            Text("–" + Money.format(expense.amount, currency: expense.currency))
                .font(.system(size: amountSize, weight: .bold))
                .tracking(-1)
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(Accounting.displayName(expense.merchant))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
        }
        .padding(.horizontal, 16)
    }

    /// Una parte lleva el ícono de su categoría con el logo del canal pegado
    /// (`2d`): es un gasto propio, pero salió de ese pago.
    @ViewBuilder
    private var headerIcon: some View {
        if expense.splitOf != nil {
            ZStack(alignment: .bottomTrailing) {
                MovementIcon(icon: CategoryStyle.icon(for: expense.category),
                             color: CategoryStyle.color(for: expense.category, accent: themeColor),
                             size: 56)
                if let logo = SplitStyle.channelLogo(for: expense) {
                    Image(logo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(palette.background, lineWidth: 2.5))
                        .offset(x: 5, y: 5)
                }
            }
        } else {
            MovementIcon(icon: MovementStyle.icon(for: expense),
                         color: MovementStyle.color(for: expense, accent: themeColor, scheme: colorScheme),
                         size: 56)
        }
    }

    /// «Hoy, 17 set · 14:20 · BCP».
    private var subtitle: String {
        let calendar = Period.calendar
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        let day = f.string(from: expense.date).replacingOccurrences(of: ".", with: "")
        let prefix = calendar.isDateInToday(expense.date) ? "Hoy, "
            : calendar.isDateInYesterday(expense.date) ? "Ayer, " : ""
        var parts = [prefix + day, expense.date.formatted(.dateTime.hour().minute())]
        if let source = MovementStyle.source(for: expense) { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Aviso de multimoneda

    @ViewBuilder
    private var foreignPaymentsWarning: some View {
        if Accounting.hasForeignPayments(expense) {
            Label("Hay devoluciones en otra moneda. El saldo no se puede calcular con ellas, así que quedan fuera de esta cuenta.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(palette.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.warning.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Propiedades

    /// Compra anulada por el banco: no cuenta. Si se eligió por error, se
    /// deshace aquí.
    private var voidedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(palette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Anulada por el banco")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
                Text("No cuenta en tus gastos.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 8)
            Button("Deshacer") {
                ReversalMatcher.restore(expense, in: modelContext)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(accent.onSurface(colorScheme))
        }
        .padding(14)
        .background(palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var properties: some View {
        VStack(spacing: 0) {
            // Un pago dividido no tiene categoría ni etiquetas propias: las
            // tienen sus partes. Queda lo que describe el pago.
            if !expense.isSplit {
                Button { showingCategoryPicker = true } label: {
                    propertyRow(title: "Categoría", icon: "square.grid.2x2") {
                        HStack(spacing: 6) {
                            Text(expense.category)
                                .fontWeight(.semibold)
                                .foregroundStyle(accent.onSurface(colorScheme))
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                    }
                }
                .buttonStyle(.plain)

                divider

                tagsRow

                divider
            }

            Button { showingEditor = true } label: {
                propertyRow(title: "Descripción", icon: "text.alignleft") {
                    HStack(spacing: 6) {
                        Text(expense.notes?.isEmpty == false ? expense.notes! : "Agregar")
                            .lineLimit(1)
                            .foregroundStyle(expense.notes?.isEmpty == false ? accent.onSurface(colorScheme) : palette.secondaryLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)

            divider

            propertyRow(title: "Origen", icon: "envelope") {
                Text(origin)
                    .foregroundStyle(palette.secondaryLabel)
            }

            // La moneda sólo cuando no es soles: en soles es lo esperado y la
            // fila no dice nada.
            if expense.currency != "PEN" {
                divider

                propertyRow(title: "Moneda", icon: "dollarsign.circle") {
                    Text("Dólares (USD)")
                        .foregroundStyle(palette.secondaryLabel)
                }

                if let fx = expense.fxRateAtCapture {
                    divider
                    propertyRow(title: "Tipo de cambio", icon: "arrow.left.arrow.right") {
                        // El del día del movimiento, no el de hoy: por eso el
                        // total de un mes cerrado ya no se mueve.
                        Text("S/ " + String(format: "%.3f", fx) + " por $ 1")
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }

            // Repetir y «Por cobrar» son de un gasto: un pago dividido ya no
            // lo es, lo son sus partes. Y una parte no se repite sola: la regla
            // iría por el comercio, que es el del pago entero.
            if !expense.isSplit && expense.splitOf == nil {
                divider

                Button(action: openRecurrence) {
                    propertyRow(title: "Repetir", icon: "arrow.triangle.2.circlepath") {
                        HStack(spacing: 6) {
                            Text(recurrenceLabel)
                                .foregroundStyle(existingRule == nil ? palette.secondaryLabel
                                                                     : accent.onSurface(colorScheme))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if !expense.isSplit {
                divider

                // «Por cobrar» baja de la fila de botones a una fila más: sigue a
                // un toque, pero ya no compite en tamaño con los datos.
                Toggle(isOn: Binding(get: { expense.isDebt }, set: { _ in toggleDebt() })) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(palette.secondaryLabel)
                            .frame(width: 20)
                        Text("Por cobrar")
                            .foregroundStyle(palette.label)
                    }
                }
                .tint(palette.warning)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - División

    /// El pago y sus partes, cuando este movimiento es uno u otro.
    private struct SplitContext {
        let parent: Expense?
        let parts: [Expense]
    }

    private var splitContext: SplitContext? {
        if expense.isSplit {
            let parts = ExpenseSplit.parts(of: expense, among: allExpenses)
            return parts.isEmpty ? nil : SplitContext(parent: expense, parts: parts)
        }
        guard let key = expense.splitOf else { return nil }
        let siblings = allExpenses.filter { $0.splitOf == key }
            .sorted { $0.splitIndex < $1.splitIndex }
        return SplitContext(parent: ExpenseSplit.parent(of: expense, among: allExpenses), parts: siblings)
    }

    /// `2a`: la entrada, debajo de los datos y antes de borrar.
    private var splitEntryRow: some View {
        Button { splitEditorParent = expense } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(themeColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(themeColor)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dividir gasto")
                        .foregroundStyle(palette.label)
                    Text("Sepáralo en lo que realmente fue")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surfaceCard(radius: 22, padding: 0)
        .padding(.horizontal, 16)
    }

    /// `2d`: de qué pago sale, la barra con esta parte encendida y la lista de
    /// hermanas. En el pago dividido, la misma tarjeta sin «ESTA».
    private func splitCard(_ split: SplitContext) -> some View {
        let isPart = expense.splitOf != nil
        let myIndex = split.parts.firstIndex { $0.id == expense.id }
        let total = split.parent?.amount ?? Money.sum(split.parts) { $0.amount }
        let currency = split.parent?.currency ?? expense.currency

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(themeColor)
                Text(splitTitle(split, index: myIndex))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("de " + Money.format(total, currency: currency))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryLabel)
            }

            SplitBar(segments: split.parts.map {
                ($0.amount,
                 CategoryStyle.color(for: $0.category, accent: themeColor),
                 !isPart || $0.id == expense.id ? 1 : 0.35)
            }, total: total, height: 8)

            VStack(spacing: 0) {
                ForEach(Array(split.parts.enumerated()), id: \.element.id) { index, part in
                    let isMe = part.id == expense.id
                    Button {
                        // Desde el pago se puede abrir cada parte; desde una
                        // parte, sus hermanas se ven aquí mismo.
                        if !isPart { focusedPart = part }
                    } label: {
                        HStack(spacing: 10) {
                            SplitCategoryIcon(category: part.category,
                                              color: CategoryStyle.color(for: part.category, accent: themeColor),
                                              size: 24)
                            Text(part.category)
                                .font(.system(size: 14, weight: isMe ? .semibold : .regular))
                                .foregroundStyle(palette.label)
                                .lineLimit(1)
                            if isMe {
                                Text("ESTA")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(accent.onSurface(colorScheme))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(themeColor.opacity(0.12),
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            Spacer(minLength: 8)
                            Text(Money.format(part.amount, currency: part.currency))
                                .font(.system(size: 14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(palette.label)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(palette.separator).frame(height: 0.5)
                        }
                    }
                }
            }

            if let parent = split.parent {
                Button { splitEditorParent = parent } label: {
                    Label("Editar división", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent.onSurface(colorScheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(themeColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: 22)
        .padding(.horizontal, 16)
    }

    /// «Parte 1 de 2 de un Yape» en una parte; «Dividido en 2» en el pago.
    private func splitTitle(_ split: SplitContext, index: Int?) -> String {
        guard expense.splitOf != nil else { return "Dividido en \(split.parts.count)" }
        let position = index.map { "Parte \($0 + 1) de \(split.parts.count)" } ?? "Parte"
        // «de un Yape»; con tarjeta, «de un pago»: «de un •••• 8156» no se lee.
        let channel = SplitStyle.channelName(for: expense).map { " de un " + $0 } ?? " de un pago"
        return position + channel
    }

    private var undoSplitButton: some View {
        Button { showingUndoSplit = true } label: {
            Label("Deshacer división", systemImage: "arrow.uturn.backward")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.negative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func undoSplit() {
        guard let split = splitContext else { return }
        let isPart = expense.splitOf != nil
        if let parent = split.parent {
            ExpenseSplit.undo(parent, in: modelContext)
        } else {
            // El pago todavía no se releyó del correo: se borran las partes
            // igual, y al volver llegará sin dividir.
            for part in split.parts { modelContext.delete(part) }
            try? modelContext.save()
        }
        // Esta ficha era de una parte que ya no existe.
        if isPart { dismiss() }
    }

    // MARK: - Repetir

    /// La regla que ya cubre este comercio, si la hay.
    private var existingRule: RecurringExpense? {
        recurringRules.first { $0.merchant == expense.merchant }
    }

    private var recurrenceLabel: String {
        guard let rule = existingRule else { return "No se repite" }
        return rule.isPaused ? "En pausa" : "Se repite"
    }

    /// Sin regla, se crea una a partir de este gasto. Con regla, se edita la
    /// existente: crear otra duplicaría los cobros propuestos.
    private func openRecurrence() {
        if let rule = existingRule {
            editingRule = rule
        } else {
            recurrence = RecurrenceDraft()
            showingRecurrence = true
        }
    }

    private func saveRecurrence() {
        guard existingRule == nil, recurrence.repeats,
              let rule = recurrence.build(merchant: expense.merchant,
                                          category: expense.category,
                                          amount: expense.amount,
                                          currency: expense.currency) else { return }
        // Este gasto ya está registrado: la regla arranca con su fecha resuelta
        // para no proponerlo otra vez.
        rule.lastResolvedOccurrence = expense.date
        modelContext.insert(rule)
        expense.isSubscription = true
        ExpenseEditStore.record(expense, isSubscription: true)
        try? modelContext.save()
    }

    // MARK: - Borrar

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Borrar movimiento", systemImage: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.negative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var origin: String {
        if expense.splitOf != nil { return "División de un pago" }
        guard expense.emailID != nil else { return "Manual" }
        if let card = expense.cardLastDigits { return "Correo · •••• " + card }
        return "Correo"
    }

    /// Las etiquetas van pegadas a la categoría, y no en cualquier otro sitio
    /// de la ficha, porque es ahí donde se entiende la diferencia: arriba la
    /// que clasifica el gasto —una, obligatoria, la que lleva el límite—, y
    /// debajo las que lo cruzan —las que hagan falta, opcionales, sin límite—.
    private var tagsRow: some View {
        Button { showingTagPicker = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "tag")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.secondaryLabel)
                        .frame(width: 20)
                    Text("Etiquetas")
                        .foregroundStyle(palette.label)
                    Spacer(minLength: 12)
                    if expense.tags.isEmpty {
                        Text("Agregar")
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryLabel)
                }

                if !expense.tags.isEmpty {
                    TagFlowLayout {
                        ForEach(expense.tags, id: \.self) { tag in
                            TagChip(name: tag)
                        }
                    }
                    .padding(.leading, 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func propertyRow<Value: View>(title: String, icon: String? = nil,
                                          @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 20)
            }
            Text(title)
                .foregroundStyle(palette.label)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    // MARK: - Deuda

    @ViewBuilder
    private var paymentsSection: some View {
        VStack(spacing: 8) {
            ShellSectionHeader(title: "Estado del cobro")
                .padding(.horizontal, 16)
            paymentsCard
        }
    }

    @ViewBuilder
    private var paymentsCard: some View {
        let paid = Accounting.paid(of: expense)
        let pending = Accounting.outstanding(of: expense)
        let settled = !expense.isDebt && expense.debtSettled
        // Saldada, la barra se llena: lo que no se cobró ya es gasto propio y
        // no queda nada pendiente.
        let ratio = settled ? 1.0 : min(Money.ratio(paid, to: expense.amount) ?? 0, 1.0)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if settled {
                    Label("Deuda saldada", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.positive)
                } else {
                    Text(expense.isDebt ? "Te deben " + Money.format(pending, currency: expense.currency)
                                        : pendingLabel(pending).capitalizedFirst)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(expense.isDebt ? palette.label : pendingColor(pending))
                }
                Spacer()
                Text("de " + Money.format(expense.amount, currency: expense.currency))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryLabel)
            }

            if settled, Money.cents(pending) > 0 {
                Text("Los " + Money.format(pending, currency: expense.currency)
                     + " que no se cobraron quedan como gasto tuyo.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule()
                        .fill(palette.positive)
                        .frame(width: geo.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 8)

            ForEach((expense.payments ?? []).sorted(by: { $0.date > $1.date })) { payment in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.source)
                            .font(.subheadline)
                            .foregroundStyle(palette.label)
                        Text(payment.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    Spacer()
                    // Sin "+": un abono devuelve lo prestado, no es un ingreso.
                    Text(Money.format(payment.amount, currency: payment.currency))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.positive)
                }
            }

            // Sólo mientras sigue por cobrar: saldada, no hay nada que
            // registrar. Abre el alta de ingreso ya en modo abono.
            if expense.isDebt {
                Button { showingCollect = true } label: {
                    Label("Registrar cobro", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent.onSurface(colorScheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(themeColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity)

                // Cobrar por dentro de la app: un recado al amigo, que no
                // mueve ni un sol de ninguna de las dos contabilidades.
                Button { showingReminder = true } label: {
                    Label("Recordar a un amigo", systemImage: "bell.badge")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent.onSurface(colorScheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(themeColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity)

                // Cerrar la deuda con saldo: nadie va a devolver el resto.
                Button { settleDebt() } label: {
                    Label("Deuda saldada", systemImage: "checkmark.seal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.positive)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(palette.positive.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(radius: 22)
        .padding(.horizontal, 16)
    }

    /// Mientras sigue por cobrar: "faltan X" (ámbar, o verde si ya no falta
    /// nada). Declarada "Saldada" con saldo: "sin cobrar X", en gris — ya no
    /// se persigue, así que no tiene sentido seguir avisando en ámbar.
    private func pendingLabel(_ pending: Double) -> String {
        if expense.isDebt {
            return "faltan " + Money.format(pending, currency: expense.currency)
        }
        return Money.isZero(pending) ? "saldada" : "sin cobrar " + Money.format(pending, currency: expense.currency)
    }

    private func pendingColor(_ pending: Double) -> Color {
        if expense.isDebt {
            return Money.isZero(pending) ? palette.positive : palette.warning
        }
        return Money.isZero(pending) ? palette.positive : palette.secondaryLabel
    }

    // MARK: - Acciones

    /// Este botón dice "Saldada" cuando el gasto sigue marcado por cobrar.
    /// Declararla saldada con un saldo pendiente no lo pone en cero: ese saldo
    /// es lo que nunca te devolvieron, y sigue apareciendo así en la fila. Lo
    /// que sí cambia es `isDebt` — deja de ofrecerse como destino al abonar un
    /// ingreso (`IncomeDestinoSheet`) y deja de sumar al total "por cobrar"
    /// del mes, porque ya no se está esperando que se salde solo.
    private func toggleDebt() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            expense.toggleDebt(in: modelContext)
        }
    }

    private func settleDebt() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            expense.settleDebt(in: modelContext)
        }
    }

    private func delete() {
        expense.deleteRecordingRecovery(in: modelContext)
        dismiss()
    }
}

/// Edición mínima de un movimiento: lo que un parser puede haber leído mal.
struct EditExpenseSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var expense: Expense

    @State private var amountText = ""
    @State private var merchant = ""
    @State private var date = Date()
    @State private var notesText = ""

    private var isInSplit: Bool { expense.isSplit || expense.splitOf != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(Money.symbol(for: expense.currency))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .disabled(isInSplit)
                            .foregroundStyle(isInSplit ? .secondary : .primary)
                    }
                } header: {
                    Text("Monto")
                } footer: {
                    // Las partes suman el pago al céntimo: cambiar un monto
                    // suelto rompería la cuenta.
                    if isInSplit {
                        Text("Está dividido. Cambia los montos desde «Editar división».")
                    }
                }
                Section("Comercio") {
                    TextField("Comercio", text: $merchant)
                        .disableAutocorrection(true)
                }
                Section("Descripción") {
                    TextField("Opcional", text: $notesText, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("Fecha") {
                    DatePicker("Fecha", selection: $date)
                        .datePickerStyle(.compact)
                }
            }
            .navigationTitle("Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(merchant.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                amountText = String(format: "%.2f", expense.amount)
                merchant = expense.merchant
                date = expense.date
                notesText = expense.notes ?? ""
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        // Se compara contra el valor original y sólo lo que de verdad cambió
        // se manda a `record`: antes se mandaban los tres campos siempre, así
        // que abrir "Editar" y tocar Guardar sin tocar nada ya creaba una fila
        // en el respaldo — con casi cualquier gasto tarde o temprano pasando
        // por aquí, esa fila terminaba existiendo para prácticamente todos.
        let originalAmount = expense.amount
        let originalMerchant = expense.merchant
        let originalDate = expense.date
        let originalNotes = expense.notes
        let originalKey = TransactionKey.key(for: expense)

        let cleaned = amountText.replacingOccurrences(of: ",", with: ".")
        if !isInSplit, let value = Double(cleaned), value > 0 {
            // Céntimos enteros, igual que en el init del modelo.
            expense.amount = Money.normalized(value)
        }
        expense.merchant = merchant.trimmingCharacters(in: .whitespaces)
        expense.date = date
        let trimmedNotes = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
        expense.notes = trimmedNotes.isEmpty ? nil : trimmedNotes

        ExpenseEditStore.record(expense,
                                merchant: expense.merchant != originalMerchant ? expense.merchant : nil,
                                amount: Money.cents(expense.amount) != Money.cents(originalAmount) ? expense.amount : nil,
                                occurredAt: expense.date != originalDate ? expense.date : nil,
                                // `""`, no `nil`: `nil` en `ExpenseEdit` significa
                                // "no lo tocó", así que borrar la descripción
                                // necesita un valor no-nulo para registrarse.
                                notes: expense.notes != originalNotes ? (expense.notes ?? "") : nil)
        try? modelContext.save()
        if expense.isSplit {
            ExpenseSplit.rekey(from: originalKey, to: TransactionKey.key(for: expense), in: modelContext)
        }
        dismiss()
    }
}
