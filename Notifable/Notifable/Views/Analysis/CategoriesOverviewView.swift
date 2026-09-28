import SwiftUI
import SwiftData

/// Categorías (`1b`), a la que se entra desde su tarjeta del dashboard.
///
/// Gráfico y lista **fusionados**. Antes vivían en pantallas distintas: el
/// donut arriba de la pestaña Ritmo y la lista dentro de Categorías, así que
/// para saber qué porción era cuál había que cambiar de pestaña y recordar el
/// color. Ahora la leyenda hace de resumen y la lista, de detalle.
///
/// Y con ellas el **límite**: la categoría que tiene uno lleva, entre el nombre
/// y el monto, una barrita con lo que le queda. Sólo eso, y sin cambiar el
/// alto de la fila: la proyección y la edición siguen a un toque, en el
/// detalle de la categoría.
///
/// Cada porción del donut lleva el color de su categoría, el mismo de su ícono
/// en la lista; el punto a su izquierda empata la fila con su porción.
struct CategoriesOverviewView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext
    @Query private var expenses: [Expense]
    @Query private var incomes: [Income]
    @StateObject private var rates = ExchangeRateService.shared
    @StateObject private var catalog = CategoryCatalog.shared
    @StateObject private var budgets = CategoryBudgetStore.shared

    @State private var selectedCategory: CategoryRef?
    @State private var creatingCategory = false
    @State private var editingCategory: CategoryRef?
    @State private var deletingCategory: CategoryRef?
    @State private var isDeleting = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var rate: Double { rates.usdToPenRate }
    private var month: Period { Period(granularity: .mes, reference: Date()) }

    private func totals(_ snapshots: [ExpenseSnapshot]) -> PeriodTotals {
        Accounting.totals(expenses: snapshots, incomes: incomes.map(\.accountingSnapshot),
                          period: month, usdToPen: rate)
    }

    private func slices(_ totals: PeriodTotals) -> [CategoryDonut.Slice] {
        totals.byCategory.enumerated().map { index, category in
            CategoryDonut.Slice(category: category.category,
                                total: category.total,
                                color: CategoryStyle.color(for: category.category, accent: accent.color))
        }
    }

    var body: some View {
        // Los totales y los límites leen el mismo historial: se convierte una
        // sola vez por dibujado, no una por cada uno.
        let snapshots = expenses.map(\.accountingSnapshot)
        let totals = self.totals(snapshots)
        let slices = self.slices(totals)
        let rows = self.rows(totals, snapshots: snapshots)

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 0) {
                ShellTitle(title: "Categorías", subtitle: monthSubtitle)

                if rows.isEmpty {
                    ShellEmptyState(icon: "square.grid.2x2",
                                    title: "Sin gastos este mes",
                                    message: "Cuando registres el primero verás aquí en qué se va tu dinero.")
                    // Crear categorías no depende de haber gastado: se pueden
                    // preparar antes del primer gasto.
                    newCategoryRow
                        .padding(.bottom, 24)
                } else {
                    if !slices.isEmpty {
                        chartCard(totals: totals, slices: slices)
                            .padding(.bottom, 24)
                    }
                    listHeader(spent: totals.spent)
                    categoryList(rows: rows, slices: slices)
                        .padding(.bottom, 14)
                    newCategoryRow
                        .padding(.bottom, 24)
                    topMerchants(totals: totals)
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
        .sheet(item: $selectedCategory) { ref in
            CategoryDetailView(category: ref.name)
        }
        .sheet(item: $editingCategory) { ref in
            NavigationStack {
                CategorySettingsView(category: ref.name, history: expenses)
            }
        }
        .alert(deletingCategory.map { "¿Eliminar \($0.name)?" } ?? "",
               isPresented: Binding(get: { deletingCategory != nil },
                                    set: { if !$0 { deletingCategory = nil } }),
               presenting: deletingCategory) { ref in
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) { delete(ref.name) }
        } message: { ref in
            Text(CategoryDeletion.message(for: ref.name, in: expenses))
        }
        .overlay {
            if isDeleting {
                ProgressView().controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .sheet(isPresented: $creatingCategory) {
            // Con su propia navegación: sin ella no hay barra, y sin barra no
            // hay «Listo», que es justo lo que crea la categoría.
            NavigationStack {
                CategorySettingsView(category: "", isNew: true, history: expenses)
            }
        }
    }

    // MARK: - Gráfico

    /// Suelto sobre el fondo, sin tarjeta (`2d`): el donut encabeza la
    /// pantalla y la tarjeta queda para la lista, que es lo que se toca.
    private func chartCard(totals: PeriodTotals, slices: [CategoryDonut.Slice]) -> some View {
        HStack(spacing: 18) {
            CategoryDonut(slices: slices)

            DonutLegend(slices: slices, total: totals.spent)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 2)
        .padding(.top, 14)
    }

    /// «setiembre 2026».
    private var monthSubtitle: String {
        Period.spanishMonthName(for: Date()).lowercased() + " "
            + String(Period.calendar.component(.year, from: Date()))
    }

    // MARK: - Filas

    /// Una fila por categoría con gasto este mes **más** las que sólo tienen
    /// límite: un límite que no se ha tocado en todo el mes es justo el que hay
    /// que ver, y si dependiera del gasto sería invisible hasta gastarlo.
    private func rows(_ totals: PeriodTotals, snapshots: [ExpenseSnapshot]) -> [Row] {
        let today = Date()

        func status(_ name: String) -> CategoryLimitStatus {
            CategoryLimits.status(category: name,
                                  budget: budgets.budget(for: name),
                                  expenses: snapshots,
                                  on: today,
                                  usdToPen: rate)
        }

        var rows = totals.byCategory.map {
            Row(category: $0.category, total: $0.total, status: status($0.category))
        }

        // Al final y en orden alfabético: la lista la manda el gasto, y estas
        // no tienen ninguno con el que competir por su sitio.
        let spent = Set(rows.map(\.category))
        let idle = budgets.budgets.values
            .filter { $0.hasLimit && !spent.contains($0.category) && $0.category != Accounting.unclassified }
            .map { Row(category: $0.category, total: 0, status: status($0.category)) }
            .sorted { $0.category < $1.category }

        rows.append(contentsOf: idle)

        // Las creadas a mano que aún no tienen nada asignado: si dependieran
        // del gasto, crear una categoría vacía la haría desaparecer al cerrar.
        let listed = Set(rows.map(\.category))
        let empty = catalog.names
            .filter { !listed.contains($0) && $0 != Accounting.unclassified && !$0.isEmpty }
            .sorted()
            .map { Row(category: $0, total: 0, status: status($0)) }
        rows.append(contentsOf: empty)
        return rows
    }

    // MARK: - Lista

    /// «Gasto por categoría» con el total del mes debajo: antes era la
    /// primera fila de la lista, y competía con las categorías por el ojo.
    private func listHeader(spent: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Gasto por categoría")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(palette.label)
            Text(Money.format(spent))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.bottom, 10)
    }

    private func categoryList(rows: [Row], slices: [CategoryDonut.Slice]) -> some View {
        // Las que el donut junta en «Otras» llevan su gris, no su color.
        let max = CategoryDonut.maxEntries
        let shown = slices.count > max ? max - 1 : slices.count
        let dots = Dictionary(uniqueKeysWithValues: slices.enumerated().map { index, slice in
            (slice.category, index < shown ? slice.color : palette.tertiaryLabel)
        })

        return MovementCard {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button {
                    selectedCategory = CategoryRef(name: row.category)
                } label: {
                    categoryRow(row, dot: dots[row.category])
                }
                .buttonStyle(.plain)
                .contextMenu { rowMenu(row.category) }

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(palette.separator)
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
        }
    }

    private func categoryRow(_ row: Row, dot: Color?) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(dot ?? palette.track)
                .frame(width: 7, height: 7)

            MovementIcon(icon: CategoryStyle.icon(for: row.category),
                         color: CategoryStyle.color(for: row.category, accent: accent.color),
                         size: 32)

            Text(row.category)
                .font(.system(size: 15))
                .foregroundStyle(palette.label)
                .lineLimit(1)

            Spacer(minLength: 8)

            if row.status.hasLimit { limitBadge(row.status) }

            Text(Money.format(row.total))
                .font(.system(size: 14.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Money.cents(row.total) > 0 ? palette.label : palette.tertiaryLabel)
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    /// Sólo lo pendiente —«S/ 120 libres» o «S/ 40 pasado»— sobre una barrita
    /// del ancho de la palabra. Cabe en el alto del ícono, así que la fila con
    /// límite mide lo mismo que la que no lo tiene.
    private func limitBadge(_ status: CategoryLimitStatus) -> some View {
        let tint = status.level.color(palette)

        return VStack(alignment: .trailing, spacing: 3) {
            Text(status.shortLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)

            LimitBar(fraction: status.fraction,
                     paceFraction: status.elapsedFraction,
                     color: tint,
                     height: 3)
                .frame(width: 56)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.longLabel)
    }

    /// Pulsación larga: editar y eliminar (también las básicas).
    @ViewBuilder
    private func rowMenu(_ category: String) -> some View {
        Button {
            editingCategory = CategoryRef(name: category)
        } label: { Label("Editar", systemImage: "pencil") }

        if !CategoryCatalog.isSystem(category) {
            Button(role: .destructive) {
                deletingCategory = CategoryRef(name: category)
            } label: { Label("Eliminar", systemImage: "trash") }
        }
    }

    private func delete(_ category: String) {
        isDeleting = true
        Task {
            await CategoryEditor.delete(category, in: expenses)
            try? modelContext.save()
            isDeleting = false
        }
    }

    /// Crear categoría vive **al final de la lista**, no en un modo de edición
    /// aparte: es una fila más, con la misma forma que las que crea.
    private var newCategoryRow: some View {
        Button {
            creatingCategory = true
        } label: {
            MovementCard {
                HStack(spacing: 11) {
                    MovementIcon(icon: "plus", color: accent.color, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nueva categoría")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.label)
                        Text("Nombre, color y límite")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }

                    Spacer()
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Top comercios

    @ViewBuilder
    private func topMerchants(totals: PeriodTotals) -> some View {
        let top = Array(totals.byMerchant.prefix(5))

        if !top.isEmpty {
            VStack(spacing: 8) {
                ShellSectionHeader(title: "Top comercios",
                                   trailing: Period.spanishMonthName(for: Date()))

                MovementCard {
                    ForEach(Array(top.enumerated()), id: \.element.id) { index, merchant in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.secondaryLabel)
                                .frame(width: 20)

                            Text(Accounting.displayName(merchant.merchant))
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(palette.label)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(Money.format(merchant.total))
                                .font(.system(size: 14.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(palette.label)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        if index < top.count - 1 { MovementSeparator() }
                    }
                }
            }
        }
    }
}

extension CategoriesOverviewView {
    /// Lo que pinta una fila: el gasto del mes y el estado de su límite, ya
    /// resueltos, para que el cuerpo de la vista no calcule nada.
    struct Row: Identifiable {
        let category: String
        let total: Double
        let status: CategoryLimitStatus
        var id: String { category }
    }
}

/// Una categoría como `item:` de una hoja. `String` no es `Identifiable`, y
/// conformarlo de forma retroactiva afectaría a todo el módulo.
struct CategoryRef: Identifiable, Hashable {
    let name: String
    var id: String { name }
}
