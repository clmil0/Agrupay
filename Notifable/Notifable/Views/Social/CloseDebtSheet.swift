import SwiftUI

/// «Cerrar deuda» («Soluciones de cobro», 08): una sola puerta para cerrar,
/// con dos caminos y su efecto escrito. Avisar es un interruptor aparte, no
/// otra forma de cerrar. Reemplaza a Perdonar, Archivar y Deuda saldada.
struct CloseDebtSheet: View {
    let share: ReceivableShare
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var receivables = FriendReceivables.shared
    @State private var friendsManager = FriendsManager.shared

    private enum Choice { case paid, forgive }
    @State private var choice: Choice = .forgive
    @State private var notify = false
    @State private var isSaving = false
    @State private var failed = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var friend: Friend { friendsManager.friend(with: share.debtor) }
    private var remaining: String { Money.format(share.remaining, currency: share.currency) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                DebtPayHead(title: friend.name + " · " + share.merchant, amount: remaining, detail: "Lo que falta")

                option(.paid, icon: "banknote", tint: palette.positive,
                       title: "Ya me pagó lo que falta",
                       detail: "Registra " + remaining + " como pago")
                option(.forgive, icon: "hands.and.sparkles", tint: accent.color,
                       title: "Perdonar " + remaining,
                       detail: "Se suman a tu gasto y a tu presupuesto")

                // A alguien sin la app no hay a quién avisarle desde aquí.
                if choice == .forgive && !share.isContact {
                    Toggle(isOn: $notify) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Avisarle a " + friend.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.label)
                            Text("Le llega «te perdonó " + remaining + "»")
                                .font(.system(size: 12.5))
                                .foregroundStyle(palette.secondaryLabel)
                        }
                    }
                    .tint(accent.color)
                    .padding(14)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
                    .transition(.opacity)
                }

                if failed {
                    Text("No se pudo cerrar. " + (receivables.lastErrorMessage ?? "Revisa tu conexión."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.negative)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button { Task { await save() } } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(accent.buttonText).controlSize(.small) }
                        Text(choice == .paid ? "Registrar " + remaining : "Perdonar " + remaining)
                            .font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accent.buttonFill.opacity(isSaving ? 0.4 : 1),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .background(palette.background)
            .navigationTitle("Cerrar deuda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
            .animation(.easeInOut(duration: 0.2), value: choice)
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.height(share.isContact ? 430 : 520)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
    }

    private func option(_ value: Choice, icon: String, tint: Color, title: String, detail: String) -> some View {
        let isOn = choice == value
        return Button { choice = value } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? accent.color : palette.tertiaryLabel)
            }
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isOn ? accent.color.opacity(0.55) : palette.hairline, lineWidth: isOn ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func save() async {
        isSaving = true
        failed = false
        defer { isSaving = false }
        switch choice {
        case .paid:
            guard await receivables.recordPayment(share, amount: share.remaining, via: "Otro") != nil else {
                failed = true
                return
            }
            onDone("Deuda de " + friend.name + " cerrada")
        case .forgive:
            guard await receivables.forgive(share, notify: notify && !share.isContact) else {
                failed = true
                return
            }
            onDone("Le perdonaste " + remaining + " a " + friend.name)
        }
        dismiss()
    }
}
