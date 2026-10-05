import SwiftUI

/// «Tu celular»: verificarlo mandando un WhatsApp (`PhoneVerification`).
///
/// Tres estados: sin número (explica y abre WhatsApp), esperando el mensaje
/// (el código grande, por si hay que escribirlo a mano) y verificado.
struct PhoneVerificationSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var verification = PhoneVerification.shared
    @State private var confirmForget = false
    @State private var copied = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let pending = verification.pending {
                        waiting(pending)
                    } else if let phone = verification.formattedPhone {
                        verified(phone)
                    } else {
                        intro
                    }

                    if let error = verification.lastErrorMessage {
                        ShellNote(icon: "exclamationmark.circle", text: error)
                            .textSelection(.enabled)
                    }

                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.25), value: verification.pending)
                .animation(.easeInOut(duration: 0.25), value: verification.phone)
            }
            .background(palette.background)
            .navigationTitle("Tu celular")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await verification.refresh() }
            .alert("¿Quitar tu número?", isPresented: $confirmForget) {
                Button("Cancelar", role: .cancel) {}
                Button("Quitar", role: .destructive) { Task { await verification.forget() } }
            } message: {
                Text("Se borra del servidor. Puedes volver a verificarlo cuando quieras.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .appAppearance()
        .appTextSize()
    }

    // MARK: - Sin número

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "phone.badge.checkmark",
                   title: "Verifica tu número con WhatsApp",
                   subtitle: "Así tus amigos saben que los Yapes y Plines a tu número son para ti.")

            steps

            primaryButton(title: "Abrir WhatsApp", icon: "paperplane.fill",
                          busy: verification.isStarting) {
                Task { await verification.start() }
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Te abrimos WhatsApp con un código ya escrito.")
            step(2, "Tocas **Enviar**. Nada más.")
            step(3, "Vuelves aquí y tu número ya aparece verificado.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(palette.hairline, lineWidth: 0.5))
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent.onSurface(scheme))
                .frame(width: 26, height: 26)
                .background(accent.color.opacity(0.14), in: Circle())
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(palette.label)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }

    // MARK: - Esperando

    private func waiting(_ pending: PhoneVerification.Pending) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(icon: "ellipsis.message",
                   title: "Esperando tu mensaje…",
                   subtitle: "Envía este código por WhatsApp. Si se borró, escríbelo tal cual.")

            VStack(spacing: 10) {
                Text(pending.code)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(palette.label)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text("Vence en " + Self.minutesLeft(pending.expiresAt))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accent.color.opacity(0.35), lineWidth: 1))

            primaryButton(title: "Abrir WhatsApp de nuevo", icon: "paperplane.fill", busy: false) {
                verification.openWhatsApp()
            }

            HStack(spacing: 10) {
                secondaryButton(copied ? "Copiado" : "Copiar código") {
                    UIPasteboard.general.string = pending.code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }
                secondaryButton("Cancelar") { verification.cancel() }
            }
        }
    }

    // MARK: - Verificado

    private func verified(_ phone: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(palette.positive)
                VStack(alignment: .leading, spacing: 3) {
                    Text(phone)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(palette.label)
                    Text(verifiedCaption)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(palette.positive.opacity(scheme == .dark ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 10) {
                secondaryButton("Cambiar número") { Task { await verification.start() } }
                secondaryButton("Quitar", destructive: true) { confirmForget = true }
            }
        }
    }

    private var verifiedCaption: String {
        guard let date = verification.verifiedAt else { return "Verificado por WhatsApp" }
        return "Verificado por WhatsApp · "
            + date.formatted(.dateTime.day().month(.abbreviated).year().locale(Locale(identifier: "es_ES")))
    }

    // MARK: - Piezas

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock")
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 2)
            Text("Tus amigos **no ven tu número**. Sólo se usa para reconocer los pagos que te hacen. El mensaje de WhatsApp no se lee: sólo se busca el código.")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(accent.onSurface(scheme))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.color.opacity(scheme == .dark ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func header(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accent.color)
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.label)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(title: String, icon: String, busy: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(accent.buttonText).controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(accent.buttonText)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(accent.buttonFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func secondaryButton(_ title: String, destructive: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(destructive ? palette.negative : palette.label)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private static func minutesLeft(_ date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSinceNow / 60).rounded(.up)))
        return minutes == 1 ? "1 minuto" : "\(minutes) minutos"
    }
}
