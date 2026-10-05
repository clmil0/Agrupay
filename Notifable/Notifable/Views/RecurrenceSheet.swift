import SwiftUI

/// Lo que el usuario configura antes de que exista la regla.
///
/// Es un valor y no un `@Model` porque la regla sólo se crea al guardar el
/// gasto: si el usuario cancela el modal, no debe quedar nada programado.
struct RecurrenceDraft: Equatable {

    enum EndMode: Equatable { case never, onDate, afterCount }

    var frequency: RecurrenceFrequency = .never
    var dayOfMonth: Int = Period.calendar.component(.day, from: Date())
    var weekdays: Set<Int> = []
    var autoConfirm: Bool = false
    var endMode: EndMode = .never
    var endDate: Date = Period.calendar.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    var occurrenceCount: Int = 12
    var startDate: Date = Date()

    var repeats: Bool { frequency != .never }

    /// El modelo sólo guarda `endDate`; "después de N veces" se traduce a la
    /// fecha de la N-ésima ocurrencia, así no hay dos formas de decir lo mismo
    /// en la base de datos.
    func resolvedEndDate(merchant: String, category: String, amount: Double, currency: String) -> Date? {
        switch endMode {
        case .never:
            return nil
        case .onDate:
            return endDate
        case .afterCount:
            let probe = makeRule(merchant: merchant, category: category,
                                 amount: amount, currency: currency, endDate: nil)
            guard let probe else { return nil }
            let cal = Period.calendar
            guard let horizon = cal.date(byAdding: .year, value: 10, to: startDate) else { return nil }
            let dates = probe.occurrences(in: DateInterval(start: startDate, end: horizon))
            guard dates.count >= occurrenceCount, occurrenceCount > 0 else { return dates.last }
            return cal.date(byAdding: .day, value: 1, to: dates[occurrenceCount - 1])
        }
    }

    func makeRule(merchant: String,
                  category: String,
                  amount: Double,
                  currency: String,
                  endDate: Date?) -> RecurringExpense? {
        guard repeats else { return nil }
        return RecurringExpense(
            merchant: merchant,
            category: category,
            amount: amount,
            currency: currency,
            frequency: frequency,
            dayOfMonth: dayOfMonth,
            weekdays: Array(weekdays).sorted(),
            autoConfirm: autoConfirm,
            startDate: startDate,
            endDate: endDate
        )
    }

    /// La regla definitiva, con el fin ya resuelto.
    func build(merchant: String, category: String, amount: Double, currency: String) -> RecurringExpense? {
        let end = resolvedEndDate(merchant: merchant, category: category,
                                  amount: amount, currency: currency)
        return makeRule(merchant: merchant, category: category,
                        amount: amount, currency: currency, endDate: end)
    }

    /// Etiqueta para la fila "Repetir" del modal.
    func label(merchant: String, amount: Double, currency: String) -> String {
        guard repeats else { return "Nunca" }
        let probe = makeRule(merchant: merchant, category: "Otros",
                             amount: amount, currency: currency, endDate: nil)
        return probe?.scheduleLabel ?? frequency.rawValue
    }

    init(from rule: RecurringExpense) {
        frequency = rule.frequency
        dayOfMonth = rule.dayOfMonth
        weekdays = Set(rule.weekdays)
        autoConfirm = rule.autoConfirm
        startDate = rule.startDate
        if let end = rule.endDate {
            endMode = .onDate
            endDate = end
        }
    }

    init() {}
}

/// Configurar la recurrencia. Sustituye al `Toggle("Es Suscripción")`, que sólo
/// ponía una marca en un gasto suelto: no programaba nada ni sabía cuándo
/// tocaba el siguiente.
struct RecurrenceSheet: View {

    @Binding var draft: RecurrenceDraft
    let merchant: String
    let amount: Double
    let currency: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @State private var working = RecurrenceDraft()

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    frequencyList

                    if working.frequency == .weekly {
                        weekdayPicker
                    } else if working.frequency != .never {
                        dayOfMonthStepper
                    }

                    if working.repeats {
                        autoConfirmRow
                        endSection
                        upcomingCard
                        deduplicationNote
                    }
                }
                .padding(.vertical, 16)
            }
            .background(palette.background)
            .navigationTitle("Repetir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        draft = working
                        dismiss()
                    }
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .onAppear { working = draft }
    }

    // MARK: - Frecuencia

    /// Segmentado con etiquetas cortas (`5h`). La lista de antes existía
    /// porque «Cada semana» no cabía en un segmento; «Semanal» sí.
    private var frequencyList: some View {
        ShellSegment(items: RecurrenceFrequency.allCases, selection: frequencyBinding) { frequency in
            switch frequency {
            case .never:   return "Nunca"
            case .weekly:  return "Semanal"
            case .monthly: return "Mensual"
            case .yearly:  return "Anual"
            }
        }
        .padding(.horizontal, 16)
    }

    private var frequencyBinding: Binding<RecurrenceFrequency> {
        Binding(get: { working.frequency }, set: { frequency in
            working.frequency = frequency
            if frequency == .weekly && working.weekdays.isEmpty {
                working.weekdays = [Period.calendar.component(.weekday, from: Date())]
            }
        })
    }

    // MARK: - Semanal

    private var weekdayPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DÍAS")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                Button("Lun a vie") {
                    withAnimation(.easeInOut(duration: 0.15)) { working.weekdays = [2, 3, 4, 5, 6] }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent.onSurface(scheme))
            }

            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    let selected = working.weekdays.contains(weekday)
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { toggleWeekday(weekday) }
                    } label: {
                        Text(Self.initials[weekday] ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? accent.buttonText : palette.label)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selected ? accent.buttonFill : palette.surface)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.names[weekday] ?? "")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Lunes primero, como el resto de la app.
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let initials: [Int: String] = [1: "D", 2: "L", 3: "M", 4: "X", 5: "J", 6: "V", 7: "S"]
    private static let names: [Int: String] = [1: "Domingo", 2: "Lunes", 3: "Martes", 4: "Miércoles",
                                               5: "Jueves", 6: "Viernes", 7: "Sábado"]

    private func toggleWeekday(_ weekday: Int) {
        if working.weekdays.contains(weekday) {
            // Al menos un día: una regla semanal sin días no se repite nunca.
            guard working.weekdays.count > 1 else { return }
            working.weekdays.remove(weekday)
        } else {
            working.weekdays.insert(weekday)
        }
    }

    // MARK: - Mensual / anual

    /// Stepper y no `DatePicker`: se elige un día del ciclo, no una fecha.
    private var dayOfMonthStepper: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Día \(working.dayOfMonth)")
                    .font(.body)
                    .foregroundStyle(palette.label)

                Spacer()

                stepperButton("minus") {
                    working.dayOfMonth = max(1, working.dayOfMonth - 1)
                }
                stepperButton("plus") {
                    working.dayOfMonth = min(31, working.dayOfMonth + 1)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )

            if working.dayOfMonth > 28 {
                Text("En meses cortos se registra el último día disponible.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(palette.label)
                .frame(width: 32, height: 32)
                .background(Circle().fill(palette.track))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "minus" ? "Un día menos" : "Un día más")
    }

    // MARK: - Automático

    private var autoConfirmRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Registrar automáticamente")
                    .foregroundStyle(palette.label)
                Text("Sin confirmar. Úsalo sólo si el monto nunca cambia.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $working.autoConfirm)
                .labelsHidden()
                .tint(accent.color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Fin

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TERMINA")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                endOption("Nunca", mode: .never)
                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 16)
                endOption("En una fecha", mode: .onDate)

                if working.endMode == .onDate {
                    DatePicker("Fecha de fin", selection: $working.endDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 16)
                endOption("Después de \(working.occurrenceCount) veces", mode: .afterCount)

                if working.endMode == .afterCount {
                    Stepper("Repeticiones: \(working.occurrenceCount)",
                            value: $working.occurrenceCount, in: 1...120)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
    }

    private func endOption(_ title: String, mode: RecurrenceDraft.EndMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { working.endMode = mode }
        } label: {
            HStack {
                Text(title).foregroundStyle(palette.label)
                Spacer()
                if working.endMode == mode {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Próximas fechas

    /// La verificación de que la regla quedó como el usuario cree: cuatro
    /// fechas calculadas en vivo, como hojas de calendario (`5h`).
    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRÓXIMAS FECHAS")
                .font(.system(size: 11.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 6)

            if upcomingDates.isEmpty {
                Text("Con esta configuración no hay fechas por delante.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 6)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(upcomingDates.enumerated()), id: \.offset) { index, date in
                        VStack(spacing: 2) {
                            Text(shortMonth(date))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == 0 ? accent.onSurface(scheme) : palette.secondaryLabel)
                            Text("\(Period.calendar.component(.day, from: date))")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(palette.label)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(index == 0 ? accent.color.opacity(0.5) : palette.hairline, lineWidth: index == 0 ? 1 : 0.5))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func shortMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "MMM"
        return f.string(from: date).replacingOccurrences(of: ".", with: "").lowercased()
    }

    private var upcomingDates: [Date] {
        guard let rule = working.build(merchant: merchant.isEmpty ? "Gasto" : merchant,
                                       category: "Otros",
                                       amount: amount,
                                       currency: currency) else { return [] }
        let cal = Period.calendar
        let from = cal.startOfDay(for: Date())
        guard let horizon = cal.date(byAdding: .year, value: 2, to: from) else { return [] }
        return Array(rule.occurrences(in: DateInterval(start: from, end: horizon)).prefix(4))
    }

    // MARK: - Nota de deduplicación

    private var deduplicationNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(palette.positive)
            Text("Si el banco te envía el cobro de "
                 + (merchant.isEmpty ? "este gasto" : Accounting.displayName(merchant))
                 + " esos días, AgruPay usa el del banco y no duplica el gasto.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}
