import SwiftData
import SwiftUI

/// «Cobrar a un amigo» sin un gasto en la mano: primero lo que falta repartir,
/// luego lo reciente, y el resto del historial sólo tras buscar. Al elegir,
/// se abre «Compartir gasto».
struct ShareExpensePickerSheet: View {
    let onPick: (Expense) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

    @State private var search = ""
    @State private var searchQuery = ""

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var pending: [Expense] { expenses.filter(\.needsSplitting) }

    /// Lo de las últimas dos semanas que todavía no se compartió.
    private var recent: [Expense] {
        let since = Date().addingTimeInterval(-14 * 86_400)
        return expenses.lazy
            .filter { $0.date >= since && $0.canBeShared && !$0.isShared && !$0.isDebt }
            .prefix(15).map { $0 }
    }

    private var searchResults: [Expense] {
        guard searchQuery.count >= 2 else { return [] }
        return expenses.lazy
            .filter { $0.canBeShared && $0.merchant.localizedCaseInsensitiveContains(searchQuery) }
            .prefix(20).map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    searchField
                    if !searchQuery.isEmpty {
                        section("Resultados", searchResults,
                                empty: "Nada con «\(searchQuery)».")
                    } else {
                        if !pending.isEmpty { section("Falta repartir", pending, empty: nil) }
                        section("Recientes", recent, empty: "No hay gastos recientes. Búscalo por comercio.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(palette.background)
            .navigationTitle("¿Qué gasto compartes?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryLabel)
            TextField("Busca por comercio", text: $search)
                .submitLabel(.search)
                .onSubmit { searchQuery = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                .onChange(of: search) { _, value in
                    if value.isEmpty { searchQuery = "" }
                }
            if !search.isEmpty {
                Button {
                    search = ""
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(palette.secondaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Expense], empty: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: title)
            if items.isEmpty, let empty {
                Text(empty)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            } else {
                MovementCard {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, expense in
                        row(expense)
                        if index < items.count - 1 { MovementSeparator() }
                    }
                }
            }
        }
    }

    private func row(_ expense: Expense) -> some View {
        Button {
            onPick(expense)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                MovementIcon(icon: MovementStyle.icon(for: expense),
                             color: MovementStyle.color(for: expense, accent: accent.color, scheme: scheme),
                             size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Accounting.displayName(expense.merchant))
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(expense.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
                         + (expense.isShared ? " · ya compartido" : ""))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                Text(Money.format(expense.amount, currency: expense.currency))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Presenta el selector y, al elegir, «Compartir gasto». Una hoja después de
/// la otra: SwiftUI no deja abrir la segunda mientras la primera se cierra.
struct ShareFlowModifier: ViewModifier {
    @Binding var isPicking: Bool
    @Binding var sharing: Expense?
    var onDone: ((String) -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPicking) {
                ShareExpensePickerSheet { expense in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { sharing = expense }
                }
            }
            .sheet(item: $sharing) { expense in
                ShareExpenseSheet(expense: expense, onDone: onDone)
            }
    }
}

extension View {
    func shareFlow(isPicking: Binding<Bool>, sharing: Binding<Expense?>,
                   onDone: ((String) -> Void)? = nil) -> some View {
        modifier(ShareFlowModifier(isPicking: isPicking, sharing: sharing, onDone: onDone))
    }
}
