import SwiftUI
import SwiftData

/// Fusionar una etiqueta en otra.
///
/// Es una hoja y no un menú de opciones porque fusionar no es elegir entre
/// cuatro cosas: es una decisión que hay que poder mirar antes de tomarla. Con
/// veinte etiquetas en el catálogo, una lista de botones sin buscador ni cifras
/// obliga a acertar de memoria cuál era «madre» y cuál «madrina».
///
/// Lo que la hoja promete, en este orden: qué se va a mover, a dónde, y **cómo
/// queda el destino**. Esa última línea es una unión, no una suma: un
/// movimiento que ya llevaba las dos etiquetas cuenta una vez.
struct TagMergeSheet: View {

    let source: String
    let expenses: [Expense]
    var onMerge: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var catalog = TagCatalog.shared
    @StateObject private var rates = ExchangeRateService.shared

    @State private var query = ""
    @State private var target: String?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var month: Period { Period(granularity: .mes, reference: Date()) }
    private var snapshots: [ExpenseSnapshot] { expenses.map(\.accountingSnapshot) }

    private var sourceKey: String { TagCatalog.normalized(source) }

    private var rows: [TagTotals.Row] {
        let all = TagTotals.rows(expenses: snapshots,
                                 in: month.interval,
                                 usdToPen: rates.usdToPenRate,
                                 known: catalog.names)
        let needle = TagCatalog.normalized(query)
        return all.filter {
            guard TagCatalog.normalized($0.tag) != sourceKey else { return false }
            return needle.isEmpty || TagCatalog.normalized($0.tag).contains(needle)
        }
    }

    private var sourceRow: TagTotals.Row? {
        TagTotals.rows(expenses: snapshots, in: month.interval, usdToPen: rates.usdToPenRate)
            .first { TagCatalog.normalized($0.tag) == sourceKey }
    }

    private var sourceCount: Int { sourceRow?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            explanation
            field
            ShellSectionHeader(title: "Etiqueta destino", trailing: matchesLabel)
                .padding(.bottom, -6)

            ScrollView {
                if rows.isEmpty {
                    Text(catalog.names.count <= 1
                         ? "No hay ninguna otra etiqueta con la que fusionar."
                         : "Ninguna etiqueta coincide con «" + query + "».")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    MovementCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            Button {
                                target = row.tag
                            } label: {
                                targetRow(row)
                            }
                            .buttonStyle(.plain)

                            if index < rows.count - 1 { MovementSeparator() }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            if let preview {
                ShellNote(icon: "info.circle", text: preview, tint: palette.secondaryLabel)
            }

            mergeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(palette.background)
    }

    // MARK: - Piezas

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Fusionar «" + source + "»")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 8)

            Button("Cancelar") { dismiss() }
                .font(.system(size: 17))
                .foregroundStyle(accent.onSurface(scheme))
        }
    }

    /// Dice las dos cosas que el usuario teme al fusionar: que se lleve por
    /// delante la categoría de los gastos (no lo hace) y qué pasa con el
    /// nombre viejo (desaparece).
    private var explanation: some View {
        Text(movementsPhrase + " a la etiqueta que elijas y «" + source
             + "» desaparece del catálogo. Nada cambia de categoría.")
            .font(.system(size: 12.5))
            .lineSpacing(1.5)
            .foregroundStyle(palette.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Con el verbo dentro: en singular es "Su movimiento **pasa**", y
    /// partirlo en dos trozos deja la frase sin concordancia.
    private var movementsPhrase: String {
        switch sourceCount {
        case 0:  return "Sus movimientos pasan"
        case 1:  return "Su movimiento pasa"
        default: return "Sus \(sourceCount) movimientos pasan"
        }
    }

    private var matchesLabel: String? {
        guard !query.isEmpty else { return nil }
        return rows.count == 1 ? "1 coincide" : "\(rows.count) coinciden"
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(palette.secondaryLabel)

            TextField("Buscar etiqueta…", text: $query)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(palette.hairline, lineWidth: 0.5))
    }

    private func targetRow(_ row: TagTotals.Row) -> some View {
        let isSelected = target.map { TagCatalog.normalized($0) == TagCatalog.normalized(row.tag) } ?? false

        return HStack(spacing: 12) {
            Circle()
                .fill(catalog.color(for: row.tag))
                .frame(width: 10, height: 10)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.tag)
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                Text(row.count == 0
                     ? "Sin movimientos este mes"
                     : (row.count == 1 ? "1 movimiento · " : "\(row.count) movimientos · ")
                        + Money.format(row.total))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer(minLength: 8)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21))
                .foregroundStyle(isSelected ? accent.onSurface(scheme) : palette.tertiaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isSelected ? accent.color.opacity(scheme == .dark ? 0.16 : 0.10) : .clear)
        .contentShape(Rectangle())
    }

    /// "«madre» quedará con 6 movimientos y S/ 425 este mes."
    private var preview: String? {
        guard let target else { return nil }
        let result = TagTotals.mergePreview(source: source,
                                            target: target,
                                            expenses: snapshots,
                                            in: month.interval,
                                            usdToPen: rates.usdToPenRate)
        let movements = result.count == 1 ? "1 movimiento" : "\(result.count) movimientos"
        return "«" + target + "» quedará con " + movements + " y "
            + Money.format(result.total) + " este mes."
    }

    private var mergeButton: some View {
        Button {
            guard let target else { return }
            onMerge(target)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 17, weight: .semibold))
                Text(target.map { "Fusionar en «" + $0 + "»" } ?? "Elige una etiqueta destino")
                    .font(.system(size: 16.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle((target == nil ? Color.white : accent.buttonText))
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(target == nil ? palette.tertiaryLabel : accent.buttonFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
    }
}
