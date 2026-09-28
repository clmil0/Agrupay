import SwiftUI
import SwiftData

/// Colocación en filas que saltan de línea al llenarse el ancho.
///
/// Un `HStack` con scroll horizontal escondería etiquetas fuera de pantalla, y
/// lo que se busca aquí es lo contrario: que se vean **todas** de un vistazo.
/// Son como mucho cinco por gasto (`TagCatalog.maxPerExpense`), así que nunca
/// pasan de dos o tres líneas.
struct TagFlowLayout: Layout {

    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// La cápsula de una etiqueta.
///
/// Texto y punto de color, nunca icono: el icono es la identidad de la
/// categoría, y repetir esa forma en la etiqueta haría que se confundieran.
struct TagChip: View {

    let name: String
    var isSelected: Bool = true
    var showsRemove: Bool = false
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var color: Color { TagCatalog.shared.color(for: name) }

    var body: some View {
        let content = HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)

            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? palette.label : palette.secondaryLabel)
                .lineLimit(1)

            if showsRemove {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(isSelected ? color.opacity(scheme == .dark ? 0.22 : 0.16) : palette.track.opacity(0.55),
                    in: Capsule())
        .overlay(Capsule().stroke(isSelected ? color.opacity(0.35) : .clear, lineWidth: 0.5))

        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Selector de etiquetas de un gasto.
///
/// Crear y asignar son el mismo gesto —nadie crea una etiqueta para no
/// ponerla—, así que el campo de texto de arriba hace las dos cosas y no hay
/// ningún modo "gestionar etiquetas" aquí dentro: eso vive en
/// Categorías › Etiquetas, que es donde se renombra, se fusiona y se borra.
struct TagPickerSheet: View {

    let selected: [String]
    var onToggle: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @StateObject private var catalog = TagCatalog.shared
    @State private var draft = ""
    /// Para eliminar una etiqueta de todos los gastos que la llevan, no sólo
    /// de los que se están etiquetando aquí.
    @Query private var expenses: [Expense]
    @State private var deleting: TagRef?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var isFull: Bool { selected.count >= TagCatalog.maxPerExpense }

    private var matches: [String] {
        let query = TagCatalog.normalized(draft)
        guard !query.isEmpty else { return catalog.names }
        return catalog.names.filter { TagCatalog.normalized($0).contains(query) }
    }

    /// Lo escrito no coincide con ninguna existente: se ofrece crearla. Con
    /// coincidencia exacta no se ofrece, que es lo que evita "Madre" y "madre"
    /// conviviendo.
    private var canCreate: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !catalog.exists(trimmed)
    }

    private func isOn(_ name: String) -> Bool {
        let key = TagCatalog.normalized(name)
        return selected.contains { TagCatalog.normalized($0) == key }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field

                    if isFull {
                        ShellNote(icon: "info.circle",
                                  text: "Cinco etiquetas es el tope por movimiento. Quita una para añadir otra.",
                                  tint: palette.secondaryLabel)
                    }

                    if canCreate {
                        Button {
                            create()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                Text("Crear «" + draft.trimmingCharacters(in: .whitespacesAndNewlines) + "»")
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 14.5))
                            .foregroundStyle(accent.onSurface(scheme))
                        }
                        .buttonStyle(.plain)
                        .disabled(isFull)
                        .opacity(isFull ? 0.4 : 1)
                    }

                    if catalog.names.isEmpty {
                        ShellEmptyState(icon: "tag",
                                        title: "Aún no hay etiquetas",
                                        message: "Escribe arriba para crear la primera. Una etiqueta cruza categorías: «madre», «viaje Cusco», «reembolsable».")
                    } else if matches.isEmpty {
                        Text("Ninguna etiqueta coincide.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(palette.secondaryLabel)
                    } else {
                        TagFlowLayout {
                            ForEach(matches, id: \.self) { name in
                                TagChip(name: name,
                                        isSelected: isOn(name),
                                        showsRemove: isOn(name)) {
                                    onToggle(name)
                                }
                                .opacity(!isOn(name) && isFull ? 0.35 : 1)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleting = TagRef(name: name)
                                    } label: { Label("Eliminar etiqueta", systemImage: "trash") }
                                }
                            }
                        }

                        Text("Mantén presionada una etiqueta para eliminarla.")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
                .padding(16)
            }
            .background(palette.background)
            .navigationTitle("Etiquetas")
            .navigationBarTitleDisplayMode(.inline)
            .alert(deleting.map { "¿Eliminar «\($0.name)»?" } ?? "",
                   isPresented: Binding(get: { deleting != nil },
                                        set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { ref in
                Button("Cancelar", role: .cancel) {}
                Button("Eliminar", role: .destructive) {
                    Task { await TagEditor.delete(ref.name, in: expenses) }
                }
            } message: { ref in
                let count = TagEditor.expenseCount(of: ref.name, in: expenses)
                Text(count == 0 ? "No la lleva ningún gasto."
                     : "Se quita de \(count == 1 ? "1 gasto" : "\(count) gastos"). Sus categorías no cambian.")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Listo") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryLabel)
            TextField("Buscar o crear…", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { if canCreate { create() } }
            if !draft.isEmpty {
                Button { draft = "" } label: {
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

    private func create() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isFull else { return }
        onToggle(trimmed)
        draft = ""
    }
}
