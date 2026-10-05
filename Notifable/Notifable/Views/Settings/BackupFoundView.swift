import SwiftUI

/// Celular nuevo: se acaba de conectar el correo y esa cuenta ya tenía un
/// respaldo. Es la única vez que la app pregunta por sí sola; después, el
/// usuario tiene que ir a Sincronización.
///
/// Enseña cuántas cosas vuelven en vez de un "hay un respaldo" abstracto: la
/// diferencia entre aceptar y no aceptar tiene que ser visible antes de tocar.
struct BackupFoundView: View {

    let header: BackupHeader
    let onRestore: () -> Void
    let onSkip: () -> Void

    @Environment(\.colorScheme) private var scheme
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false

    @State private var isRestoring = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .purple }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle()
                    .fill(accent.color.opacity(0.16))
                    .frame(width: 78, height: 78)
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(accent.onSurface(scheme))
            }

            Text("Encontramos tu configuración")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            Text(origin)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 28)

            VStack(spacing: 0) {
                item("slider.horizontal.3", "Reglas de comercio", header.ruleCount)
                item("square.grid.2x2", "Categorías y límites", sum(header.categoryCount, header.limitCount))
                item("bolt.fill", "Atajos y recurrentes", header.shortcutCount)
                item("square.and.pencil", "Cobros y anotado a mano", header.manualCount)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .padding(.horizontal, 20)
            .padding(.top, 26)

            Text("Tus gastos del correo no hace falta traerlos: se vuelven a leer solos.")
                .font(.caption)
                .foregroundStyle(palette.tertiaryLabel)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
                .padding(.horizontal, 32)

            Spacer(minLength: 20)

            Button {
                isRestoring = true
                onRestore()
            } label: {
                HStack(spacing: 8) {
                    if isRestoring { ProgressView().tint(accent.buttonText) }
                    Text(isRestoring ? "Restaurando…" : "Restaurar")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(accent.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isRestoring)
            .padding(.horizontal, 20)

            Button("Ahora no", action: onSkip)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.vertical, 16)
                .disabled(isRestoring)
        }
        .background(palette.background)
    }

    private var origin: String {
        let date = header.updatedAt?.formatted(date: .long, time: .omitted) ?? "otro día"
        if let device = header.deviceLabel {
            return "Guardada el \(date) desde \(device), con la misma cuenta que acabas de conectar."
        }
        return "Guardada el \(date) con la misma cuenta que acabas de conectar."
    }

    private func sum(_ a: Int?, _ b: Int?) -> Int? {
        guard a != nil || b != nil else { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    @ViewBuilder
    private func item(_ icon: String, _ title: String, _ count: Int?) -> some View {
        if let count, count > 0 {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.footnote)
                    .frame(width: 20)
                    .foregroundStyle(accent.onSurface(scheme))
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(palette.label)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.secondaryLabel)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 48)
            }
        }
    }
}
