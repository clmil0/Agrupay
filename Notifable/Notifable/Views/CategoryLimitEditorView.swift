import SwiftUI

/// `6c` — Editar el límite.
///
/// Tres decisiones viven aquí: cuánto, cada cuánto se reinicia, y qué meses son
/// la excepción. El histórico está debajo del monto porque un límite se elige
/// mirando lo que de verdad gastas: por debajo del promedio se incumple siempre
/// y enseña a ignorar los avisos.
struct CategoryLimitEditorView: View {

    let category: String
    let color: Color
    let budget: CategoryBudget
    let history: [Expense]
    var onSave: (CategoryBudget) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage("period") private var period = Period()

    @StateObject private var rates = ExchangeRateService.shared

    /// Se edita una **copia**: "Cancelar" la descarta sin haber tocado el store.
    @State private var draft = CategoryBudget(category: "", amount: 0)
    @State private var amountText = ""
    @State private var showingAnchor = false
    @State private var showingOverride = false
    @State private var loaded = false
    @FocusState private var amountFocused: Bool

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        amountBlock
                        cycleSection
                        behaviorSection
                        overridesSection
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)

                saveButton
            }
            .background(palette.background)
            .navigationTitle("Límite de " + category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { amountFocused = false }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingAnchor) { anchorPicker }
            .sheet(isPresented: $showingOverride) { overrideEditor }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.fraction(0.82), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .onAppear(perform: load)
    }

    // MARK: - Carga y estado

    private func load() {
        guard !loaded else { return }
        loaded = true
        draft = budget
        draft.category = category
        amountText = budget.hasLimit ? trimmed(budget.amount) : ""
    }

    private func trimmed(_ value: Double) -> String {
        let cents = Money.cents(value)
        if cents % 100 == 0 { return String(cents / 100) }
        return String(format: "%.2f", Money.value(cents))
    }

    private var amount: Double { Money.normalized(Double(amountText) ?? 0) }

    private var referenceDate: Date { CategoryLimits.referenceDate(for: period) }
    private var snapshots: [ExpenseSnapshot] { history.map(\.accountingSnapshot) }

    private var average: Double? {
        CategoryLimits.average(budget: draft,
                               expenses: snapshots,
                               on: referenceDate,
                               usdToPen: rates.usdToPenRate)
    }

    // MARK: - Monto

    private var amountBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.cycle == .mes ? "LÍMITE MENSUAL" : "LÍMITE POR " + draft.cycle.label.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryLabel)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("S/")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                TextField("0", text: amountBinding)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(palette.label)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
            }

            presets

            if let average {
                Text("Tu promedio de los últimos 3 meses es " + Money.formatCompact(average) + ".")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    /// Todo lo que se teclea pasa por el mismo saneador que el alta de gastos.
    private var amountBinding: Binding<String> {
        Binding(get: { amountText },
                set: { amountText = TransactionDraft.sanitizedAmount($0) })
    }

    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(roundPresets, id: \.self) { value in
                Button { amountText = String(Int(value)) } label: {
                    presetLabel(Money.formatCompact(value).replacingOccurrences(of: "S/ ", with: ""),
                                selected: Money.cents(value) == Money.cents(amount),
                                icon: nil)
                }
                .buttonStyle(.plain)
            }

            if let average {
                let suggested = CategoryLimits.suggestedLimit(from: average)
                Button { amountText = String(Int(suggested)) } label: {
                    presetLabel("Usar " + Money.formatCompact(average).replacingOccurrences(of: "S/ ", with: ""),
                                selected: false, icon: "sparkles")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetLabel(_ text: String, selected: Bool, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.system(size: 13.5, weight: .semibold))
        }
        .foregroundStyle(selected ? accent.buttonText : (icon == nil ? palette.label : accent.onSurface(scheme)))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(selected ? AnyShapeStyle(accent.buttonFill)
                             : AnyShapeStyle(icon == nil ? palette.neutralSurface : accent.color.opacity(0.12)),
                    in: Capsule())
    }

    /// Dos valores redondos cerca del actual. Con el campo vacío, dos valores
    /// alrededor del promedio; sin promedio, dos arranques razonables.
    private var roundPresets: [Double] {
        let base = Money.cents(amount) > 0 ? amount : (average ?? 300)
        let step: Double = base >= 1000 ? 100 : 50
        let anchor = (base / step).rounded() * step
        let lower = max(step, anchor - step)
        let upper = anchor + step
        return lower == upper ? [lower] : [lower, upper]
    }

    // MARK: - Ciclo

    private var cycleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("SE REINICIA CADA")

            Picker("Ciclo", selection: cycleBinding) {
                ForEach(CategoryBudget.Cycle.allCases, id: \.self) { cycle in
                    Text(cycle.label).tag(cycle)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if draft.cycle.usesAnchorDay {
                Button { showingAnchor = true } label: {
                    HStack {
                        Text("Día de corte").foregroundStyle(palette.label)
                        Spacer()
                        Text("Día \(draft.safeAnchorDay)").foregroundStyle(palette.secondaryLabel)
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(palette.secondaryLabel)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 0.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Comportamiento

    /// Las dos decisiones que el modelo ya soportaba y ninguna pantalla
    /// ofrecía: el aviso previo y traspasar lo que sobra.
    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("CÓMO SE COMPORTA")

            VStack(spacing: 0) {
                behaviorToggle(title: "Avisarme al llegar al 80%",
                               detail: "Una sola notificación por ciclo",
                               isOn: Binding(get: { draft.alertThreshold != nil },
                                             set: { draft.alertThreshold = $0 ? 0.8 : nil }))

                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 14)

                behaviorToggle(title: "Traspasar lo que sobre",
                               detail: "Lo no gastado se suma al mes siguiente",
                               isOn: $draft.rollsOver)
            }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
            .padding(.horizontal, 16)
        }
    }

    private func behaviorToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(palette.label)
                Text(detail).font(.caption).foregroundStyle(palette.secondaryLabel)
            }
        }
        .tint(accent.color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Guardar

    private var saveButton: some View {
        Button(action: save) {
            Text(Money.cents(amount) > 0 ? "Guardar límite" : "Quitar límite")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(accent.buttonFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var cycleBinding: Binding<CategoryBudget.Cycle> {
        Binding(get: { draft.cycle }, set: { draft.cycle = $0 })
    }

    private var anchorPicker: some View {
        NavigationStack {
            List(1...28, id: \.self) { day in
                Button {
                    draft.anchorDay = day
                    showingAnchor = false
                } label: {
                    HStack {
                        Text("Día \(day)")
                        Spacer()
                        if draft.safeAnchorDay == day {
                            Image(systemName: "checkmark")
                                .foregroundStyle(accent.onSurface(scheme))
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Día de corte")
            .navigationBarTitleDisplayMode(.inline)
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium])
    }

    // MARK: - Excepciones

    private var overridesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("MESES CON OTRO LÍMITE")

            VStack(spacing: 0) {
                ForEach(sortedOverrides) { override in
                    overrideRow(override)
                    Rectangle()
                        .fill(palette.separator)
                        .frame(height: 0.5)
                        .padding(.leading, 52)
                }

                Button { showingOverride = true } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.track)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(palette.label)
                            )
                        Text("Programar otro mes")
                            .foregroundStyle(accent.onSurface(scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 16)

            if !draft.overrides.isEmpty {
                Text("Fuera de esos meses vuelve solo a " + Money.formatCompact(amount) + ".")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 22)
            }
        }
    }

    private var sortedOverrides: [CategoryBudget.Override] {
        draft.overrides.sorted { $0.month < $1.month }
    }

    private func overrideRow(_ override: CategoryBudget.Override) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.softFill(scheme))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(accent.onSurface(scheme))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(CategoryLimitEditorView.monthName(override.month))
                    .foregroundStyle(palette.label)
                Text(override.repeatsYearly ? "Se repite cada año" : "Sólo \(override.year ?? 0)")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer()

            Text(Money.formatCompact(override.amount))
                .font(.body.weight(.semibold))
                .foregroundStyle(accent.onSurface(scheme))

            Button { remove(override) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.secondaryLabel)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func remove(_ override: CategoryBudget.Override) {
        draft.overrides.removeAll { $0.id == override.id }
    }

    private var overrideEditor: some View {
        OverrideEditor(defaultAmount: amount) { override in
            draft.overrides.removeAll { $0.month == override.month && $0.year == override.year }
            draft.overrides.append(override)
        }
    }

    static func monthName(_ month: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = max(1, min(12, month))
        components.day = 1
        let date = Period.calendar.date(from: components) ?? Date()
        return Period.spanishMonthName(for: date)
    }

    // MARK: - Guardar

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(palette.secondaryLabel)
            .padding(.horizontal, 22)
    }

    private func save() {
        var result = draft
        result.category = category
        result.amount = amount
        onSave(result)
        dismiss()
    }
}

// MARK: - Histórico

// MARK: - Excepción de un mes

struct OverrideEditor: View {

    let defaultAmount: Double
    var onSave: (CategoryBudget.Override) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var month = Period.calendar.component(.month, from: Date())
    @State private var amountText = ""
    @State private var yearly = true

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mes", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(CategoryLimitEditorView.monthName(value)).tag(value)
                    }
                }

                HStack {
                    Text("Límite")
                    Spacer()
                    TextField(Money.formatCompact(defaultAmount), text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Se repite cada año", isOn: $yearly)
            }
            .navigationTitle("Otro mes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") { add() }
                        .disabled(Money.cents(Double(amountText) ?? 0) <= 0)
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.medium])
    }

    private func add() {
        let value = Money.normalized(Double(amountText) ?? 0)
        guard Money.cents(value) > 0 else { return }
        let year = yearly ? nil : Period.calendar.component(.year, from: Date())
        onSave(CategoryBudget.Override(month: month, year: year, amount: value))
        dismiss()
    }
}
