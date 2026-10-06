import SwiftUI
import SwiftData

/// "Por confirmar": las ocurrencias vencidas de las reglas recurrentes.
///
/// Nada de esto existe como `Expense` todavía, así que **no cuenta en ningún
/// total**. Es deliberado: el número grande del Resumen sólo refleja gasto real,
/// y por eso la pantalla lo dice en voz alta — si no, el usuario cree que le
/// falta dinero.
struct PendingConfirmationView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @Query private var rules: [RecurringExpense]
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

    @State private var undoStack: [Expense] = []
    @State private var showUndo = false
    @State private var expandedOccurrence: String?
    /// «Cambiar»: aceptar con otro monto (la luz que vino más cara).
    @State private var changing: PendingOccurrence?
    @State private var changedAmount = ""

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    private var occurrences: [PendingOccurrence] {
        RecurringEngine.pending(rules: rules, expenses: expenses)
    }

    private var awaiting: [PendingOccurrence] { occurrences.filter(\.isAwaiting) }

    private var awaitingTotal: Double {
        Money.sum(awaiting) { $0.totalAmount }
    }

    var body: some View {
        trackedBody.trackScreen("recurring_confirm")
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if occurrences.isEmpty {
                        ContentUnavailableView("Nada por confirmar",
                                               systemImage: "checkmark.circle.fill",
                                               description: Text("Tus gastos programados están al día."))
                            .padding(.top, 40)
                    } else {
                        header

                        ForEach(occurrences) { occurrence in
                            card(for: occurrence)
                        }

                        explanationNote
                    }
                }
                .padding(.vertical, 16)
            }
            .background(palette.background)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle("Por confirmar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .alert("¿Cuánto fue?", isPresented: changingBinding, presenting: changing) { occurrence in
                TextField("Monto", text: $changedAmount)
                    .keyboardType(.decimalPad)
                Button("Aceptar") {
                    let value = Double(TransactionDraft.sanitizedAmount(changedAmount)) ?? 0
                    if Money.cents(value) > 0 { confirm(occurrence, override: value) }
                }
                Button("Cancelar", role: .cancel) {}
            } message: { occurrence in
                Text("Se registra con este monto en vez de " + Money.format(occurrence.expectedAmount, currency: occurrence.currency) + ".")
            }
            .appAppearance()
            .appTextSize()
        }
    }

    private var changingBinding: Binding<Bool> {
        Binding(get: { changing != nil }, set: { if !$0 { changing = nil } })
    }

    // MARK: - Banner

    private var header: some View {
        let count = occurrences.reduce(0) { $0 + $1.dates.count }

        return VStack(alignment: .leading, spacing: 3) {
            Text(count == 1 ? "1 gasto programado llegó a su fecha"
                            : "\(count) gastos programados llegaron a su fecha")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryLabel)
            // La frase que evita que el usuario crea que le falta dinero.
            Text("No cuentan en tu mes hasta que los aceptes.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    // MARK: - Tarjetas

    @ViewBuilder
    private func card(for occurrence: PendingOccurrence) -> some View {
        switch occurrence.status {
        case .awaiting:
            awaitingCard(occurrence)
        case .satisfiedByBank(_, let bankAmount, let daysApart):
            bankCard(occurrence, bankAmount: bankAmount, daysApart: daysApart)
        }
    }

    /// Normal: Aceptar · Cambiar · Omitir. Con varias fechas juntas: Aceptar
    /// las N · Omitir, y la lista de días a un toque (`5i`).
    private func awaitingCard(_ occurrence: PendingOccurrence) -> some View {
        let isAccumulated = occurrence.dates.count > 1

        return VStack(alignment: .leading, spacing: 12) {
            cardHeader(occurrence, amount: occurrence.totalAmount)

            if isAccumulated {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expandedOccurrence = expandedOccurrence == occurrence.id ? nil : occurrence.id
                    }
                } label: {
                    Label(monthsLabel(occurrence) + " · " + (expandedOccurrence == occurrence.id ? "ocultar días" : "ver días"),
                          systemImage: "calendar")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }
                .buttonStyle(.plain)

                if expandedOccurrence == occurrence.id {
                    ForEach(occurrence.dates, id: \.self) { date in
                        HStack {
                            Text(longDate(date))
                            Spacer()
                            Text(Money.format(occurrence.expectedAmount, currency: occurrence.currency))
                        }
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }

            HStack(spacing: 8) {
                actionButton(isAccumulated ? "Aceptar las \(occurrence.dates.count)" : "Aceptar",
                             style: .primary) { confirm(occurrence) }
                if !isAccumulated {
                    actionButton("Cambiar", style: .secondary) {
                        changedAmount = ""
                        changing = occurrence
                    }
                }
                actionButton("Omitir", style: .secondary) { skip(occurrence) }
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func cardHeader(_ occurrence: PendingOccurrence, amount: Double) -> some View {
        HStack(spacing: 12) {
            icon(for: occurrence.category)

            VStack(alignment: .leading, spacing: 2) {
                Text(Accounting.displayName(occurrence.merchant))
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(scheduleText(occurrence))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(Money.format(amount, currency: occurrence.currency))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(palette.label)
        }
    }

    private enum ActionStyle { case primary, secondary, dark }

    private func actionButton(_ title: String, style: ActionStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(style == .secondary ? palette.label : (style == .dark ? palette.background : Color.white))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(style == .primary ? AnyShapeStyle(accent.color)
                            : style == .dark ? AnyShapeStyle(palette.label)
                            : AnyShapeStyle(palette.neutralSurface),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(style == .secondary ? palette.hairline : Color.clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// «Agosto y setiembre».
    private func monthsLabel(_ occurrence: PendingOccurrence) -> String {
        var names: [String] = []
        for date in occurrence.dates {
            let name = Period.spanishMonthName(for: date)
            if !names.contains(name) { names.append(name) }
        }
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return (names.dropLast().joined(separator: ", ") + " y " + last.lowercased()).capitalizedFirst
    }

    /// El banco ya lo cobró: aceptarlo duplicaría el gasto. La acción
    /// recomendada es descartar, y es la oscura (`5i`). Antes se reconocía
    /// sola al aparecer, sin que el usuario viera qué había pasado.
    private func bankCard(_ occurrence: PendingOccurrence, bankAmount: Double, daysApart: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(occurrence, amount: occurrence.totalAmount)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.warning)
                Text("Ya llegó del banco el " + shortDate(occurrence.dates.first ?? Date())
                     + " por " + Money.format(bankAmount, currency: occurrence.currency)
                     + ". Si lo aceptas, se duplica.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                actionButton("Aceptar igual", style: .secondary) { confirm(occurrence) }
                actionButton("Descartar", style: .dark) {
                    withAnimation { acknowledge(occurrence) }
                }
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func icon(for category: String) -> some View {
        MovementIcon(icon: CategoryStyle.icon(for: category),
                     color: CategoryStyle.color(for: category, accent: accent.color),
                     size: 40)
    }

    // MARK: - Pie

    private var explanationNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("POR QUÉ NO SE REGISTRAN SOLOS")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
            Text("El monto de un recurrente cambia (la luz de más consumo, un reajuste). Se confirma para que tu mes no se llene de cifras que nadie revisó. Si el monto nunca cambia, actívalo por regla.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if showUndo {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(palette.positive)
                Text(undoStack.count == 1 ? "1 gasto registrado" : "\(undoStack.count) gastos registrados")
                    .font(.subheadline)
                    .foregroundStyle(palette.label)
                Spacer()
                Button("Deshacer") { undo() }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent.onSurface(scheme))
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(palette.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(16)
        } else if !awaiting.isEmpty {
            Button { confirmAll() } label: {
                // El total excluye los que ya cobró el banco: «todo» es lo
                // que de verdad falta aceptar.
                Text("Confirmar todo — " + Money.format(awaitingTotal))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(accent.buttonFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(palette.background)
        }
    }

    // MARK: - Acciones

    private func rule(for occurrence: PendingOccurrence) -> RecurringExpense? {
        rules.first { $0.id == occurrence.ruleID }
    }

    private func confirm(_ occurrence: PendingOccurrence, override: Double? = nil) {
        guard let rule = rule(for: occurrence) else { return }
        let created = RecurringEngine.confirm(occurrence, rule: rule, amountOverride: override, in: modelContext)
        try? modelContext.save()
        ProHaptics.play(.confirmed)
        offerUndo(created)
    }

    private func confirmAll() {
        var created: [Expense] = []
        for occurrence in awaiting {
            guard let rule = rule(for: occurrence) else { continue }
            created += RecurringEngine.confirm(occurrence, rule: rule, in: modelContext)
        }
        try? modelContext.save()
        ProHaptics.play(.confirmed)
        offerUndo(created)
    }

    private func skip(_ occurrence: PendingOccurrence) {
        guard let rule = rule(for: occurrence) else { return }
        withAnimation {
            RecurringEngine.skip(occurrence, rule: rule)
            try? modelContext.save()
        }
    }

    private func acknowledge(_ occurrence: PendingOccurrence) {
        guard let rule = rule(for: occurrence) else { return }
        RecurringEngine.acknowledgeBankMatch(occurrence, rule: rule)
        try? modelContext.save()
    }

    /// Cada confirmación es reversible durante unos segundos.
    private func offerUndo(_ created: [Expense]) {
        guard !created.isEmpty else { return }
        undoStack = created
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showUndo = true }

        let snapshot = created.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard undoStack.map(\.id) == snapshot else { return }
            withAnimation(.easeInOut) {
                showUndo = false
                undoStack = []
            }
        }
    }

    private func undo() {
        withAnimation {
            for expense in undoStack { modelContext.delete(expense) }
            try? modelContext.save()
            undoStack = []
            showUndo = false
        }
    }

    // MARK: - Texto

    private func scheduleText(_ occurrence: PendingOccurrence) -> String {
        guard let last = occurrence.dates.max() else { return "" }
        let base = "Tocaba el " + shortDate(last)
        if occurrence.dates.count > 1 { return base + " · \(occurrence.dates.count) fechas juntas" }
        let days = Period.calendar.dateComponents([.day], from: Period.calendar.startOfDay(for: last),
                                                  to: Period.calendar.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return base }
        return base + (days == 1 ? " · ayer" : " · hace \(days) días")
    }

    private func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "EEEE d"
        return f.string(from: date).capitalizedFirst
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d MMM"
        return f.string(from: date).replacingOccurrences(of: ".", with: "")
    }
}
