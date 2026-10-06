import SwiftUI
import SwiftData
import UIKit

/// Alta de gasto o ingreso. Reemplaza a `AddExpenseView`.
///
/// Tres cosas cambian de fondo respecto al modal anterior:
/// el monto —lo único que el usuario viene a escribir— deja de ser el elemento
/// más pequeño de la pantalla; el tipo se puede cambiar sin cerrar y volver a
/// abrir; y el botón nunca acepta un toque sin hacer nada: si falta algo, está
/// deshabilitado y su propio texto dice qué falta.
struct AddTransactionSheet: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Query(filter: #Predicate<Expense> { $0.isDebt == true }, sort: \Expense.date, order: .reverse)
    private var activeDebts: [Expense]
    @Query(sort: \Expense.date, order: .reverse) private var history: [Expense]
    @Query(sort: \QuickExpense.sortIndex) private var quickExpenses: [QuickExpense]

    @State private var draft: TransactionDraft
    @State private var showDatePicker = false
    @State private var showAllCategories = false
    @State private var showDebtPicker = false
    @State private var showDiscardDialog = false
    @State private var justSaved = false
    @State private var recurrence = RecurrenceDraft()
    @State private var showRecurrenceSheet = false
    @State private var showSourcePicker = false
    @State private var showDetail = false
    @State private var showQuickEditor = false
    @State private var activeQuickID: UUID?
    /// El atajo en uso, abierto desde Detalle. Aparte de `showQuickEditor`:
    /// ése se presenta desde la hoja principal, que con Detalle encima no
    /// puede presentar nada.
    @State private var editingActiveQuick: QuickExpense?
    /// Cómo estaba el atajo al abrirlo, para llevar al gasto sólo lo que cambió.
    @State private var quickBeforeEdit: QuickValues?
    @State private var saveAsQuick = false
    /// Gasto creado por doble toque, mientras el toast de deshacer sigue vivo.
    @State private var undoTarget: Expense?
    @State private var pendingDismissToken = UUID()
    @State private var editingQuick: QuickExpense?
    /// Dos destinos de foco: el monto abre el teclado numérico del sistema y
    /// los campos de texto el normal. Antes era un solo `Bool` que sólo servía
    /// para esconder el teclado propio.
    private enum Field: Hashable { case amount, text }
    @FocusState private var focused: Field?

    init(transactionType: TransactionType = .gasto) {
        _draft = State(initialValue: Self.blankDraft(transactionType))
    }

    /// La categoría empieza vacía («Toca para elegir»): que el gasto caiga en
    /// «Otros» sin que nadie lo decida llenaba esa categoría de ruido.
    private static func blankDraft(_ type: TransactionType) -> TransactionDraft {
        var draft = TransactionDraft(type: type)
        draft.category = ""
        return draft
    }

    /// Desde un enlace `agrupay://` (widget o Atajos): ingreso con la fuente
    /// ya elegida, o un gasto rápido que se registra al abrir con la opción de
    /// deshacer — el mismo camino que el doble toque.
    init(transactionType: TransactionType, source: String?, savingQuick quickID: UUID?,
         isLockedEntry: Bool = false) {
        var draft = Self.blankDraft(transactionType)
        if let source { draft.source = source }
        _draft = State(initialValue: draft)
        _pendingQuickSave = State(initialValue: quickID)
        self.isLockedEntry = isLockedEntry
    }

    /// Abierto desde el widget con la app bloqueada: se anota, pero no se
    /// enseña nada de los demás —los cobros pendientes llevan nombres y montos
    /// de amigos—, que eso sigue detrás de Face ID.
    private var isLockedEntry = false

    /// Gasto rápido por registrar al aparecer. Se consume una sola vez.
    @State private var pendingQuickSave: UUID?
    /// La categoría que puso la app («la de siempre» de ese comercio): si se
    /// guarda tal cual, cuenta como sugerida y no como elegida.
    @State private var prefilledCategory: String?

    /// Cobro de una deuda concreta, abierto desde "Estado del cobro" en el
    /// detalle del gasto: ingreso, marcado como abono, con esa deuda elegida y
    /// su moneda. Sólo queda escribir el monto.
    init(collecting debt: Expense) {
        var draft = TransactionDraft(type: .ingreso)
        draft.isDebtPayment = true
        draft.currency = debt.currency
        draft.selectDebt(debt)
        _draft = State(initialValue: draft)
    }

    // MARK: - Colores

    private var palette: Palette { Palette(scheme) }
    private var themeAccent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }

    /// Verde de relleno para ingreso: `#30D158` no llega a 4.5:1 con texto blanco.
    private static let incomeFill = Color(red: 0.141, green: 0.541, blue: 0.239)   // #248A3D

    private var accentFill: Color {
        draft.type == .gasto ? themeAccent.buttonFill : Self.incomeFill
    }

    /// El texto sobre `accentFill`: tinta oscura sobre los acentos claros.
    private var onAccentFill: Color {
        draft.type == .gasto ? themeAccent.buttonText : .white
    }

    private var accentText: Color {
        draft.type == .gasto
            ? themeAccent.onSurface(scheme)
            : (scheme == .dark ? Color(red: 0.188, green: 0.820, blue: 0.345)
                               : Color(red: 0.114, green: 0.498, blue: 0.235))
    }

    // MARK: - Cuerpo

    /// Lo mínimo a la vista: monto, tres cápsulas (de dónde, gasto o ingreso,
    /// cuándo), «+ Detalle» para título y descripción, y la categoría. Todo lo
    /// demás —repetir, guardar como atajo— vive dentro de Detalle.
    var body: some View {
        trackedBody.trackScreen("add_movement")
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        VStack(spacing: 0) {
            topBar
            amountHero

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    capsuleRow
                    detailRow

                    // Los atajos sólo mientras no hay monto (`4b`): son una
                    // forma de rellenar; con el monto escrito sobran.
                    if draft.type == .gasto && !draft.hasAmount {
                        quickExpenseRow
                    }

                    if draft.type == .gasto {
                        categoryCard
                    } else {
                        incomeFields
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)

            primaryButton
        }
        .background(palette.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(palette.background)
        // Con datos escritos no se descarta de un arrastre; para salir hay que
        // usar la X, que sí pregunta.
        .interactiveDismissDisabled(draft.hasAmount)
        .confirmationDialog("¿Descartar este movimiento?",
                            isPresented: $showDiscardDialog,
                            titleVisibility: .visible) {
            Button("Descartar movimiento", role: .destructive) { dismiss() }
            Button("Seguir editando", role: .cancel) {}
        }
        .onAppear {
            guard let id = pendingQuickSave else { return }
            pendingQuickSave = nil
            if let quick = quickExpenses.first(where: { $0.id == id }) {
                saveImmediately(quick)
            }
        }
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
        .sheet(isPresented: $showAllCategories) {
            // Bloqueada: sólo los nombres. La hoja completa enseña el saldo de
            // cada límite y deja editar o borrar categorías.
            if isLockedEntry { lockedCategorySheet } else { categoryListSheet }
        }
        .sheet(isPresented: $showDebtPicker) { debtPickerSheet }
        .sheet(isPresented: $showSourcePicker) { sourcePickerSheet }
        .sheet(isPresented: $showDetail, onDismiss: suggestCategoryFromTitle) { detailSheet }
        .sheet(isPresented: $showQuickEditor) {
            QuickExpenseEditor(quick: editingQuick)
        }
        // Sin barra «Listo» sobre el teclado: el botón de registrar ya queda
        // encima del `.decimalPad`, y en iOS 26 esa barra flota justo sobre
        // él y se come los toques. El teclado se cierra deslizando la lista.
        .onAppear(perform: preselectSingleDebt)
        .task {
            // El foco inicial va al monto, que es lo primero que se escribe.
            // Con un respiro: puesto en `onAppear`, la hoja todavía se está
            // presentando y iOS descarta la petición.
            try? await Task.sleep(nanoseconds: 350_000_000)
            focused = .amount
        }
    }

    // MARK: - 1. Barra superior

    /// Cerrar a la izquierda y la moneda a la derecha. El tipo ya no va aquí:
    /// es la cápsula del medio.
    private var topBar: some View {
        HStack {
            Button {
                if draft.hasAmount { showDiscardDialog = true } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .frame(width: 44, height: 44)
                    .background(palette.surface, in: Circle())
                    .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")

            Spacer()

            currencyPicker
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    // MARK: - 2. Monto

    /// Sin rótulo «Monto del gasto»: el número grande ya dice qué es, y la
    /// cápsula de tipo dice si entra o sale.
    private var amountHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            amountRow

            if case .invalid(let message) = draft.validation {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(palette.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Todo lo que se teclea pasa por el saneador: el `.decimalPad` del sistema
    /// no puede validar tecla a tecla como hacía el teclado propio.
    private var amountBinding: Binding<String> {
        Binding(get: { draft.amountText },
                set: { draft.amountText = TransactionDraft.sanitizedAmount($0) })
    }

    private var amountLabel: String {
        if draft.type == .ingreso && draft.isDebtPayment { return "Monto del cobro" }
        return draft.type == .gasto ? "Monto del gasto" : "Monto del ingreso"
    }

    private var isInvalid: Bool {
        if case .invalid = draft.validation { return true }
        return false
    }

    /// El número y, detrás, la moneda: «120 S/» como en el diseño.
    private var amountRow: some View {
        let amountColor: Color = isInvalid ? palette.negative
            : (draft.amountText.isEmpty ? palette.tertiaryLabel : palette.label)

        let font = Font.system(size: amountFontSize, weight: .bold, design: .rounded)

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // El ancho lo da un `Text` invisible con lo escrito, y el campo se
            // monta encima. Antes el campo medía lo que el «0» de ejemplo y
            // `minimumScaleFactor` encogía el número al escribir para que
            // cupiera ahí: el 0 se veía grande y el 42.5, pequeño.
            ZStack(alignment: .leading) {
                Text(draft.amountText.isEmpty ? "0" : draft.amountText)
                    .font(font)
                    .lineLimit(1)
                    .padding(.trailing, 4)      // sitio para el cursor
                    .hidden()

                TextField("0", text: amountBinding)
                    .font(font)
                    .foregroundStyle(amountColor)
                    .keyboardType(.decimalPad)
                    .focused($focused, equals: .amount)
                    .lineLimit(1)
                    .accessibilityLabel(amountLabel)
            }
            .fixedSize(horizontal: true, vertical: false)
            .animation(.easeOut(duration: 0.15), value: amountFontSize)

            Text(draft.currency == "USD" ? "US$" : "S/")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(isInvalid ? palette.negative : palette.secondaryLabel)

            Spacer(minLength: 0)
        }
        .frame(height: 76)
        .contentShape(Rectangle())
        .onTapGesture { focused = .amount }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(amountLabel)
        .accessibilityValue(Money.format(draft.amount, currency: draft.currency))
    }

    /// 64 pt hasta seis caracteres («1234.5»); desde ahí baja de a poco para
    /// que un monto largo («123456789.99») siga cabiendo con su moneda. Es el
    /// mismo tamaño para el número y para el `Text` que le da el ancho, así
    /// que nunca se reescala a medias.
    private var amountFontSize: CGFloat {
        let count = max(draft.amountText.count, 1)
        return count <= 6 ? 64 : max(38, 64 - CGFloat(count - 6) * 5)
    }

    /// Sólo hay dos monedas: un segmentado de 26 pt en vez del `Picker` de rueda
    /// de 80 pt que ocupaba el modal anterior.
    private var currencyPicker: some View {
        HStack(spacing: 0) {
            currencyOption("S/", value: "PEN")
            currencyOption("US$", value: "USD")
        }
        .padding(2)
        .background(palette.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    private func currencyOption(_ label: String, value: String) -> some View {
        let selected = draft.currency == value
        return Button {
            // No se convierte el monto: el número escrito es el de esa moneda.
            withAnimation(.easeInOut(duration: 0.15)) { draft.currency = value }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? onAccentFill : palette.secondaryLabel)
                .frame(width: 50, height: 32)
                .background(Capsule().fill(selected ? accentFill : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 3. Cápsulas

    /// De dónde · gasto o ingreso · cuándo. Cada una es un toque.
    private var capsuleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { showSourcePicker = true } label: {
                    capsule {
                        sourceIcon(Self.source(named: draft.source), size: 22)
                        Text(draft.source)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel((draft.type == .gasto ? "Pagado con " : "Recibido en ") + draft.source)

                Button(action: toggleType) {
                    capsule {
                        Image(systemName: draft.type == .gasto ? "arrow.down.right" : "arrow.up.right")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(draft.type == .gasto ? palette.negative : accentText)
                        Text(draft.type == .gasto ? "Gasto" : "Ingreso")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draft.type == .gasto ? "Gasto" : "Ingreso")
                .accessibilityHint("Toca para cambiar entre gasto e ingreso")

                Button { showDatePicker = true } label: {
                    capsule {
                        Image(systemName: "calendar")
                            .font(.system(size: 17))
                            .foregroundStyle(palette.secondaryLabel)
                        Text(capsuleDateLabel)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fecha: " + dateLabel)
            }
            .padding(.horizontal, 16)
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(palette.label)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    /// Gasto ⇄ ingreso sin cerrar la hoja. Lo que sólo vale para uno de los
    /// dos se limpia al cambiar: un cobro de deuda no sobrevive a pasar a gasto.
    private func toggleType() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if draft.type == .gasto {
                draft.type = .ingreso
                // El título es uno solo en pantalla: viaja de un tipo al otro.
                if draft.title.isEmpty { draft.title = draft.merchant }
            } else {
                draft.type = .gasto
                draft.isDebtPayment = false
                draft.selectDebt(nil)
                if draft.merchant.isEmpty { draft.merchant = draft.title }
            }
            activeQuickID = nil
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// «Hoy», «Ayer» o «20 set»: lo justo para una cápsula.
    private var capsuleDateLabel: String {
        if isSameDay(draft.date, Date()) { return "Hoy" }
        if isSameDay(draft.date, yesterday) { return "Ayer" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        return f.string(from: draft.date).replacingOccurrences(of: ".", with: "")
    }

    // MARK: - 4. Detalle

    /// El título que se ve y se edita: el comercio en un gasto, el título en un
    /// ingreso.
    private var titleBinding: Binding<String> {
        draft.type == .gasto ? $draft.merchant : $draft.title
    }

    /// «+ Detalle» mientras no haya nada; con título o descripción, su resumen
    /// para ver lo escrito sin abrirlo.
    @ViewBuilder
    private var detailRow: some View {
        let title = titleBinding.wrappedValue.trimmed
        let notes = draft.notes.trimmed

        Button { showDetail = true } label: {
            if title.isEmpty && notes.isEmpty && !recurrence.repeats {
                Text("+ Detalle")
                    .font(.system(size: 17))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title.isEmpty ? "Sin título" : title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(title.isEmpty ? palette.secondaryLabel : palette.label)
                            .lineLimit(1)
                        if !notes.isEmpty {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(palette.secondaryLabel)
                                .lineLimit(2)
                        }
                        if recurrence.repeats {
                            Label(recurrence.label(merchant: draft.merchant, amount: draft.amount, currency: draft.currency),
                                  systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accentText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityLabel(title.isEmpty && notes.isEmpty ? "Añadir detalle" : "Editar detalle")
    }

    /// Título y descripción; en un gasto, también Repetir y Guardar como atajo.
    private var detailSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(draft.type == .gasto ? "Título (dónde, qué)" : "Título (Sueldo, venta…)",
                              text: titleBinding)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    TextField("Descripción", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)
                } footer: {
                    Text(draft.type == .gasto
                         ? "Opcional. Sin título, el gasto se llama como su categoría."
                         : "Opcional.")
                }

                // Los comercios frecuentes que coinciden con lo escrito: tocar
                // uno lo completa y trae su categoría de siempre.
                if draft.type == .gasto && !merchantSuggestions.isEmpty {
                    Section("Frecuentes") {
                        ForEach(merchantSuggestions, id: \.self) { name in
                            Button { pickMerchant(name) } label: {
                                Text(Accounting.displayName(name))
                                    .foregroundStyle(palette.label)
                            }
                        }
                    }
                }

                if draft.type == .gasto, let quick = activeQuick {
                    Section {
                        activeQuickRow(quick)
                            .listRowInsets(EdgeInsets())
                    } footer: {
                        Text("Monto, moneda y categoría del atajo. Lo que cambies vale para este gasto y los próximos.")
                    }
                }

                if draft.type == .gasto {
                    Section {
                        repeatRow
                            .listRowInsets(EdgeInsets())
                        if canSaveAsQuick {
                            saveAsQuickRow
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .navigationTitle("Detalle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { showDetail = false }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showRecurrenceSheet) {
                RecurrenceSheet(draft: $recurrence,
                                merchant: draft.merchant,
                                amount: draft.amount,
                                currency: draft.currency)
            }
            .sheet(item: $editingActiveQuick, onDismiss: carryQuickEdits) { quick in
                QuickExpenseEditor(quick: quick)
            }
        }
        .tint(accentText)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// Al cerrar Detalle con un título conocido y sin categoría todavía, se
    /// rellena la de siempre: la misma sugerencia que antes daba el campo de
    /// comercio mientras se escribía.
    private func suggestCategoryFromTitle() {
        guard draft.type == .gasto, draft.category.trimmed.isEmpty, !isLockedEntry else { return }
        let title = draft.merchant.trimmed
        guard !title.isEmpty else { return }
        let match = history.first {
            Accounting.displayName($0.merchant).caseInsensitiveCompare(title) == .orderedSame
        }?.merchant ?? title
        if let usual = usualCategory(for: match) {
            withAnimation(.easeInOut(duration: 0.2)) { draft.category = usual }
            prefilledCategory = usual
        }
    }

    // MARK: - 5. Categoría

    private var categoryCard: some View {
        let category = draft.category.trimmed
        let hasCategory = !category.isEmpty
        let color = hasCategory ? CategoryStyle.color(for: category, accent: themeAccent.color) : palette.secondaryLabel

        return VStack(alignment: .leading, spacing: 8) {
            Button { showAllCategories = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: hasCategory ? CategoryStyle.icon(for: category) : "tray")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(color)
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Categoría")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.label)
                        Text(hasCategory ? category : "Opcional · sin ella queda en Pendientes")
                            .font(.subheadline)
                            .foregroundStyle(hasCategory ? color : palette.secondaryLabel)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 68)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)

            // Por qué se eligió sola: sin esta línea parecía un error.
            if let reason = suggestionReason {
                Label(reason, systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 6. Fuente

    /// Efectivo, Yape, Plin, Transferencia u Otro. En un gasto es con qué
    /// pagaste; en un ingreso, dónde te llegó.
    private var sourcePickerSheet: some View {
        NavigationStack {
            List(Self.sources, id: \.name) { source in
                Button {
                    draft.source = source.name
                    showSourcePicker = false
                } label: {
                    HStack(spacing: 12) {
                        sourceIcon(source, size: 30)
                        Text(source.name)
                            .foregroundStyle(palette.label)
                        Spacer()
                        if draft.source == source.name {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(accentText)
                        }
                    }
                }
                .accessibilityAddTraits(draft.source == source.name ? [.isSelected] : [])
            }
            .navigationTitle(draft.type == .gasto ? "¿Con qué pagaste?" : "¿Dónde te llegó?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { showSourcePicker = false }
                }
            }
        }
        .tint(accentText)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private static func source(named name: String) -> SourceOption {
        sources.first { $0.name == name } ?? SourceOption(name: name, symbol: "ellipsis.circle", asset: nil)
    }

    @ViewBuilder
    private func sourceIcon(_ source: SourceOption, size: CGFloat) -> some View {
        if let asset = source.asset {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: source.symbol ?? "ellipsis.circle")
                .font(.system(size: size * 0.62))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: size, height: size)
        }
    }

    private struct SourceOption {
        let name: String
        let symbol: String?
        let asset: String?
    }

    private static let sources: [SourceOption] = [
        SourceOption(name: "Efectivo", symbol: "banknote", asset: nil),
        SourceOption(name: "Yape", symbol: nil, asset: "yape_icon"),
        SourceOption(name: "Plin", symbol: nil, asset: "plin_icon"),
        SourceOption(name: "Transferencia", symbol: "building.columns", asset: nil),
        SourceOption(name: "Otro", symbol: "ellipsis.circle", asset: nil)
    ]
    // MARK: - Atajos

    @ViewBuilder
    private var quickExpenseRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ATAJOS")
                    .font(.caption)
                    .tracking(0.3)
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                if !quickExpenses.isEmpty {
                    Button("Editar") {
                        editingQuick = nil
                        showQuickEditor = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accentText)
                }
            }
            .padding(.horizontal, 16)

            if quickExpenses.isEmpty {
                emptyQuickCard
            } else {
                chipRow {
                    ForEach(quickExpenses.prefix(3)) { quick in
                        quickCard(quick)
                    }
                    addQuickButton
                }

                Text("Un toque rellena · dos toques guardan")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func quickCard(_ quick: QuickExpense) -> some View {
        let active = activeQuickID == quick.id

        return VStack(alignment: .leading, spacing: 4) {
            quickIcon(quick)
            Text(quick.label)
                .font(.caption.bold())
                .foregroundStyle(palette.label)
                .lineLimit(1)
            Text(Money.format(quick.amount, currency: quick.currency))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(width: 88, height: 62, alignment: .leading)
        .background(active ? accentFill.opacity(0.2) : palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active ? accentFill.opacity(0.6) : palette.hairline, lineWidth: active ? 1 : 0.5)
        )
        .contentShape(Rectangle())
        // El orden importa: el doble toque debe reconocerse antes que el simple.
        .onTapGesture(count: 2) { saveImmediately(quick) }
        .onTapGesture { apply(quick) }
        .onLongPressGesture {
            editingQuick = quick
            showQuickEditor = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(quick.label + ", " + Money.format(quick.amount, currency: quick.currency))
        .accessibilityHint("Toca para rellenar, toca dos veces para guardar")
    }

    @ViewBuilder
    private func quickIcon(_ quick: QuickExpense) -> some View {
        if quick.iconName == "yape" || quick.iconName == "plin" {
            Image(quick.iconName + "_icon")
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: quick.iconName)
                .font(.system(size: 18))
                .foregroundStyle(accentText)
        }
    }

    private var addQuickButton: some View {
        Button {
            editingQuick = nil
            showQuickEditor = true
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: 56, height: 62)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Añadir atajo")
    }

    private var emptyQuickCard: some View {
        Button {
            editingQuick = nil
            showQuickEditor = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Crea un atajo para lo que pagas en efectivo")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Text("El pasaje de S/ 2.50 en un toque")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.label)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }

    /// Un toque: rellena y espera confirmación. Dos toques en total.
    private func apply(_ quick: QuickExpense) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draft.amountText = String(format: "%.2f", quick.amount)
            draft.currency = quick.currency
            draft.merchant = quick.merchant
            draft.category = quick.category
            activeQuickID = quick.id
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Doble toque: el camino de un solo gesto para el pasaje diario.
    private func saveImmediately(_ quick: QuickExpense) {
        let expense = quick.makeExpense()
        modelContext.insert(expense)
        Analytics.track(.movementCreated, ["source": "quick", "kind": "expense",
                                           "category_source": "quick",
                                           "category": Analytics.categoryLabel(expense.category)])
        Analytics.milestone(.firstMovement)
        quick.useCount += 1
        quick.lastUsedAt = Date()
        try? modelContext.save()

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        undoTarget = expense
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { justSaved = true }
        scheduleDismiss()
    }

    /// Se cierra sola a los 3 s, salvo que se deshaga antes.
    private func scheduleDismiss() {
        let token = UUID()
        pendingDismissToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard pendingDismissToken == token else { return }
            dismiss()
        }
    }

    private func undoQuickSave() {
        guard let expense = undoTarget else { return }
        pendingDismissToken = UUID()          // cancela el cierre programado
        modelContext.delete(expense)
        try? modelContext.save()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            undoTarget = nil
            justSaved = false
        }
    }

    /// Los comercios más frecuentes. Tocar uno llena el campo y preselecciona la
    /// categoría que ese comercio ya tiene: el atajo que hace innecesario escribir.
    private var merchantSuggestions: [String] {
        // Con la app bloqueada, dónde sueles comprar sigue detrás de Face ID.
        guard !isLockedEntry else { return [] }
        var counts: [String: Int] = [:]
        for expense in history where !expense.merchant.isEmpty {
            counts[expense.merchant, default: 0] += 1
        }
        let typed = draft.merchant.trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                                   locale: Locale(identifier: "es_PE"))
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
            .filter { name in
                guard !typed.isEmpty else { return true }
                let clean = Accounting.displayName(name)
                    .folding(options: [.diacriticInsensitive, .caseInsensitive],
                             locale: Locale(identifier: "es_PE"))
                return clean.contains(typed) && clean != typed
            }
            .prefix(4)
            .map { $0 }
    }

    private func pickMerchant(_ name: String) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draft.merchant = Accounting.displayName(name)
            if let usual = usualCategory(for: name) {
                draft.category = usual
                prefilledCategory = usual
            }
        }
    }

    private func usualCategory(for merchant: String) -> String? {
        if let rule = MerchantRules.category(for: merchant) { return rule }
        var counts: [String: Int] = [:]
        for expense in history where expense.merchant == merchant && expense.category != Accounting.unclassified {
            counts[expense.category, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Por qué hay una categoría preseleccionada. Sin esta línea el chip se
    /// encendía solo, sin motivo visible, y parecía un error.
    private var suggestionReason: String? {
        let merchant = draft.merchant.trimmed
        let category = draft.category
        guard !merchant.isEmpty, !category.isEmpty, category != Accounting.unclassified,
              !isLockedEntry else { return nil }

        if MerchantRules.category(for: merchant) == category {
            return "Por tu regla para " + merchant
        }

        let count = history.filter {
            Accounting.displayName($0.merchant).caseInsensitiveCompare(merchant) == .orderedSame
                && $0.category == category
        }.count
        guard count > 0 else { return nil }
        return count == 1
            ? "Sugerida por tu compra anterior en " + merchant
            : "Sugerida por tus \(count) compras anteriores en " + merchant
    }

    /// «Hoy, 17 set», «Ayer, 16 set», o el día con su fecha.
    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        let day = f.string(from: draft.date).replacingOccurrences(of: ".", with: "")
        if isSameDay(draft.date, Date()) { return "Hoy, " + day }
        if isSameDay(draft.date, yesterday) { return "Ayer, " + day }
        f.dateFormat = "EEEE d MMM"
        return f.string(from: draft.date).replacingOccurrences(of: ".", with: "").capitalizedFirst
    }

    private var yesterday: Date {
        Period.calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    private func isSameDay(_ a: Date, _ b: Date) -> Bool {
        Period.calendar.isDate(a, inSameDayAs: b)
    }

    /// El toggle "Es suscripción" desaparece: sólo ponía una marca en un gasto
    /// suelto, sin programar nada ni saber cuándo tocaba el siguiente.
    /// `isSubscription` pasa a derivarse de `frequency != .never`.
    private var repeatRow: some View {
        Button { showRecurrenceSheet = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17))
                    .foregroundStyle(palette.secondaryLabel)
                Text("Repetir")
                    .foregroundStyle(palette.label)

                Spacer()

                Text(recurrence.repeats
                     ? recurrence.label(merchant: draft.merchant, amount: draft.amount, currency: draft.currency)
                     : "No se repite")
                    .foregroundStyle(recurrence.repeats ? accentText : palette.secondaryLabel)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Atajo en uso

    struct QuickValues: Equatable {
        var merchant: String
        var category: String
        var amount: Double
        var currency: String

        init(_ quick: QuickExpense) {
            merchant = quick.merchant
            category = quick.category
            amount = quick.amount
            currency = quick.currency
        }
    }

    private var activeQuick: QuickExpense? {
        activeQuickID.flatMap { id in quickExpenses.first { $0.id == id } }
    }

    /// El atajo que rellenó el gasto. Antes el lápiz de Detalle sólo dejaba
    /// cambiar título y descripción, y los montos del atajo había que ir a
    /// buscarlos a Configuración.
    private func activeQuickRow(_ quick: QuickExpense) -> some View {
        Button {
            quickBeforeEdit = QuickValues(quick)
            editingActiveQuick = quick
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(palette.secondaryLabel)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Editar atajo «" + quick.label + "»")
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(Money.format(quick.amount, currency: quick.currency) + " · " + quick.category)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Lo que cambió en el atajo pasa al gasto; lo demás se queda como el
    /// usuario lo haya dejado (un título retocado no se pisa). Si lo borró,
    /// el gasto deja de contar como hecho con él.
    private func carryQuickEdits() {
        defer { quickBeforeEdit = nil }
        guard let quick = activeQuick else {
            activeQuickID = nil
            return
        }
        guard let before = quickBeforeEdit else { return }
        let after = QuickValues(quick)
        withAnimation(.easeInOut(duration: 0.2)) {
            if after.amount != before.amount { draft.amountText = String(format: "%.2f", after.amount) }
            if after.currency != before.currency { draft.currency = after.currency }
            if after.merchant != before.merchant { draft.merchant = after.merchant }
            if after.category != before.category { draft.category = after.category }
        }
    }

    /// Sólo aparece cuando hay algo que guardar y no existe ya el mismo atajo.
    private var canSaveAsQuick: Bool {
        guard draft.hasAmount, !draft.merchant.trimmed.isEmpty else { return false }
        let cents = Money.cents(draft.amount)
        return !quickExpenses.contains {
            $0.merchant.caseInsensitiveCompare(draft.merchant.trimmed) == .orderedSame
                && Money.cents($0.amount) == cents
        }
    }

    private var saveAsQuickRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 17))
                .foregroundStyle(palette.secondaryLabel)

            VStack(alignment: .leading, spacing: 1) {
                Text("Guardar como atajo")
                    .foregroundStyle(palette.label)
                Text("Un toque la próxima vez")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer()

            Toggle("", isOn: $saveAsQuick)
                .labelsHidden()
                .tint(accentFill)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
    }

    // MARK: - 3b. Ingreso

    /// En un ingreso, la tarjeta de categoría pasa a ser «¿Es un cobro?»: es
    /// lo único que hay que decidir, y sólo si hay algo por cobrar.
    @ViewBuilder
    private var incomeFields: some View {
        if !activeDebts.isEmpty && !isLockedEntry {
            debtToggle
        }

        if draft.isDebtPayment {
            debtCard
        } else {
            explanationNote
        }
    }
    private var debtToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 17))
                .foregroundStyle(palette.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text("¿Te están devolviendo algo?")
                    .foregroundStyle(palette.label)
                Text(activeDebts.count == 1 ? "Tienes 1 cobro pendiente" : "Tienes \(activeDebts.count) cobros pendientes")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer()

            Toggle("", isOn: debtToggleBinding)
                .labelsHidden()
                .tint(accentFill)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        // Tinte de aviso: es la única decisión del formulario que cambia lo
        // que el ingreso significa, y tiene que verse distinta del resto.
        .background(palette.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.warning.opacity(0.35), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    private var debtToggleBinding: Binding<Bool> {
        Binding(
            get: { draft.isDebtPayment },
            set: { on in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    draft.isDebtPayment = on
                    if on { preselectSingleDebt() } else { draft.selectDebt(nil) }
                }
            }
        )
    }

    private func preselectSingleDebt() {
        guard draft.isDebtPayment, draft.selectedDebt == nil, activeDebts.count == 1 else { return }
        draft.selectDebt(activeDebts.first)
    }

    /// La distinción que ACCOUNTING.md §3 y §4 exigen y que ninguna pantalla
    /// explicaba: por qué un abono no aparece en el balance.
    private var explanationNote: some View {
        Text(activeDebts.isEmpty || isLockedEntry
             ? "Un ingreso normal cuenta en tu balance. Un cobro no: sólo reduce lo que te deben."
             : "Al activarlo, el monto se abona a una deuda y deja de contar como ingreso del mes.")
            .font(.footnote)
            .foregroundStyle(palette.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    // MARK: - 3c. Tarjeta de abono a deuda

    @ViewBuilder
    private var debtCard: some View {
        VStack(spacing: 0) {
            debtChooserRow

            if draft.selectedDebt != nil {
                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 14)
                balanceRow
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)

        if draft.cancelsDebt, let debt = draft.selectedDebt {
            cancelBanner(debt)
        }
    }

    private var debtChooserRow: some View {
        Button { showDebtPicker = true } label: {
            HStack(spacing: 12) {
                if let debt = draft.selectedDebt {
                    debtIcon(debt)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Accounting.displayName(debt.merchant))
                            .font(.headline)
                            .foregroundStyle(palette.label)
                            .lineLimit(1)
                        Text(debtSubtitle(debt))
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 19))
                        .foregroundStyle(palette.warning)
                    Text("Elige qué te están devolviendo")
                        .foregroundStyle(palette.label)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func debtIcon(_ debt: Expense) -> some View {
        let color = CategoryStyle.color(for: debt.category, accent: themeAccent.color)
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.2))
                .frame(width: 40, height: 40)
            Image(systemName: CategoryStyle.icon(for: debt.category))
                .foregroundStyle(color)
        }
    }

    private func debtSubtitle(_ debt: Expense) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        return "Por cobrar del " + f.string(from: debt.date) + " · "
            + Money.format(debt.amount, currency: debt.currency) + " original"
    }

    /// Saldo actual → lo que quedaría, con "Saldar" a la derecha para marcar
    /// que este abono cierra la deuda aunque no cubra el saldo completo. Antes
    /// había tres atajos para el monto ("Todo el saldo"/"Mitad"/"Otro monto");
    /// el monto ya se escribe arriba con el teclado, así que sólo hacía falta
    /// una forma de decir "esto es lo último que va a pagar".
    private var balanceRow: some View {
        let remainder = draft.cancelsDebt ? 0 : (draft.debtRemainder ?? 0)
        let currency = draft.selectedDebt?.currency ?? draft.currency

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Te deben")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                Text(Money.format(draft.debtOutstanding ?? 0, currency: currency))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 20))
                .foregroundStyle(palette.secondaryLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text("Queda")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                Text(Money.format(remainder, currency: currency))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Money.isZero(remainder) ? palette.positive : palette.label)
            }

            Spacer(minLength: 0)

            settleToggle
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    /// Se apaga solo cuando el abono ya cubre el saldo completo: forzarlo ahí
    /// no cambiaría nada, así que se muestra marcado pero sin poder tocarse.
    private var debtIsNaturallySettled: Bool { Money.isZero(draft.debtRemainder ?? 0) }

    private var settleToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { draft.forceCancelsDebt.toggle() }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(draft.cancelsDebt ? palette.positive : palette.secondaryLabel.opacity(0.6), lineWidth: 1.6)
                        .background(Circle().fill(draft.cancelsDebt ? palette.positive : Color.clear))
                        .frame(width: 24, height: 24)
                    if draft.cancelsDebt {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                Text("Saldar")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .buttonStyle(.plain)
        .disabled(debtIsNaturallySettled)
        .opacity(debtIsNaturallySettled ? 0.5 : 1)
    }

    private func cancelBanner(_ debt: Expense) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.positive)
            Text("Con esto queda saldado. " + Accounting.displayName(debt.merchant)
                 + " deja de estar por cobrar.")
                .font(.footnote)
                .foregroundStyle(palette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(palette.positive.opacity(scheme == .dark ? 0.16 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - 7. Botón principal

    @ViewBuilder
    private var primaryButton: some View {
        if undoTarget != nil {
            undoBar
        } else {
            standardButton
        }
    }

    /// Tras el doble toque en un atajo, el gasto ya está guardado; esto da los
    /// segundos para arrepentirse antes de que el modal se cierre solo.
    private var undoBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(palette.positive)
            Text("Guardado")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.label)
            Spacer()
            Button("Deshacer") { undoQuickSave() }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accentText)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var standardButton: some View {
        Button(action: save) {
            buttonLabel
        }
        .buttonStyle(.plain)
        .disabled(!draft.validation.isReady || justSaved)
        .accessibilityLabel(buttonAccessibilityLabel)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(palette.background)
    }

    private var blockedReason: String? {
        switch draft.validation {
        case .ready: return nil
        case .blocked(let reason): return reason
        case .invalid(let error): return error
        }
    }

    private var buttonAccessibilityLabel: String {
        blockedReason ?? draft.actionTitle
    }

    /// El texto del botón deshabilitado, legible sobre `palette.track`.
    ///
    /// La razón de que falte algo se decía dos veces —dentro del botón y en una
    /// línea debajo— porque `tertiaryLabel` sobre `#E3E3E8` da 3.1:1 y no cumple
    /// AA. Se arregla oscureciendo el texto (5.4:1) en vez de repetirlo: la
    /// línea de abajo comía altura para no decir nada nuevo.
    private var disabledTextColor: Color {
        scheme == .dark
            ? palette.secondaryLabel
            : Color(red: 0.353, green: 0.353, blue: 0.369)   // #5A5A5E
    }

    @ViewBuilder
    private var buttonLabel: some View {
        let ready = draft.validation.isReady

        HStack(spacing: 8) {
            if justSaved {
                Image(systemName: "checkmark")
                    .symbolEffect(.bounce, value: justSaved)
            }
            Text(justSaved ? "Guardado" : (blockedReason ?? draft.actionTitle))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.headline)
        .foregroundStyle(ready || justSaved ? onAccentFill : disabledTextColor)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(ready || justSaved ? accentFill : palette.track)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: ready ? accentFill.opacity(0.35) : .clear, radius: 18, y: 6)
    }

    private func save() {
        guard draft.validation.isReady else { return }

        if draft.type == .gasto {
            // `isSubscription` ya no se marca a mano: se deriva de la recurrencia.
            draft.isSubscription = recurrence.repeats
            guard let expense = draft.makeExpense() else { return }
            modelContext.insert(expense)
            let categorySource = expense.category == Accounting.unclassified ? "none"
                : (expense.category == prefilledCategory ? "prefilled" : "user")
            Analytics.track(.movementCreated, ["source": isLockedEntry ? "form_locked" : "form",
                                               "kind": "expense",
                                               "category_source": categorySource,
                                               "category": Analytics.categoryLabel(expense.category),
                                               "recurring": recurrence.repeats,
                                               "saved_quick": saveAsQuick,
                                               "used_quick": activeQuickID != nil])

            if let rule = recurrence.build(merchant: expense.merchant,
                                           category: expense.category,
                                           amount: expense.amount,
                                           currency: expense.currency) {
                // El gasto de hoy ya está registrado: la regla arranca marcando
                // esta fecha como resuelta para no proponerla otra vez.
                rule.lastResolvedOccurrence = expense.date
                modelContext.insert(rule)
            }

            if saveAsQuick {
                let quick = QuickExpense(
                    label: Accounting.displayName(expense.merchant),
                    merchant: expense.merchant,
                    category: expense.category,
                    amount: expense.amount,
                    currency: expense.currency,
                    iconName: CategoryStyle.icon(for: expense.category),
                    sortIndex: (quickExpenses.map(\.sortIndex).max() ?? -1) + 1
                )
                modelContext.insert(quick)
            }

            if let id = activeQuickID, let used = quickExpenses.first(where: { $0.id == id }) {
                used.useCount += 1
                used.lastUsedAt = Date()
            }
            // Sin guardar regla de comercio: elegir una categoría para un gasto
            // suelto no debería reescribir la que el usuario fijó en la Bandeja.
            // Para eso está la Bandeja.
        } else {
            // Una sola resolución: el ingreso y la decisión de saldar salen
            // juntos y **antes** de tocar la deuda. Aquí se leía
            // `draft.cancelsDebt` después de crear el ingreso, cuando el saldo
            // ya descontaba ese mismo abono: la deuda se daba por saldada con
            // un abono parcial. Ver `TransactionDraft.Resolution`.
            guard let resolution = draft.resolveIncome() else { return }
            let income = resolution.income
            modelContext.insert(income)
            Analytics.track(.movementCreated, ["source": isLockedEntry ? "form_locked" : "form",
                                               "kind": "income",
                                               "pays_debt": resolution.debt != nil])
            // El vínculo se anota por la huella del gasto, no sólo por la
            // relación de SwiftData: esa relación se rompe cada vez que el
            // gasto se rearma desde el correo.
            if let debt = resolution.debt {
                IncomeLinkStore.record(income: income, expense: debt, isFinal: resolution.cancelsDebt)
            }
            // `isFinalDebtPayment` se deduce del saldo, no de un toggle: el
            // anterior permitía cerrar una deuda con un abono parcial.
            if resolution.cancelsDebt, let debt = resolution.debt {
                debt.isDebt = false
                // Saldarlo es una decisión del usuario sobre un gasto del
                // correo: sin anotarla, la relectura lo devuelve a "por cobrar".
                ExpenseEditStore.record(debt, isDebt: false)
            }
        }
        try? modelContext.save()
        Analytics.milestone(.firstMovement)

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { justSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
    }

    // MARK: - Sheets auxiliares

    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Fecha", selection: $draft.date, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("Fecha")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") { showDatePicker = false }
                    }
                }
        }
        .presentationDetents([.fraction(0.55)])
        .presentationDragIndicator(.visible)
    }

    /// El chip "…" abre `6a`, el mismo sheet que la Bandeja y el detalle: aquí
    /// también hace falta ver el saldo del límite antes de elegir, y aquí
    /// también conviene poder crear la regla del comercio de una vez.
    ///
    /// El gasto todavía no existe, así que la cabecera muestra el borrador y el
    /// interruptor de regla sólo aparece si ya hay comercio escrito.
    private var categoryListSheet: some View {
        AssignCategorySheet(context: .draft(merchant: draft.merchant,
                                            amount: draft.amount,
                                            currency: draft.currency,
                                            current: draft.category),
                            history: history,
                            onClear: { draft.category = "" }) { category, createRule in
            draft.category = category
            if createRule {
                MerchantRules.set(category, for: draft.merchant.trimmed)
                Analytics.ruleCreated(origin: "add_form")
            }
            showAllCategories = false
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// La lista de categorías del registro rápido con la app bloqueada:
    /// alfabética (el orden por uso diría en qué gastas más), sin montos ni
    /// edición.
    private var lockedCategorySheet: some View {
        NavigationStack {
            List(CategoryStyle.alphabetical(history: []), id: \.self) { name in
                Button {
                    draft.category = name
                    showAllCategories = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: CategoryStyle.icon(for: name))
                            .foregroundStyle(CategoryStyle.color(for: name, accent: themeAccent.color))
                            .frame(width: 30)
                        Text(name)
                            .foregroundStyle(palette.label)
                        Spacer()
                        if draft.category == name {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(accentText)
                        }
                    }
                }
                .accessibilityAddTraits(draft.category == name ? [.isSelected] : [])
            }
            .navigationTitle("Categoría")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { showAllCategories = false }
                }
                if !draft.category.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Quitar") {
                            draft.category = ""
                            showAllCategories = false
                        }
                    }
                }
            }
        }
        .tint(accentText)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var debtPickerSheet: some View {
        NavigationStack {
            List(activeDebts) { debt in
                Button {
                    draft.selectDebt(debt)
                    draft.currency = debt.currency
                    showDebtPicker = false
                } label: {
                    HStack(spacing: 12) {
                        debtIcon(debt)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Accounting.displayName(debt.merchant))
                                .foregroundStyle(palette.label)
                            Text("saldo " + Money.format(Accounting.outstanding(of: debt), currency: debt.currency))
                                .font(.caption)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        Spacer()
                        if draft.selectedDebt?.id == debt.id {
                            Image(systemName: "checkmark").foregroundStyle(accentText)
                        }
                    }
                }
            }
            .navigationTitle("Pendientes de cobro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { showDebtPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Piezas compartidas

    private func chipRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Teclado numérico

