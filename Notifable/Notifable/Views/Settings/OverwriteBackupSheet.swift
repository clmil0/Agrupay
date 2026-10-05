import SwiftUI

/// La advertencia antes de subir este celular encima de una copia que existe.
///
/// Aparece cuando la sincronización está en pausa sobre una copia con datos
/// —se entró con la cuenta y no se quiso restaurar, o se usó "Empezar de
/// cero"— y el usuario cambia algo (sincronización automática) o elige
/// reemplazarla desde Ajustes (manual). `write_config_backup` reemplaza todo:
/// lo que diga esta hoja es exactamente lo que se pierde, así que tiene que
/// decir de cuándo es la copia, qué contiene y que no hay vuelta atrás.
///
/// Borrar pide dos confirmaciones. La opción destacada es la que no destruye
/// nada: traer la copia.
struct OverwriteBackupSheet: View {

    let header: BackupHeader
    let accent: AppThemeColor
    let onRestore: () -> Void
    let onOverwrite: () -> Void
    let onLater: () -> Void

    @State private var confirmingOverwrite = false

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(palette.negative)
                    .padding(.top, 24)

                Text("Tu cuenta ya tiene una copia de seguridad")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)

                Text("Sincronizar este celular **borrará esa copia** y la reemplazará por lo que hay aquí.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)

                details
                warning
                buttons
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(palette.background)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .confirmationDialog("¿Borrar la copia de seguridad para siempre?",
                            isPresented: $confirmingOverwrite,
                            titleVisibility: .visible) {
            Button("Sí, borrar la copia y reemplazarla", role: .destructive, action: onOverwrite)
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se perderán \(summaryLine). No se puede deshacer.")
        }
    }

    // MARK: - Qué hay en la copia

    private var details: some View {
        VStack(spacing: 0) {
            row("Guardada", periodText)
            if let device = header.deviceLabel ?? header.accountEmail {
                divider
                row("Último celular", device)
            }
            ForEach(countRows, id: \.title) { item in
                divider
                row(item.title, "\(item.count)")
            }
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "trash.fill")
                .foregroundStyle(palette.negative)
            Text("Esta acción es **irreversible**. Si reemplazas la copia, lo guardado \(periodText.lowercasedFirst) no se podrá recuperar de ninguna forma.")
                .font(.footnote)
                .foregroundStyle(palette.label)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(palette.negative.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.negative.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button(action: onRestore) {
                Text("Traer la copia a este celular")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accent.buttonFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                confirmingOverwrite = true
            } label: {
                Text("Borrar la copia y reemplazarla")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.negative)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(palette.negative, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)

            Button("Ahora no", action: onLater)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.top, 4)

            Text("Con \"Ahora no\" la sincronización sigue en pausa: nada de lo que cambies en este celular se guarda hasta que elijas.")
                .font(.caption)
                .foregroundStyle(palette.tertiaryLabel)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Textos

    /// "del 3 de marzo de 2026 al 15 de setiembre de 2026". Sin `createdAt`
    /// (servidor anterior a v5) sólo se sabe la última fecha.
    private var periodText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateStyle = .long
        f.timeStyle = .none
        switch (header.createdAt, header.updatedAt) {
        case let (start?, end?) where !Calendar.current.isDate(start, inSameDayAs: end):
            return "Del \(f.string(from: start)) al \(f.string(from: end))"
        case let (_, end?):
            return "El \(f.string(from: end))"
        case let (start?, nil):
            return "Desde el \(f.string(from: start))"
        default:
            return "En una fecha desconocida"
        }
    }

    private struct CountRow { let title: String; let count: Int }

    private var countRows: [CountRow] {
        var rows: [CountRow] = []
        func add(_ title: String, _ count: Int?) {
            if let count, count > 0 { rows.append(CountRow(title: title, count: count)) }
        }
        add("Reglas de comercio", header.ruleCount)
        add("Categorías", header.categoryCount)
        add("Límites por categoría", header.limitCount)
        if header.quickCount != nil || header.recurringCount != nil {
            add("Gastos rápidos", header.quickCount)
            add("Gastos recurrentes", header.recurringCount)
            add("Movimientos anotados a mano", header.manualTxCount)
            add("Cambios a gastos del correo", header.editCount)
        } else {
            add("Atajos y recurrentes", header.shortcutCount)
            add("Movimientos a mano y cambios", header.manualCount)
        }
        return rows
    }

    private var totalCount: Int { countRows.reduce(0) { $0 + $1.count } }

    private var summaryLine: String {
        let total = totalCount
        let items = total == 1 ? "1 dato guardado" : "\(total) datos guardados"
        return items + " (" + periodText.lowercasedFirst + ")"
    }

    private var divider: some View {
        Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.secondaryLabel)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(palette.label).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

private extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
