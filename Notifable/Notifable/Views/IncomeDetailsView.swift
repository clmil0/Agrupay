import SwiftUI
import SwiftData

/// Detalle de un ingreso, con las acciones a la vista — espejo de
/// `ExpenseDetailsView` (`2a`).
///
/// Antes un ingreso no tenía pantalla de detalle: tocarlo sólo ofrecía
/// eliminar, en un `confirmationDialog`. Aquí tiene las mismas tres acciones
/// que un gasto —¿a dónde va?, editar, eliminar— y las mismas propiedades
/// explicadas, en vez de la única acción que cabía en un menú.
struct IncomeDetailsView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Bindable var income: Income

    @State private var showingDestino = false
    @State private var showingEditor = false
    @State private var showingDeleteConfirmation = false
    @ScaledAmountFont(40) private var amountSize

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(colorScheme) }

    var body: some View {
        trackedBody.trackScreen("income_detail")
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    properties
                    explanationNote

                    if income.isDebtPayment {
                        debtStatusSection
                    }

                    deleteButton

                    Spacer(minLength: 24)
                }
                .padding(.top, 24)
            }
            .background(palette.background)
            .navigationTitle("Ingreso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Editar") { showingEditor = true }
                }
            }
            .sheet(isPresented: $showingDestino) {
                IncomeDestinoSheet(income: income)
            }
            .sheet(isPresented: $showingEditor) {
                EditIncomeSheet(income: income)
            }
            .alert("¿Eliminar este ingreso?", isPresented: $showingDeleteConfirmation) {
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) { delete() }
            } message: {
                Text(deleteNote)
            }
        }
        .appAppearance()
        .appTextSize()
        .presentationCornerRadius(32)
        // Ver `ExpenseDetailsView`: sin esto, en oscuro la mitad inferior
        // enseñaba el gris de la hoja del sistema.
        .presentationBackground(palette.background)
    }

    // MARK: - Cabecera

    /// Misma estructura que el gasto (`4f`), para que el par se lea igual.
    private var header: some View {
        VStack(spacing: 8) {
            MovementIcon(icon: iconName, color: iconColor, size: 56)
                .padding(.bottom, 4)

            // Un abono no lleva «+» ni va en verde: no es ingreso, devuelve
            // lo prestado (`Income.amountSign`).
            Text(income.amountSign + Money.format(income.amount, currency: income.currency))
                .font(.system(size: amountSize, weight: .bold))
                .tracking(-1)
                .foregroundStyle(income.isDebtPayment ? palette.label : accent.incomeColor(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(income.title?.isEmpty == false ? income.title! : income.source)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
        }
        .padding(.horizontal, 16)
    }

    /// «1 set · Transferencia».
    private var subtitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        return f.string(from: income.date).replacingOccurrences(of: ".", with: "") + " · " + income.source
    }

    private var iconName: String { IncomeStyle.iconAndColor(for: income, accent: accent.incomeFillColor).1 }
    private var iconColor: Color { IncomeStyle.iconAndColor(for: income, accent: accent.incomeFillColor).0 }
    // MARK: - Propiedades

    private var properties: some View {
        VStack(spacing: 0) {
            // La única fila con decisión, arriba: ingreso libre o abono.
            Button { showingDestino = true } label: {
                propertyRow(title: "¿A dónde va?", icon: "scope") {
                    HStack(spacing: 6) {
                        Text(destinoValue)
                            .fontWeight(.semibold)
                            .foregroundStyle(palette.label)
                            .multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)

            divider

            // Fuente y fecha sólo se editan desde «Editar»: estas filas son de
            // lectura a propósito, para que no haya dos caminos a la misma
            // edición.
            propertyRow(title: "Fuente", icon: "building.columns") {
                Text(income.source)
                    .foregroundStyle(palette.secondaryLabel)
            }

            divider

            Button { showingEditor = true } label: {
                propertyRow(title: "Descripción", icon: "text.alignleft") {
                    HStack(spacing: 6) {
                        Text(income.notes?.isEmpty == false ? income.notes! : "Sin descripción")
                            .lineLimit(1)
                            .foregroundStyle(palette.secondaryLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }
            .buttonStyle(.plain)

            divider

            propertyRow(title: "Fecha", icon: "calendar") {
                Text(fullDate)
                    .foregroundStyle(palette.secondaryLabel)
            }

            if income.currency != "PEN" {
                divider
                propertyRow(title: "Moneda", icon: "dollarsign.circle") {
                    Text("Dólares (USD)")
                        .foregroundStyle(palette.secondaryLabel)
                }
            }

            if income.emailID != nil {
                divider
                propertyRow(title: "Origen", icon: "envelope") {
                    Text("Correo")
                        .foregroundStyle(palette.secondaryLabel)
                }
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

    /// «1 set 2026, 09:12».
    private var fullDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: income.date).replacingOccurrences(of: ".", with: "")
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Borrar ingreso", systemImage: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.negative)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var destinoValue: String {
        guard let debt = income.debtReference else { return "Ingreso libre" }
        return Accounting.displayName(debt.merchant)
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

    // MARK: - Estado del cobro

    @ViewBuilder
    private var debtStatusSection: some View {
        if let debt = income.debtReference {
            let paid = Accounting.paid(of: debt)
            let pending = Accounting.outstanding(of: debt)
            let ratio = min(Money.ratio(paid, to: debt.amount) ?? 0, 1.0)

            VStack(alignment: .leading, spacing: 12) {
                Text("Estado del cobro")
                    .font(.headline)
                    .foregroundStyle(palette.label)

                HStack {
                    Text(Money.format(paid, currency: debt.currency) + " devuelto")
                        .font(.subheadline)
                        .foregroundStyle(palette.positive)
                    Spacer()
                    Text("faltan " + Money.format(pending, currency: debt.currency))
                        .font(.subheadline)
                        .foregroundStyle(Money.isZero(pending) ? palette.positive : palette.warning)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(radius: 22)
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Explicación

    private var explanationNote: some View {
        ShellNote(icon: "info.circle",
                  text: income.isDebtPayment
                      ? "Es un abono a un cobro: no cuenta en tu balance, sólo reduce lo que te deben."
                      : "Como ingreso libre, cuenta en tu balance del mes. Si lo abonas a un cobro, deja de contar y baja la deuda.")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private var deleteNote: String {
        income.isDebtPayment
            ? "Se borrará de tus cuentas y lo que devuelve volverá a figurar como pendiente. Esto no se puede deshacer."
            : "Se borrará de tus cuentas. Esto no se puede deshacer."
    }

    // MARK: - Eliminar

    private func delete() {
        income.deleteRestoringDebt(in: modelContext)
        dismiss()
    }
}

/// «¿A dónde va este ingreso?» — reasignar, desasignar o dejarlo suelto (`2b`).
///
/// Es la misma decisión de `AddTransactionSheet.debtCard`, pero sobre un
/// `Income` que ya existe: puede tener una deuda vinculada de antes, así que
/// —a diferencia del alta— aquí "guardar" puede *quitar* un vínculo, no sólo
/// ponerlo.
struct IncomeDestinoSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Bindable var income: Income

    @Query(filter: #Predicate<Expense> { $0.isDebt == true }, sort: \Expense.date, order: .reverse)
    private var activeDebts: [Expense]

    @State private var selection: Expense?
    @State private var didInitializeSelection = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(colorScheme) }

    /// Sólo deudas en la misma moneda del ingreso, más la que ya tuviera
    /// vinculada (por si quedó en otra moneda por un dato antiguo): así el
    /// pícker nunca oculta la selección actual.
    private var debts: [Expense] {
        activeDebts.filter { $0.currency == income.currency || $0.id == income.debtReference?.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let debt = income.debtReference {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("DEUDA ASIGNADA")
                            linkedDebtRow(debt)
                        }
                    }

                    Text("Un ingreso normal cuenta en tu balance. Un cobro no: sólo reduce lo que te deben.")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("SIN DESTINO")
                        noneRow
                    }

                    if !debts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionHeader("ABONAR A UN COBRO PENDIENTE")
                            VStack(spacing: 8) {
                                ForEach(debts) { debt in
                                    debtRow(debt)
                                }
                            }
                        }
                    }

                    if let warning = destinoWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(palette.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(palette.warning.opacity(colorScheme == .dark ? 0.16 : 0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(16)
            }
            .background(palette.background)
            .navigationTitle("¿A dónde va?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                guard !didInitializeSelection else { return }
                selection = income.debtReference
                didInitializeSelection = true
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(palette.background)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(palette.secondaryLabel)
    }

    /// Lleva a la deuda: se cierran estas hojas y se abre su detalle
    /// (`ActivityFocus`).
    private func linkedDebtRow(_ debt: Expense) -> some View {
        let color = CategoryStyle.color(for: debt.category, accent: accent.color)
        return Button {
            ActivityFocus.request(transactionID: debt.id, date: debt.date)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: CategoryStyle.icon(for: debt.category))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Accounting.displayName(debt.merchant))
                        .font(.headline)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(Money.format(debt.amount, currency: debt.currency) + " · "
                         + debt.date.formatted(.dateTime.day().month().locale(Locale(identifier: "es_ES"))) + " · Ver detalle")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.onSurface(colorScheme))
            }
            .padding(14)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ver \(Accounting.displayName(debt.merchant)) en Actividad reciente")
    }

    private var noneRow: some View {
        Button { selection = nil } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.positive.opacity(0.18))
                        .frame(width: 40, height: 40)
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(palette.positive)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ingreso libre")
                        .font(.headline)
                        .foregroundStyle(palette.label)
                    Text("Cuenta en tu balance del mes")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer()
                radio(selected: selection == nil)
            }
            .padding(14)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selection == nil ? accent.color.opacity(0.55) : palette.hairline,
                            lineWidth: selection == nil ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func debtRow(_ debt: Expense) -> some View {
        let selected = selection?.id == debt.id
        return Button { selection = debt } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CategoryStyle.color(for: debt.category, accent: accent.color).opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: CategoryStyle.icon(for: debt.category))
                        .foregroundStyle(CategoryStyle.color(for: debt.category, accent: accent.color))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Accounting.displayName(debt.merchant))
                        .font(.headline)
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text("saldo " + Money.format(outstandingExcludingSelf(debt), currency: debt.currency))
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer()
                radio(selected: selected)
            }
            .padding(14)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? accent.color.opacity(0.55) : palette.hairline, lineWidth: selected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func radio(selected: Bool) -> some View {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(selected ? accent.color : palette.secondaryLabel)
    }

    /// Saldo de la deuda como si este ingreso todavía no la hubiera abonado —
    /// si no, un ingreso que ya apunta aquí vería su propio abono restado del
    /// saldo que se le ofrece elegir. Mismo motivo que
    /// `TransactionDraft.selectedDebtOutstanding`.
    private func outstandingExcludingSelf(_ debt: Expense) -> Double {
        let raw = Accounting.outstanding(of: debt)
        guard income.debtReference?.id == debt.id else { return raw }
        return Money.value(Money.cents(raw) + Money.cents(income.amount))
    }

    private var destinoWarning: String? {
        guard let debt = selection else { return nil }
        guard debt.currency == income.currency else {
            return "Lo que te deben está en \(debt.currency). No se puede abonar en otra moneda."
        }
        let available = outstandingExcludingSelf(debt)
        let excess = Money.subtract(income.amount, available)
        guard Money.cents(excess) > 0 else { return nil }
        return "Supera lo que te deben en " + Money.format(excess, currency: income.currency)
    }

    private var canSave: Bool { destinoWarning == nil }

    private func save() {
        setDestino(selection)
        dismiss()
    }

    private func setDestino(_ newDebt: Expense?) {
        let oldDebt = income.debtReference
        // Este abono deja de contar contra la deuda anterior: si con él se
        // había dado por saldada, vuelve a quedar por cobrar.
        if let oldDebt, oldDebt.id != newDebt?.id, income.isFinalDebtPayment == true, !oldDebt.isDebt {
            oldDebt.isDebt = true
            ExpenseEditStore.record(oldDebt, isDebt: true)
        }

        income.debtReference = newDebt

        if let newDebt {
            let cancels = Money.isZero(Accounting.outstanding(of: newDebt))
            income.isFinalDebtPayment = cancels
            if cancels, newDebt.isDebt {
                newDebt.isDebt = false
                ExpenseEditStore.record(newDebt, isDebt: false)
            }
            IncomeLinkStore.record(income: income, expense: newDebt, isFinal: cancels)
        } else {
            income.isFinalDebtPayment = false
            IncomeLinkStore.remove(incomeID: income.id)
        }

        let descriptor = FetchDescriptor<Expense>(predicate: #Predicate { $0.isDebt == true })
        let hasDebts = ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
        NotificationManager.shared.updateDebtNotification(hasDebts: hasDebts)

        try? modelContext.save()
    }
}

/// Edición mínima de un ingreso: nombre, monto, fuente y fecha (`2c`) — el
/// mismo alcance que `EditExpenseSheet` tiene para un gasto.
struct EditIncomeSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var income: Income

    @State private var amountText = ""
    @State private var titleText = ""
    @State private var source = "Transferencia"
    @State private var date = Date()
    @State private var notesText = ""

    private static let sources = ["Transferencia", "Yape", "Plin", "Efectivo", "Otro"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Monto") {
                    HStack {
                        Text(Money.symbol(for: income.currency))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                }
                Section("Título") {
                    TextField("Sueldo, venta de laptop…", text: $titleText)
                        .disableAutocorrection(true)
                }
                Section("Fuente") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.sources, id: \.self) { option in
                                sourceChip(option)
                            }
                        }
                    }
                    .padding(.vertical, 4)
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
            .navigationTitle("Editar ingreso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                }
            }
            .onAppear {
                amountText = String(format: "%.2f", income.amount)
                titleText = income.title ?? ""
                source = income.source
                date = income.date
                notesText = income.notes ?? ""
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sourceChip(_ name: String) -> some View {
        let selected = source == name
        return Button {
            source = name
        } label: {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let cleaned = amountText.replacingOccurrences(of: ",", with: ".")
        if let value = Double(cleaned), value > 0 {
            income.amount = Money.normalized(value)
        }
        income.title = titleText.trimmed.isEmpty ? nil : titleText.trimmed
        income.source = source
        income.date = date
        income.notes = notesText.trimmed.isEmpty ? nil : notesText.trimmed
        try? modelContext.save()
        dismiss()
    }
}
