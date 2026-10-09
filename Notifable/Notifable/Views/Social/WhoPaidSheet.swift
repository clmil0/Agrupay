import SwiftUI

/// «¿Quién te pagó?» («Soluciones de cobro», 06): un ingreso se abona a una
/// persona, no a un gasto. Se elige entre quienes te deben; el gasto de esa
/// deuda se actualiza solo. «Ingreso libre» lo deja contando en tu balance.
struct WhoPaidSheet: View {
    let income: Income
    var onDone: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var receivables = FriendReceivables.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var selectedID: String?
    @State private var isSaving = false
    @State private var failed = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    /// Las deudas abiertas en la moneda del ingreso: primero las del monto
    /// exacto y las de alguien que se llama como quien te pagó.
    private var candidates: [ReceivableShare] {
        let sender = income.title ?? income.source
        return receivables.open
            .filter { $0.currency == income.currency }
            .sorted { lhs, rhs in score(lhs, sender: sender) > score(rhs, sender: sender) }
    }

    private func score(_ share: ReceivableShare, sender: String) -> Int {
        var value = 0
        if Money.cents(share.remaining) == Money.cents(income.amount) { value += 2 }
        let name = friendsManager.friend(with: share.debtor).name
        if DebtPaymentMatcher.namesMatch(payee: sender, friend: [name]) { value += 3 }
        return value
    }

    private var selected: ReceivableShare? { candidates.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Un pago baja lo que te deben; un ingreso libre cuenta en tu balance.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)

                    if candidates.isEmpty {
                        ShellNote(icon: "person.2", text: "Nadie te debe en " + (income.currency == "USD" ? "dólares" : "soles")
                                  + ". Comparte un gasto para que aparezca aquí.")
                    } else {
                        MovementCard {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, share in
                                if index > 0 { MovementSeparator() }
                                row(share)
                            }
                        }
                    }

                    freeIncomeRow

                    if let selected { outcome(selected) }
                    if failed {
                        Text("No se pudo registrar. " + (receivables.lastErrorMessage ?? "Revisa tu conexión."))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.negative)
                    }
                }
                .padding(16)
            }
            .background(palette.background)
            .navigationTitle("¿Quién te pagó?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .task {
                if receivables.shares.isEmpty { await receivables.refresh() }
                if selectedID == nil, let first = candidates.first, score(first, sender: income.title ?? income.source) > 0 {
                    selectedID = first.id
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
    }

    private func row(_ share: ReceivableShare) -> some View {
        let friend = friendsManager.friend(with: share.debtor)
        let isOn = selectedID == share.id
        return Button { selectedID = share.id } label: {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(share.merchant + " · te debe " + Money.format(share.remaining, currency: share.currency))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? accent.color : palette.tertiaryLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var freeIncomeRow: some View {
        let isOn = selectedID == nil
        return Button { selectedID = nil } label: {
            HStack(spacing: 12) {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.positive)
                    .frame(width: 38, height: 38)
                    .background(palette.positive.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ingreso libre")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text("Cuenta en tu balance del mes")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? accent.color : palette.tertiaryLabel)
            }
            .padding(14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isOn ? accent.color.opacity(0.55) : palette.hairline, lineWidth: isOn ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func outcome(_ share: ReceivableShare) -> some View {
        let applied = min(income.amount, share.remaining)
        let left = Money.subtract(share.remaining, applied)
        var text = Money.cents(left) == 0
            ? "Queda pagada su parte de " + share.merchant + "."
            : "Abona " + Money.format(applied, currency: share.currency) + ". Quedarían "
                + Money.format(left, currency: share.currency) + "."
        if Money.cents(income.amount) > Money.cents(share.remaining) {
            text += " Lo demás no cuenta para esta deuda."
        }
        text += " Deja de contar como ingreso del mes."
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() async {
        guard let share = selected else {
            dismiss()
            return
        }
        isSaving = true
        failed = false
        defer { isSaving = false }
        let via = ["Yape", "Plin"].contains(income.source) ? income.source : "Otro"
        guard await receivables.recordPayment(share, amount: income.amount, via: via, income: income) != nil else {
            failed = true
            return
        }
        onDone?("Pago de " + friendsManager.friend(with: share.debtor).name + " registrado")
        dismiss()
    }
}
