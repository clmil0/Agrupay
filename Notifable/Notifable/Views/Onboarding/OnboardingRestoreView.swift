import SwiftUI

/// Paso del onboarding que sólo existe si hace falta: la cuenta con la que
/// acaba de entrar ya tenía un respaldo.
///
/// Enseña cuándo se guardó, desde qué dispositivo y **cuántas cosas** vuelven,
/// porque "hay un respaldo" no ayuda a decidir; "38 reglas y 12 categorías" sí.
/// Y deja la puerta abierta a ignorarlo: quien cambió de vida financiera puede
/// querer empezar limpio, y esconder esa salida sería obligarle a restaurar
/// para luego borrar.
struct OnboardingRestoreView: View {

    let header: BackupHeader
    /// `true` si se restauró; `false` si eligió empezar de cero.
    let onDone: (Bool) -> Void

    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @Environment(\.colorScheme) private var scheme

    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showFreshConfirm = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(accent.color.opacity(0.16))
                        .frame(width: 78, height: 78)
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(accent.onSurface(scheme))
                }
                .padding(.top, 56)

                Text("Encontramos tu configuración")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                    .padding(.horizontal, 28)

                Text(origin)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                    .padding(.horizontal, 30)

                savedAt
                    .padding(.top, 20)
                    .padding(.horizontal, 20)

                inventory
                    .padding(.top, 12)
                    .padding(.horizontal, 20)

                Text("Tus gastos del correo no hace falta traerlos: se vuelven a leer solos en el siguiente paso.")
                    .font(.caption)
                    .foregroundStyle(palette.tertiaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 32)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(palette.negative)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 28)
                }

                buttons
                    .padding(.top, 26)
                    .padding(.bottom, 36)
            }
        }
        .background(palette.background)
        .confirmationDialog("¿Empezar de cero?", isPresented: $showFreshConfirm, titleVisibility: .visible) {
            Button("Empezar de cero", role: .destructive) { onDone(false) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tu copia se queda guardada en tu cuenta. Podrás restaurarla más tarde desde Ajustes → Sincronización.")
        }
    }

    // MARK: - Cuándo y de dónde

    private var savedAt: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accent.color.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16))
                    .foregroundStyle(accent.onSurface(scheme))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(header.updatedAt?.formatted(date: .long, time: .shortened) ?? "Fecha desconocida")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.label)
                Text(header.deviceLabel ?? header.accountEmail ?? "Otro dispositivo")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    private var origin: String {
        "Guardada con la misma cuenta que acabas de conectar."
    }

    // MARK: - Cuánto vuelve

    private var rows: [(icon: String, title: String, count: Int)] {
        [
            ("slider.horizontal.3", "Reglas de comercio", header.ruleCount ?? 0),
            ("square.grid.2x2", "Categorías y límites", (header.categoryCount ?? 0) + (header.limitCount ?? 0)),
            ("bolt.fill", "Atajos y recurrentes", header.shortcutCount ?? 0),
            ("square.and.pencil", "Cobros y anotado a mano", header.manualCount ?? 0)
        ].filter { $0.2 > 0 }
    }

    @ViewBuilder
    private var inventory: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
                    HStack(spacing: 12) {
                        Image(systemName: row.icon)
                            .font(.footnote)
                            .frame(width: 20)
                            .foregroundStyle(accent.onSurface(scheme))
                        Text(row.title)
                            .font(.subheadline)
                            .foregroundStyle(palette.label)
                        Spacer(minLength: 8)
                        Text("\(row.count)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 48)

                    if index < rows.count - 1 {
                        Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 48)
                    }
                }
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
        }
    }

    // MARK: - Acciones

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await restore() }
            } label: {
                HStack(spacing: 8) {
                    if isRestoring { ProgressView().tint(accent.buttonText) }
                    Text(isRestoring ? "Restaurando…" : "Restaurar mi configuración")
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

            Button("Empezar de cero") { showFreshConfirm = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
                .disabled(isRestoring)
        }
        .padding(.horizontal, 24)
    }

    private func restore() async {
        isRestoring = true
        errorMessage = nil
        let error = await ConfigBackupManager.shared.restore(code: nil)
        isRestoring = false
        if let error {
            errorMessage = error
        } else {
            onDone(true)
        }
    }
}
