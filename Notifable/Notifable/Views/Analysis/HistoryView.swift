import SwiftUI
import SwiftData

/// Análisis (`1b`), la hermana de Movimientos: **el único sitio de la app con
/// periodo**.
///
/// El selector Día · Semana · Mes · Año que antes vivía arriba de Resumen, de
/// Categorías y de Ritmo —tres barras distintas para un mismo ajuste global—
/// se retira de todas y aterriza aquí. El resto de la app habla siempre del
/// mes en curso; quien quiera mirar atrás, entra.
///
/// Las barras no son los días del periodo: son **los últimos periodos**. Con
/// «Mes» se ven los últimos siete meses, y la barra de la derecha es el mes
/// actual. Es lo que convierte la pantalla en un historial y no en otro
/// gráfico del mes que ya estás viendo en Categorías.
struct HistoryView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @Query private var incomes: [Income]
    @StateObject private var rates = ExchangeRateService.shared

    /// Local a esta vista, no `@AppStorage("period")`: el periodo dejó de ser
    /// un ajuste global. Nadie más lo lee.
    @State private var granularity: PeriodGranularity = .mes
    @State private var offset = 0

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }

    private static let selectable: [PeriodGranularity] = [.dia, .semana, .mes, .anio]

    /// Cuántas barras dibujar por granularidad. Más de esto y las barras se
    /// vuelven rayas que no se pueden tocar.
    private var bucketCount: Int {
        switch granularity {
        case .dia:    return 14
        case .semana: return 10
        case .mes:    return 7
        case .anio:   return 5
        case .rango:  return 7
        }
    }

    /// Los periodos a dibujar, del más antiguo al más reciente. El último es
    /// el seleccionado.
    private var periods: [Period] {
        var result: [Period] = []
        var cursor = Period(granularity: granularity, reference: Date())
        for _ in 0..<offset { cursor = cursor.previous }
        for _ in 0..<bucketCount {
            result.append(cursor)
            cursor = cursor.previous
        }
        return result.reversed()
    }

    /// Una sola conversión a snapshots por dibujado: la pantalla pide nueve
    /// totales —siete barras más el periodo y el anterior— y cada uno sobre
    /// los modelos volvía a convertir el historial entero.
    private func totals(for period: Period,
                        _ snapshots: (expenses: [ExpenseSnapshot], incomes: [IncomeSnapshot])) -> PeriodTotals {
        Accounting.totals(expenses: snapshots.expenses, incomes: snapshots.incomes, period: period, usdToPen: rate)
    }

    var body: some View {
        let periods = self.periods
        let current = periods.last ?? Period(granularity: granularity, reference: Date())
        let windowStart = min(periods.first?.interval.start ?? Date.distantPast, current.previous.interval.start)
        let windowEnd = current.interval.end
        
        let relevantExpenses = expenses.filter { $0.date >= windowStart && $0.date < windowEnd }
        let relevantIncomes = incomes.filter { $0.date >= windowStart && $0.date < windowEnd }

        let snapshots = (expenses: relevantExpenses.map(\.accountingSnapshot),
                         incomes: relevantIncomes.map(\.accountingSnapshot))
        
        let series = periods.map { (period: $0, total: totals(for: $0, snapshots).spent) }
        let currentTotals = totals(for: current, snapshots)
        let previousTotals = totals(for: current.previous, snapshots)
        let rhythm = Rhythm(period: current, current: currentTotals, previous: previousTotals)

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 0) {
                ShellTitle(title: "Análisis", subtitle: windowSubtitle)

                ShellSegment(items: Self.selectable, selection: $granularity,
                             tint: palette.expense) { $0.rawValue }
                    .padding(.bottom, 24)

                chartCard(series: series)
                    .padding(.bottom, 26)

                headline(period: current, totals: currentTotals, rhythm: rhythm, series: series)
                    .padding(.bottom, 22)

                if !rhythm.categoryChanges.isEmpty {
                    changesSection(rhythm: rhythm, previous: current.previous)
                        .padding(.bottom, 22)
                }

                let subscriptions = detectedSubscriptions(in: current, source: relevantExpenses)
                if !subscriptions.isEmpty {
                    subscriptionsSection(subscriptions)
                }
            }
            .padding(.horizontal, ShellMetrics.sideInset)
            .padding(.top, ShellMetrics.contentTopInset)
            .padding(.bottom, 40)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            progress.update(offset)
        }
        .onChange(of: granularity) { _, _ in
            offset = 0
            trackPeriod()
        }
        .onChange(of: offset) { _, _ in trackPeriod() }
    }

    /// El periodo elegido y lo más viejo que alcanzan las barras.
    private func trackPeriod() {
        let periods = self.periods
        guard let selected = periods.last else { return }
        var extra: [String: Any] = ["offset": offset]
        if let oldest = periods.first {
            extra["window_months_back"] = Analytics.monthsBack(from: oldest.interval.start)
        }
        Analytics.periodChanged(screen: "history", period: selected, extra: extra)
    }

    // MARK: - Gráfico

    /// «Los últimos siete meses»: cuánto abarcan las barras.
    private var windowSubtitle: String {
        let words = [5: "cinco", 7: "siete", 10: "diez", 14: "catorce"]
        let count = words[bucketCount] ?? "\(bucketCount)"
        switch granularity {
        case .dia:    return "Los últimos \(count) días"
        case .semana: return "Las últimas \(count) semanas"
        case .mes:    return "Los últimos \(count) meses"
        case .anio:   return "Los últimos \(count) años"
        case .rango:  return "El rango elegido"
        }
    }

    /// Suelto sobre el fondo (`1b`): la barra de la derecha, el periodo que se
    /// mira, en el naranja del gasto; las demás, en gris.
    private func chartCard(series: [(period: Period, total: Double)]) -> some View {
        let maximum = series.map(\.total).max() ?? 0

        return VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                    let isCurrent = index == series.count - 1
                    let fraction = maximum > 0 ? item.total / maximum : 0

                    VStack(spacing: 8) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 118)

                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isCurrent
                                      ? AnyShapeStyle(LinearGradient(colors: [palette.expenseLight, palette.expense],
                                                                     startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(palette.track))
                                .frame(height: max(4, 118 * fraction))
                        }

                        Text(axisLabel(for: item.period))
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? palette.expenseText : palette.secondaryLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Tocar una barra mueve la ventana hasta ella: el
                        // pasado se navega tocando, no con flechas.
                        withAnimation(.easeInOut(duration: 0.25)) {
                            offset += (series.count - 1 - index)
                        }
                    }
                }
            }

            if offset > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { offset = 0 }
                } label: {
                    Text("Volver a " + (granularity == .anio ? "este año" : "hoy"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func axisLabel(for period: Period) -> String {
        let date = period.interval.start
        switch granularity {
        case .dia:
            return date.formatted(.dateTime.day().locale(Locale(identifier: "es_ES")))
        case .semana:
            return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
        case .mes, .rango:
            return Period.spanishMonthName(for: date, abbreviated: true)
        case .anio:
            return date.formatted(.dateTime.year())
        }
    }

    // MARK: - Titular y comparativas

    /// Las comparativas van **en texto, no en más gráficos**. Un segundo
    /// gráfico para decir «S/ 340 menos que en agosto» obliga a leer dos ejes
    /// para sacar una frase.
    private func headline(period: Period,
                          totals: PeriodTotals,
                          rhythm: Rhythm,
                          series: [(period: Period, total: Double)]) -> some View {
        let previous = series.count >= 2 ? series[series.count - 2].total : 0
        let delta = Money.subtract(totals.spent, previous)
        let isUp = Money.cents(delta) > 0
        let average = Money.sum(series.map(\.total)) / Double(max(1, series.count))
        let highest = series.max { $0.total < $1.total }

        let hasComparison = !Money.isZero(previous) && !Money.isZero(delta)

        return ShellCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(periodTitle(period).capitalizedFirst)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)

                    Text(Money.format(totals.spent))
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.8)
                        .monospacedDigit()
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                if hasComparison {
                    HStack(spacing: 7) {
                        deltaBadge(delta, isUp: isUp)
                        Text((isUp ? "más que " : "menos que ") + previousLabel())
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }

                Rectangle().fill(palette.separator).frame(height: 0.5)

                HStack(alignment: .top, spacing: 18) {
                    miniStat(label: averageLabel(), value: Money.formatCompact(average))
                    if let highest, Money.cents(highest.total) > 0 {
                        miniStat(label: highestLabel(),
                                 value: axisLabel(for: highest.period) + " · "
                                    + Money.formatCompact(highest.total))
                    }
                }
            }
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryLabel)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func deltaBadge(_ delta: Double, isUp: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isUp ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .bold))
            Text(Money.formatCompact(abs(delta)))
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isUp ? palette.expenseText : palette.income)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isUp ? palette.expenseSoft : palette.incomeSoft,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func periodTitle(_ period: Period) -> String {
        let date = period.interval.start
        switch granularity {
        case .dia:
            return MovementDay.label(for: date)
        case .semana:
            return "Semana del " + date.formatted(.dateTime.day().month(.abbreviated)
                .locale(Locale(identifier: "es_ES")))
        case .mes, .rango:
            return Period.spanishMonthName(for: date)
        case .anio:
            return date.formatted(.dateTime.year())
        }
    }

    /// «agosto», «la semana pasada».
    private func previousLabel() -> String {
        switch granularity {
        case .dia:    return "el día anterior"
        case .semana: return "la semana pasada"
        case .mes:
            let reference = periods.last?.previous.reference ?? Date()
            return Period.spanishMonthName(for: reference).lowercased()
        case .anio:   return "el año pasado"
        case .rango:  return "el periodo anterior"
        }
    }

    /// «Promedio 7 meses».
    private func averageLabel() -> String {
        switch granularity {
        case .dia:    return "Promedio \(bucketCount) días"
        case .semana: return "Promedio \(bucketCount) semanas"
        case .mes:    return "Promedio \(bucketCount) meses"
        case .anio:   return "Promedio \(bucketCount) años"
        case .rango:  return "Promedio del rango"
        }
    }

    private func highestLabel() -> String {
        switch granularity {
        case .dia:    return "Día más alto"
        case .semana: return "Semana más alta"
        case .mes, .rango: return "Mes más alto"
        case .anio:   return "Año más alto"
        }
    }

    // MARK: - Qué cambió

    private func changesSection(rhythm: Rhythm, previous: Period) -> some View {
        let changes = Array(rhythm.categoryChanges.prefix(5))

        return VStack(spacing: 8) {
            ShellSectionHeader(title: "Qué cambió frente a " + periodTitle(previous).lowercased())

            MovementCard {
                ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                    let isUp = Money.cents(change.delta) > 0

                    HStack(spacing: 11) {
                        MovementIcon(icon: CategoryStyle.icon(for: change.category),
                                     color: CategoryStyle.color(for: change.category, accent: accent.color),
                                     size: 30)

                        Text(change.category)
                            .font(.system(size: 14.5))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        // «+212» en naranja, «−64» en verde: subir el gasto es
                        // lo que hay que mirar.
                        Text((isUp ? "+" : "−") + Money.formatCompact(abs(change.delta))
                                .replacingOccurrences(of: "S/ ", with: ""))
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(isUp ? palette.expenseText : palette.income)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                    if index < changes.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    // MARK: - Suscripciones

    private func detectedSubscriptions(in period: Period, source: [Expense]) -> [DetectedSubscription] {
        let calendar = Period.calendar
        let range = period.interval
        var grouped: [String: [Expense]] = [:]
        for expense in source
        where expense.isSubscription && expense.date >= range.start && expense.date < range.end {
            grouped[expense.merchant, default: []].append(expense)
        }
        return grouped.compactMap { merchant, items -> DetectedSubscription? in
            guard let last = items.max(by: { $0.date < $1.date }) else { return nil }
            return DetectedSubscription(merchant: merchant,
                                        amount: Accounting.amountInPEN(last, fallbackRate: rate),
                                        dayOfMonth: calendar.component(.day, from: last.date))
        }
        .sorted { Money.cents($0.amount) > Money.cents($1.amount) }
    }

    private func subscriptionsSection(_ subscriptions: [DetectedSubscription]) -> some View {
        let total = Money.sum(subscriptions) { $0.amount }

        return VStack(spacing: 8) {
            ShellSectionHeader(title: "Suscripciones detectadas",
                               trailing: Money.format(total) + "/mes")

            MovementCard {
                ForEach(Array(subscriptions.enumerated()), id: \.element.id) { index, subscription in
                    HStack(spacing: 12) {
                        MovementIcon(icon: "arrow.triangle.2.circlepath", color: accent.color, size: 38)

                        Text(Accounting.displayName(subscription.merchant))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)

                        Text("· día \(subscription.dayOfMonth)")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)

                        Spacer(minLength: 6)

                        Text(Money.format(subscription.amount))
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(palette.label)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if index < subscriptions.count - 1 { MovementSeparator() }
                }
            }
        }
    }
}
