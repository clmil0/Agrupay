import SwiftUI

/// Lo que dice una tira de stats al tocarla: la cifra en grande, qué
/// significa en una frase, un gráfico chico que se recorre con el dedo y las
/// dos cifras de las que sale.
///
/// Las tiras del dashboard son finas a propósito —etiqueta y número— y el
/// detalle vive aquí, sin sacar al usuario del dashboard. Con una sola tira
/// elegida, este mismo detalle se dibuja en línea (`StatExpandedCard`).
struct StatDetail: Identifiable {
    typealias Kind = DashboardStat

    let kind: Kind
    let amount: String
    var amountColor: Color?
    let detail: String
    let tiles: [StatFigure]
    /// Lo que dice la tira del dashboard: la cifra sin céntimos, o la fecha.
    let strip: String
    /// Segunda línea de la tira cuando hay sitio (dos tiras o una sola).
    var caption: String?
    var visual: StatVisual?

    var id: String { kind.rawValue }
    var title: String { kind.title }
    /// La cifra de arriba es texto (una fecha), no un monto: va más chica y
    /// en dos líneas si hace falta.
    var isName: Bool { kind == .topDay }
}

struct StatFigure: Hashable {
    let label: String
    let value: String
    var color: Color?
}

/// Lo que va entre la frase y las dos cifras.
enum StatVisual {
    case chart(StatChart)
    /// Racha: un cuadro por día del mes.
    case days([StatDay], start: String, end: String)
    /// Límites superados: las categorías y cuánto se pasaron.
    case list([StatListItem], more: Int)
}

enum StatDay { case free, spent, future }

struct StatListItem: Identifiable {
    let name: String
    let value: String
    var id: String { name }
}

/// Un gráfico de líneas chico (`1a`–`1e`): una o dos series, la marcada con
/// relleno degradado, y un punto que se mueve con el dedo.
struct StatChart {
    enum Role { case spend, income, ideal }

    struct Series {
        /// Hasta el último día con datos; el eje X sigue siendo el mes entero.
        var values: [Double]
        var role: Role
        var name: String
        var step = false
        var dashed = false
        var area = false
    }

    let series: [Series]
    /// Una por punto del eje X («12 set»); fija el ancho del eje.
    let labels: [String]
    /// Lo que dice la burbuja en cada punto («12 set · S/ 434»).
    let tips: [String]
    let defaultIndex: Int
    var yMax: Double
    /// Con pocos puntos (meses), un punto en cada uno.
    var allDots = false

    var count: Int { labels.count }
    /// El último punto que se puede marcar: hoy, en el mes en curso.
    var maxIndex: Int { max(0, (series.filter { !$0.dashed }.map(\.values.count).max() ?? count) - 1) }
}

// MARK: - Hoja

struct StatSheet: View {
    @Environment(\.hidesAmounts) private var hidesAmounts
    let stat: StatDetail

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 440
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        trackedBody.trackScreen("stat_sheet", feature: .statSheet)
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .frame(width: 34, height: 34)
                        .background(palette.selectedFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cerrar")
            }
            .overlay {
                Text(stat.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(palette.label)
            }

            VStack(spacing: 8) {
                Text(stat.amount.masked(hidesAmounts))
                    .font(.system(size: stat.isName ? 32 : 40, weight: .bold))
                    .tracking(stat.isName ? -0.8 : -1.2)
                    .monospacedDigit()
                    .foregroundStyle(stat.amountColor ?? palette.label)
                    .multilineTextAlignment(.center)
                    .lineLimit(stat.isName ? 2 : 1)
                    .minimumScaleFactor(0.6)

                Text(stat.detail.masked(hidesAmounts))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            if let visual = stat.visual {
                StatVisualView(visual: visual, interactive: true, ringColor: palette.surfaceElevated)
            }

            StatTilesRow(tiles: stat.tiles)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        // La hoja mide lo que su contenido: cada stat trae otro gráfico.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 + 16 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.surfaceElevated)
    }
}

// MARK: - Tarjeta grande

/// Con una sola tira elegida, ésta ocupa la fila entera y enseña lo que
/// antes sólo cabía en la hoja: la frase, el gráfico y las dos cifras. Tocarla
/// abre la hoja, donde el gráfico se recorre con el dedo.
struct StatExpandedCard: View {
    @Environment(\.hidesAmounts) private var hidesAmounts
    let stat: StatDetail
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(stat.title)
                        .font(.system(size: 13, weight: palette.duoText == nil ? .medium : .semibold))
                        .foregroundStyle(palette.duoText ?? palette.secondaryLabel)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.duoText ?? palette.secondaryLabel)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(stat.amount.masked(hidesAmounts))
                        .font(.system(size: stat.isName ? 26 : 32, weight: .bold))
                        .tracking(-1)
                        .monospacedDigit()
                        .foregroundStyle(stat.amountColor ?? palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.detail.masked(hidesAmounts))
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let visual = stat.visual {
                    StatVisualView(visual: visual, interactive: false, ringColor: palette.surface)
                }

                StatTilesRow(tiles: stat.tiles, fill: palette.selectedFill)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stat.title + ": " + stat.amount)
    }
}

// MARK: - Piezas

struct StatTilesRow: View {
    @Environment(\.hidesAmounts) private var hidesAmounts
    let tiles: [StatFigure]
    var fill: Color?

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.tertiaryLabel)
                        .lineLimit(1)
                    Text(tile.value.masked(hidesAmounts))
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(tile.color ?? palette.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .background(fill ?? palette.selectedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        // Las dos del mismo alto aunque una encoja su texto.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct StatVisualView: View {
    let visual: StatVisual
    let interactive: Bool
    /// El borde de los puntos: el fondo sobre el que se dibujan.
    let ringColor: Color

    var body: some View {
        switch visual {
        case .chart(let chart):
            StatLineChart(chart: chart, interactive: interactive, ringColor: ringColor)
        case .days(let days, let start, let end):
            StatDaysStrip(days: days, start: start, end: end)
        case .list(let items, let more):
            StatLimitList(items: items, more: more)
        }
    }
}

/// El gráfico de `1a`–`1e`. Se recorre arrastrando el dedo; al soltar, la
/// marca se queda donde quedó.
struct StatLineChart: View {
    @Environment(\.hidesAmounts) private var hidesAmounts
    let chart: StatChart
    var interactive = true
    let ringColor: Color

    @Environment(\.colorScheme) private var scheme
    @State private var hover: Int?
    @State private var tipSize: CGSize = .zero
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private static let height: CGFloat = 84

    private func color(_ role: StatChart.Role) -> Color {
        switch role {
        case .spend:  return accent.color
        case .income: return palette.income
        case .ideal:  return palette.label.opacity(0.5)
        }
    }

    private func dotColor(_ role: StatChart.Role) -> Color {
        role == .spend ? accent.onSurface(scheme) : color(role)
    }

    private var index: Int { min(chart.maxIndex, hover ?? chart.defaultIndex) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                plot(width: geo.size.width)
            }
            .frame(height: Self.height)
            .padding(.top, 18)

            legend
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.tips.indices.contains(index) ? chart.tips[index] : "")
    }

    private func plot(width: CGFloat) -> some View {
        let n = chart.count
        let h = Self.height
        let x: (Int) -> CGFloat = { n > 1 ? CGFloat($0) / CGFloat(n - 1) * width : width / 2 }
        let yMax = max(chart.yMax, 0.01)
        let y: (Double) -> CGFloat = { h - 2 - CGFloat(min(max($0, 0), yMax) / yMax) * (h - 14) }
        let i = index
        let markX = x(i)

        func path(_ values: [Double], step: Bool) -> Path {
            Path { p in
                for (k, v) in values.enumerated() {
                    let point = CGPoint(x: x(k), y: y(v))
                    if k == 0 {
                        p.move(to: point)
                    } else if step {
                        p.addLine(to: CGPoint(x: point.x, y: p.currentPoint?.y ?? point.y))
                        p.addLine(to: point)
                    } else {
                        p.addLine(to: point)
                    }
                }
            }
        }

        let dots: [(point: CGPoint, color: Color)] = {
            if chart.allDots, let first = chart.series.first {
                return first.values.enumerated().map { k, v in
                    (CGPoint(x: x(k), y: y(v)), k == i ? dotColor(first.role) : color(first.role))
                }
            }
            return chart.series.filter { !$0.dashed && $0.values.indices.contains(i) }.map {
                (CGPoint(x: markX, y: y($0.values[i])), dotColor($0.role))
            }
        }()

        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: h - 0.5))
                p.addLine(to: CGPoint(x: width, y: h - 0.5))
            }
            .stroke(palette.separator, lineWidth: 1)

            if let area = chart.series.first(where: \.area), !area.values.isEmpty {
                path(area.values, step: area.step)
                    .closedToBaseline(lastX: x(area.values.count - 1), baseline: h)
                    .fill(LinearGradient(colors: [color(area.role).opacity(0.28), color(area.role).opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
            }

            ForEach(Array(chart.series.enumerated().reversed()), id: \.offset) { _, series in
                path(series.values, step: series.step)
                    .stroke(color(series.role),
                            style: StrokeStyle(lineWidth: series.dashed ? 1.5 : 2,
                                               lineCap: .round, lineJoin: .round,
                                               dash: series.dashed ? [4, 4] : []))
            }

            Rectangle()
                .fill(palette.label.opacity(0.3))
                .frame(width: 1, height: h)
                .offset(x: markX)

            ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                Circle()
                    .fill(dot.color)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(ringColor, lineWidth: 2))
                    .position(dot.point)
            }
        }
        .frame(width: width, height: h, alignment: .topLeading)
        // En un overlay, para que la burbuja no cambie el tamaño del gráfico.
        .overlay(alignment: .topLeading) {
            if chart.tips.indices.contains(i) {
                Text(chart.tips[i].masked(hidesAmounts))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.track, in: Capsule())
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { tipSize = $0 }
                    // Centrada sobre la marca, sin salirse por los bordes.
                    .offset(x: min(max(0, markX - tipSize.width / 2), max(0, width - tipSize.width)),
                            y: -tipSize.height - 4)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard interactive, n > 1, width > 0 else { return }
                let fraction = min(1, max(0, value.location.x / width))
                let k = Int((fraction * CGFloat(n - 1)).rounded())
                if k != hover {
                    hover = k
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }, including: interactive ? .all : .subviews)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Text(chart.labels.first ?? "")
            Spacer(minLength: 4)
            ForEach(Array(chart.series.enumerated()), id: \.offset) { _, series in
                HStack(spacing: 5) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 1))
                        p.addLine(to: CGPoint(x: 10, y: 1))
                    }
                    .stroke(color(series.role), style: StrokeStyle(lineWidth: 2, dash: series.dashed ? [3, 2] : []))
                    .frame(width: 10, height: 2)
                    Text(series.name)
                }
            }
            Spacer(minLength: 4)
            Text(chart.labels.last ?? "")
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(palette.tertiaryLabel)
        .lineLimit(1)
    }
}

private extension Path {
    /// La línea cerrada contra el eje, para el relleno degradado de debajo.
    func closedToBaseline(lastX: CGFloat, baseline: CGFloat) -> Path {
        var path = self
        path.addLine(to: CGPoint(x: lastX, y: baseline))
        path.addLine(to: CGPoint(x: 0, y: baseline))
        path.closeSubpath()
        return path
    }
}

/// Racha sin gastar: un cuadro por día del mes, del color del ingreso los
/// días sin gasto.
struct StatDaysStrip: View {
    let days: [StatDay]
    let start: String
    let end: String

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(fill(day))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 12) {
                Text(start)
                Spacer(minLength: 4)
                legendItem("Sin gastar", color: palette.income)
                legendItem("Con gasto", color: palette.track)
                Spacer(minLength: 4)
                Text(end)
            }
            .font(.system(size: 11))
            .foregroundStyle(palette.tertiaryLabel)
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(days.filter { $0 == .free }.count) días sin gastar este mes")
    }

    private func fill(_ day: StatDay) -> Color {
        switch day {
        case .free:   return palette.income
        case .spent:  return palette.track
        case .future: return palette.track.opacity(0.35)
        }
    }

    private func legendItem(_ name: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name)
        }
    }
}

/// Límites superados: cada categoría pasada y por cuánto.
struct StatLimitList: View {
    @Environment(\.hidesAmounts) private var hidesAmounts
    let items: [StatListItem]
    let more: Int

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        if items.isEmpty {
            Label("Todas tus categorías siguen dentro de su límite", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(palette.income)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        MovementIcon(icon: CategoryStyle.icon(for: item.name),
                                     color: CategoryStyle.color(for: item.name, accent: accent.color),
                                     size: 28)
                        Text(item.name)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.value.masked(hidesAmounts))
                            .font(.system(size: 13.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(palette.negative)
                            .lineLimit(1)
                    }
                }
                if more > 0 {
                    Text(more == 1 ? "y 1 más" : "y \(more) más")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.tertiaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 2)
        }
    }
}
