import SwiftUI
import SwiftData

/// Crear o editar un atajo.
///
/// Con `quick == nil` crea uno nuevo y, si el historial lo permite, ofrece los
/// montos que el usuario ya repite —`QuickExpense.suggestions`— en vez de pedirle
/// que los escriba. Sugerir no es crear: la app propone, el usuario acepta.
struct QuickExpenseEditor: View {

    let quick: QuickExpense?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Query(sort: \Expense.date, order: .reverse) private var history: [Expense]
    @Query(sort: \QuickExpense.sortIndex) private var existing: [QuickExpense]

    @State private var label = ""
    @State private var merchant = ""
    @State private var category = CategoryStyle.fallback
    @State private var amountText = ""
    @State private var currency = "PEN"
    @State private var showDeleteDialog = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }
    private var amount: Double { Money.parse(amountText) ?? 0 }
    private var isValid: Bool { Money.cents(amount) > 0 && !merchant.trimmed.isEmpty && !label.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if quick == nil, !suggestions.isEmpty {
                    Section("Sugerencias") {
                        ForEach(suggestions, id: \.merchant) { suggestion in
                            Button {
                                fill(from: suggestion)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Accounting.displayName(suggestion.merchant))
                                            .foregroundStyle(palette.label)
                                        Text("lo registraste \(suggestion.count) veces por el mismo monto")
                                            .font(.caption)
                                            .foregroundStyle(palette.secondaryLabel)
                                    }
                                    Spacer()
                                    Text(Money.format(suggestion.amount))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.label)
                                }
                            }
                        }
                    }
                }

                Section("Atajo") {
                    TextField("Nombre corto (Pasaje)", text: $label)
                        .textInputAutocapitalization(.sentences)
                    TextField("Comercio", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    HStack {
                        Text(Money.symbol(for: currency))
                            .foregroundStyle(.secondary)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                    Picker("Moneda", selection: $currency) {
                        Text("Soles").tag("PEN")
                        Text("Dólares").tag("USD")
                    }
                }

                Section("Categoría") {
                    Picker("Categoría", selection: $category) {
                        ForEach(CategoryStyle.selectable(history: history), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                if quick != nil {
                    Section {
                        Button(role: .destructive) { showDeleteDialog = true } label: {
                            Label("Eliminar atajo", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    } footer: {
                        Text("Los gastos ya registrados con este atajo se conservan.")
                    }
                }
            }
            .navigationTitle(quick == nil ? "Nuevo atajo" : "Editar atajo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(!isValid)
                }
            }
            // Alerta centrada, no `confirmationDialog`: dentro de la hoja el
            // diálogo se anclaba al formulario entero y aparecía arriba,
            // desfasado del botón.
            .alert("¿Eliminar este atajo?", isPresented: $showDeleteDialog) {
                Button("Eliminar", role: .destructive) { delete() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Los gastos ya registrados con este atajo se conservan.")
            }
            .onAppear(perform: load)
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var suggestions: [(merchant: String, amount: Double, category: String, count: Int)] {
        QuickExpense.suggestions(from: history).filter { suggestion in
            !existing.contains {
                $0.merchant == suggestion.merchant && Money.cents($0.amount) == Money.cents(suggestion.amount)
            }
        }
    }

    private func fill(from suggestion: (merchant: String, amount: Double, category: String, count: Int)) {
        label = Accounting.displayName(suggestion.merchant)
        merchant = suggestion.merchant
        category = suggestion.category
        amountText = String(format: "%.2f", suggestion.amount)
    }

    private func load() {
        guard let quick else { return }
        label = quick.label
        merchant = quick.merchant
        category = quick.category
        amountText = String(format: "%.2f", quick.amount)
        currency = quick.currency
    }

    private func save() {
        guard isValid else { return }
        if let quick {
            quick.label = label.trimmed
            quick.merchant = merchant.trimmed
            quick.category = category
            quick.amount = Money.normalized(amount)
            quick.currency = currency
            quick.iconName = CategoryStyle.icon(for: category)
        } else {
            let new = QuickExpense(
                label: label.trimmed,
                merchant: merchant.trimmed,
                category: category,
                amount: amount,
                currency: currency,
                iconName: CategoryStyle.icon(for: category),
                sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1
            )
            modelContext.insert(new)
        }
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        guard let quick else { return }
        modelContext.delete(quick)
        try? modelContext.save()
        dismiss()
    }
}
