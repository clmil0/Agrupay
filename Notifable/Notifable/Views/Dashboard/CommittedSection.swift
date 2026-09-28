import SwiftUI
import SwiftData

/// «Comprometido este mes» (`1b`): los gastos programados que tocan este mes,
/// lleguen o no todavía.
///
/// Absorbe a «Por confirmar», que vivía arriba de Movimientos: un recurrente
/// que ya venció y espera tu visto bueno se ve aquí con su botón de aceptar,
/// porque no cuenta en tu mes hasta que lo aceptas, y el dashboard es donde
/// se mira el mes. Lo que el banco ya cobró por su cuenta se revisa en la
/// pantalla completa (`PendingConfirmationView`): aceptarlo con un toque
/// duplicaría el gasto.
struct CommittedSection: View {
    let rate: Double

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.hidesAmounts) private var hidesAmounts
    @Query private var rules: [RecurringExpense]

    @State private var showsPendingConfirmation = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    /// Una fila por regla con alguna fecha en el mes.
    struct Row: Identifiable {
        enum Status { case upcoming(Date), charged, awaiting(PendingOccurrence), chargedByBank }

        let rule: RecurringExpense
        let state: Status
        let occurrences: Int
        var id: UUID { rule.id }
    }

    // MARK: - Datos

    /// Los gastos de la ventana de casado de recurrentes: los mismos que usa
    /// `ContentView` al resolverlos al arrancar. Sin reglas activas no se pide
    /// nada.
    private func matchingExpenses() -> [Expense] {
        guard let window = RecurringEngine.matchWindow(rules: rules) else { return [] }
        let start = window.start
        let end = window.end
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\Expense.date, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func rows() -> [Row] {
        let active = rules.filter { !$0.isPaused && $0.frequency != .never }
        guard !active.isEmpty else { return [] }

        let month = Period(granularity: .mes, reference: Date()).interval
        let today = Period.calendar.startOfDay(for: Date())
        let pending = RecurringEngine.pending(rules: active, expenses: matchingExpenses())

        return active.compactMap { rule -> Row? in
            let dates = rule.occurrences(in: month)
            guard !dates.isEmpty else { return nil }

            let own = pending.filter { $0.ruleID == rule.id }
            let state: Row.Status
            if let awaiting = own.first(where: \.isAwaiting) {
                state = .awaiting(awaiting)
            } else if !own.isEmpty {
                state = .chargedByBank
            } else if let next = dates.first(where: { $0 >= today }),
                      rule.lastResolvedOccurrence.map({ $0 < next }) ?? true {
                state = .upcoming(next)
            } else {
                state = .charged
            }
            return Row(rule: rule, state: state, occurrences: dates.count)
        }
        .sorted { lhs, rhs in
            lhs.sortKey < rhs.sortKey
        }
    }

    // MARK: - Cuerpo

    var body: some View {
        let rows = self.rows()

        if !rows.isEmpty {
            let total = Money.sum(rows) { row in
                let amount = Money.multiply(row.rule.amount, by: Double(row.occurrences))
                return row.rule.currency == "USD" ? Money.multiply(amount, by: rate) : amount
            }

            VStack(spacing: 8) {
                ShellSectionHeader(title: "Comprometido este mes", trailing: Money.formatCompact(total).masked(hidesAmounts))

                MovementCard {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                        if index < rows.count - 1 {
                            Rectangle()
                                .fill(palette.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 59)
                        }
                    }
                }

                if rows.contains(where: \.isAwaiting) {
                    Text("Lo que espera tu visto bueno no cuenta en tu mes hasta que lo aceptas.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                }
            }
            .sheet(isPresented: $showsPendingConfirmation) { PendingConfirmationView() }
        }
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 11) {
            MovementIcon(icon: CategoryStyle.icon(for: row.rule.category),
                         color: CategoryStyle.color(for: row.rule.category, accent: accent.color),
                         size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(Accounting.displayName(row.rule.merchant))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                Text(subtitle(row))
                    .font(.system(size: 12))
                    .foregroundStyle(row.isAwaiting || row.isChargedByBank ? palette.warning : palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(Money.formatCompact(row.rule.amount, currency: row.rule.currency).masked(hidesAmounts))
                .amountVeil()
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryLabel)

            if case .awaiting(let occurrence) = row.state {
                Button {
                    confirm(occurrence, rule: row.rule)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(accent.color, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Aceptar " + Accounting.displayName(row.rule.merchant))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isAwaiting || row.isChargedByBank { showsPendingConfirmation = true }
        }
    }

    /// «cada 28 · llega el 26», «cada 1 · ya cobrado».
    private func subtitle(_ row: Row) -> String {
        let schedule: String
        switch row.rule.frequency {
        case .monthly: schedule = "cada \(row.rule.dayOfMonth)"
        case .weekly:  schedule = row.rule.scheduleLabel.lowercased()
        case .yearly:  schedule = "cada año"
        case .never:   schedule = ""
        }

        let status: String
        switch row.state {
        case .upcoming(let date):
            let day = Period.calendar.component(.day, from: date)
            status = Period.calendar.isDateInToday(date) ? "llega hoy" : "llega el \(day)"
        case .charged:
            status = "ya cobrado"
        case .awaiting(let occurrence):
            status = occurrence.dates.count > 1 ? "por confirmar · \(occurrence.dates.count) cobros"
                                                : "por confirmar"
        case .chargedByBank:
            status = "ya lo cobró el banco · revisar"
        }
        return schedule.isEmpty ? status : schedule + " · " + status
    }

    private func confirm(_ occurrence: PendingOccurrence, rule: RecurringExpense) {
        _ = RecurringEngine.confirm(occurrence, rule: rule, in: modelContext)
        try? modelContext.save()
    }
}

private extension CommittedSection.Row {
    var isAwaiting: Bool {
        if case .awaiting = state { return true }
        return false
    }

    var isChargedByBank: Bool {
        if case .chargedByBank = state { return true }
        return false
    }

    /// Lo que pide algo va primero; luego lo que llega, por fecha; lo cobrado
    /// al final.
    var sortKey: String {
        switch state {
        case .awaiting:          return "0"
        case .chargedByBank:     return "1"
        case .upcoming(let d):   return "2" + String(Int(d.timeIntervalSince1970))
        case .charged:           return "3" + rule.merchant
        }
    }
}
