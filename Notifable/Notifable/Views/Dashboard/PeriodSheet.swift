import SwiftUI

/// Lo que formó una barra del gráfico (`03` de «Soluciones del Resumen»): se
/// abre encima del Resumen, con su mes y su cuenta, sin ir a Movimientos a
/// buscarlo.
///
/// Sirve para las tres vistas del gráfico —un día, una semana o un mes— y
/// para «Día de más gasto». Muestra los tres últimos movimientos y, si hay
/// más, una fila «N más» con los íconos de sus categorías; «Ver en
/// Movimientos» abre la lista con sólo ese periodo.
struct PeriodDetail: Identifiable {
    let id = UUID()
    /// «Sábado 12», «12–18 set», «Agosto 2026».
    let title: String
    let spent: Double
    /// «3 movimientos. Tu día de más gasto en setiembre.»
    let detail: String
    /// Los tres más recientes.
    let recent: [Expense]
    /// Cuántos quedan fuera de `recent`, y sus categorías (sin repetir, la
    /// de más gasto primero).
    let moreCount: Int
    let moreCategories: [String]
    /// «Gastado» y «Del mes» (o «Del año» en la vista de meses).
    let tiles: [StatFigure]
    let filter: MovementsPeriodFilter.Selection
    let rate: Double
}

struct PeriodSheet: View {
    let period: PeriodDetail
    let onShowAll: () -> Void

    @Environment(\.hidesAmounts) private var hidesAmounts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 520
    @State private var selected: Expense?
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private static let time = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
        .locale(Locale(identifier: "es_ES"))

    var body: some View {
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
                Text(period.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(palette.label)
            }

            VStack(spacing: 8) {
                Text(Money.format(period.spent).masked(hidesAmounts))
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-1.2)
                    .monospacedDigit()
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(period.detail.masked(hidesAmounts))
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            if !period.recent.isEmpty {
                MovementCard {
                    ForEach(Array(period.recent.enumerated()), id: \.element.id) { index, expense in
                        Button { selected = expense } label: { row(expense) }
                            .buttonStyle(.plain)
                        if index < period.recent.count - 1 || period.moreCount > 0 { MovementSeparator() }
                    }
                    if period.moreCount > 0 {
                        Button(action: showAll) { moreRow }
                            .buttonStyle(.plain)
                    }
                }
            }

            StatTilesRow(tiles: period.tiles)

            if !period.recent.isEmpty {
                Button(action: showAll) {
                    Text("Ver en Movimientos")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent.buttonText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(accent.buttonFill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 + 16 }
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.surfaceElevated)
        .sheet(item: $selected) { ExpenseDetailsView(expense: $0) }
        .trackScreen("period_sheet", feature: .statSheet)
    }

    private func showAll() {
        dismiss()
        onShowAll()
    }

    private func row(_ expense: Expense) -> some View {
        let category = expense.category
        return HStack(spacing: 11) {
            MovementIcon(icon: CategoryStyle.icon(for: category),
                         color: CategoryStyle.color(for: category, accent: accent.color),
                         size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(Accounting.displayName(expense.merchant))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(category + " · " + expense.date.formatted(Self.time))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(Accounting.netCostInPEN(expense, fallbackRate: period.rate)).masked(hidesAmounts))
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(palette.label)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// «4 más», con los íconos de sus categorías apilados.
    private var moreRow: some View {
        HStack(spacing: 11) {
            StackedCategoryIcons(categories: Array(period.moreCategories.prefix(3)), size: 28,
                                 ring: palette.surfaceElevated)
                .frame(minWidth: 34, alignment: .leading)
            Text(period.moreCount == 1 ? "1 más" : "\(period.moreCount) más")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.label)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(period.moreCount == 1 ? "1 movimiento más" : "\(period.moreCount) movimientos más")
        .accessibilityHint("Abre Movimientos en este periodo")
    }
}

/// Íconos de categoría encimados, cada uno con un aro del color de fondo
/// para que se separen: la tira «Hoy» del Resumen y la fila «N más».
struct StackedCategoryIcons: View {
    let categories: [String]
    var size: CGFloat = 30
    /// El color de lo que hay detrás: el aro que separa cada ícono.
    let ring: Color

    var body: some View {
        let accent = AppThemeColor.current.color
        HStack(spacing: -size / 3) {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                MovementIcon(icon: CategoryStyle.icon(for: category),
                             color: CategoryStyle.color(for: category, accent: accent),
                             size: size)
                    // El ícono es translúcido: debajo, el fondo liso para que
                    // el de atrás no se transparente.
                    .background(ring, in: RoundedRectangle(cornerRadius: size * 0.295, style: .continuous))
                    .padding(2)
                    .background(ring, in: RoundedRectangle(cornerRadius: size * 0.295 + 2, style: .continuous))
                    .zIndex(Double(categories.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}
