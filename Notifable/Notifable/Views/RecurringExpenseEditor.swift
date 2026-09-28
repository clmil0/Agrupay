import SwiftUI
import SwiftData

/// Editar un recurrente desde Ajustes › Recurrentes y atajos.
///
/// Mismo patrón que `QuickExpenseEditor`: los datos del gasto arriba, la
/// programación en la hoja "Repetir" de siempre (`RecurrenceSheet`), y pausar
/// y eliminar dentro del mismo modal.
struct RecurringExpenseEditor: View {

    let rule: RecurringExpense

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Query(sort: \Expense.date, order: .reverse) private var history: [Expense]

    @State private var merchant = ""
    @State private var category = CategoryStyle.fallback
    @State private var amountText = ""
    @State private var currency = "PEN"
    @State private var isPaused = false
    @State private var schedule = RecurrenceDraft()
    @State private var showSchedule = false
    @State private var showDeleteAlert = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }
    private var amount: Double { Money.parse(amountText) ?? 0 }
    private var isValid: Bool {
        Money.cents(amount) > 0 && !merchant.trimmed.isEmpty && schedule.repeats
            && (schedule.frequency != .weekly || !schedule.weekdays.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gasto") {
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
                    Picker("Categoría", selection: $category) {
                        ForEach(categoryOptions, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    Button { showSchedule = true } label: {
                        HStack {
                            Text("Repetir")
                                .foregroundStyle(palette.label)
                            Spacer()
                            Text(schedule.label(merchant: merchant, amount: amount, currency: currency))
                                .foregroundStyle(palette.secondaryLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(palette.tertiaryLabel)
                        }
                    }
                    Toggle("Pausado", isOn: $isPaused)
                        .tint(accent.color)
                } footer: {
                    if !schedule.repeats {
                        Text("Elige una frecuencia. Para dejar de repetirlo, pausa o elimina el recurrente.")
                    } else if isPaused {
                        Text("Pausado no propone ni registra nada hasta que lo reanudes.")
                    }
                }

                Section {
                    Button(role: .destructive) { showDeleteAlert = true } label: {
                        Label("Eliminar recurrente", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Los gastos ya registrados se conservan.")
                }
            }
            .navigationTitle("Editar recurrente")
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
            .sheet(isPresented: $showSchedule) {
                RecurrenceSheet(draft: $schedule, merchant: merchant, amount: amount, currency: currency)
            }
            .alert("¿Eliminar este recurrente?", isPresented: $showDeleteAlert) {
                Button("Eliminar", role: .destructive) { delete() }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se eliminará la programación. Los gastos ya registrados se conservan.")
            }
            .onAppear(perform: load)
            .appAppearance()
            .appTextSize()
        }
        // Semimodal, como el editor de atajos: se puede subir a pantalla completa.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// La categoría actual siempre está en la lista, aunque ya no tenga gastos.
    private var categoryOptions: [String] {
        let names = CategoryStyle.selectable(history: history)
        return names.contains(category) ? names : [category] + names
    }

    private func load() {
        merchant = rule.merchant
        category = rule.category
        amountText = String(format: "%.2f", rule.amount)
        currency = rule.currency
        isPaused = rule.isPaused
        schedule = RecurrenceDraft(from: rule)
    }

    private func save() {
        guard isValid else { return }
        let name = merchant.trimmed
        rule.merchant = name
        rule.category = category
        rule.amount = Money.normalized(amount)
        rule.currency = currency
        rule.isPaused = isPaused
        rule.frequency = schedule.frequency
        rule.dayOfMonth = min(max(schedule.dayOfMonth, 1), 31)
        rule.weekdays = Array(schedule.weekdays).sorted()
        rule.autoConfirm = schedule.autoConfirm
        rule.startDate = schedule.startDate
        rule.endDate = schedule.resolvedEndDate(merchant: name, category: category,
                                                amount: amount, currency: currency)
        try? modelContext.save()
        dismiss()
    }

    private func delete() {
        modelContext.delete(rule)
        try? modelContext.save()
        dismiss()
    }
}
