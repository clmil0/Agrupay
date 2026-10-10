import SwiftUI

/// El donut de distribución de Categorías (`1b`).
///
/// Dibujado a mano y no con Swift Charts: el gráfico necesita el monto del
/// periodo centrado dentro del anillo, y los colores tienen que salir de
/// `CategoryStyle` —el mismo que pinta los íconos de cada fila— para que la
/// porción y el cuadradito de la lista de abajo sean del mismo color. Un
/// `SectorMark` con su propia escala de color rompería justo eso.
struct CategoryDonut: View {
    struct Slice: Identifiable {
        let category: String
        let total: Double
        let color: Color
        var id: String { category }
    }

    let slices: [Slice]
    /// Igual que en `DonutLegend`: como mucho cinco porciones; con más
    /// categorías, la quinta es «Otras» en gris con el resto.
    var maxSlices: Int = CategoryDonut.maxEntries

    var lineWidth: CGFloat = 26
    var size: CGFloat = 136

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    private var total: Double { Money.sum(slices) { $0.total } }

    /// Todas si caben; si no, las primeras y «Otras» con el resto.
    private var visibleSlices: [Slice] {
        guard slices.count > maxSlices else { return slices }
        let rest = slices.dropFirst(maxSlices - 1)
        return Array(slices.prefix(maxSlices - 1)) + [
            Slice(category: "Otras",
                  total: Money.sum(Array(rest)) { $0.total },
                  color: palette.tertiaryLabel)
        ]
    }

    /// Inicio y fin de cada arco, en fracciones de vuelta.
    private var arcs: [(slice: Slice, start: Double, end: Double)] {
        guard Money.cents(total) > 0 else { return [] }
        var cursor = 0.0
        return visibleSlices.map { slice in
            let fraction = max(0, slice.total / total)
            let arc = (slice, cursor, cursor + fraction)
            cursor += fraction
            return arc
        }
    }

    var body: some View {
        ZStack {
            // `inset` mete el anillo dentro del marco: con `stroke` a secas la
            // mitad del grosor se salía y el donut ocupaba más de lo que medía.
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(palette.track, lineWidth: lineWidth)

            ForEach(arcs, id: \.slice.id) { arc in
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: arc.start, to: max(arc.start, arc.end - 0.004))
                    .stroke(arc.slice.color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        // El primer arco arranca arriba, no a las tres en punto.
        .rotationEffect(.degrees(-90))
        .frame(width: size, height: size)
    }
}

/// La leyenda del donut: nombre y porcentaje, con el punto del color de la
/// porción. Hace de resumen; el detalle está en la lista de abajo.
struct DonutLegend: View {
    let slices: [CategoryDonut.Slice]
    let total: Double
    /// Filas como mucho, «Otras N» incluida.
    var maxRows: Int = CategoryDonut.maxEntries
    /// Con el ojito del Resumen cerrado: «•••» en vez del porcentaje.
    var hidesPercents = false

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let shown = slices.count > maxRows ? maxRows - 1 : slices.count
            ForEach(slices.prefix(shown)) { slice in
                row(color: slice.color,
                    name: slice.category,
                    percent: Money.formatPercent(slice.total, of: total))
            }

            if slices.count > maxRows {
                let rest = slices.dropFirst(shown)
                let restTotal = Money.sum(Array(rest)) { $0.total }
                row(color: palette.tertiaryLabel,
                    name: "Otras \(rest.count)",
                    percent: Money.formatPercent(restTotal, of: total),
                    muted: true)
            }
        }
    }

    private func row(color: Color, name: String, percent: String, muted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(muted ? palette.secondaryLabel : palette.label)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(hidesPercents ? AmountPrivacy.hiddenDigits : percent)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryLabel)
        }
    }
}

extension CategoryDonut {
    /// Porciones del anillo y filas de la leyenda, «Otras» incluida.
    static let maxEntries = 5
}
