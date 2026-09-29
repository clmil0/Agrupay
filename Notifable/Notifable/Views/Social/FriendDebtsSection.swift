import SwiftUI

/// Lo que le debes a tus amigos y los envíos que podrían ser su pago
/// (`FriendDebts`). Vive en Amigos, bajo los cobros que te recuerdan.
///
/// Tres piezas, en orden de urgencia:
/// 1. El aviso del pago que se marcó solo, con «Deshacer».
/// 2. Las preguntas: «¿Esto fue para lo que le debes a Joseph?».
/// 3. «Lo que debes»: abierto, con «Ya le pagué» para lo que no pasó por
///    un correo (efectivo, otra cuenta).
struct FriendDebtsSection: View {

    @Environment(\.colorScheme) private var scheme
    @State private var debts = FriendDebts.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var confirmingManual: OwedShare?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var open: [OwedShare] { debts.owed.filter(\.isOpen) }
    private var recentlyPaid: [OwedShare] {
        debts.owed.filter { !$0.isOpen && ($0.paidAt ?? .distantPast) > Date().addingTimeInterval(-7 * 86_400) }
    }

    var body: some View {
        VStack(spacing: 14) {
            if let auto = debts.lastAuto { autoNotice(auto) }
            if !debts.suggestions.isEmpty { suggestionsSection }
            if !open.isEmpty || !recentlyPaid.isEmpty { owedSection }
            if let error = debts.lastErrorMessage {
                ShellNote(icon: "exclamationmark.circle", text: error)
                    .textSelection(.enabled)
            }
        }
        .task { await debts.refresh() }
        .animation(.easeInOut(duration: 0.22), value: debts.suggestions.map(\.id))
        .animation(.easeInOut(duration: 0.22), value: debts.lastAuto)
        .alert(manualTitle, isPresented: Binding(get: { confirmingManual != nil },
                                                 set: { if !$0 { confirmingManual = nil } })) {
            Button("Cancelar", role: .cancel) {}
            Button("Ya le pagué") {
                guard let share = confirmingManual else { return }
                Task { await debts.payManually(share) }
            }
        } message: {
            Text("Se le avisa que ya le pagaste. Úsalo si no fue por Yape o Plin, o si el correo no llegó.")
        }
    }

    private var manualTitle: String {
        guard let share = confirmingManual else { return "" }
        return "¿Ya le pagaste " + Money.format(share.remaining, currency: share.currency)
            + " a " + friendsManager.friend(with: share.creditor).name + "?"
    }

    // MARK: - Pago detectado

    private func autoNotice(_ auto: FriendDebts.AutoPayment) -> some View {
        let name = friendsManager.friend(with: auto.friendID).name
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(palette.positive)
            VStack(alignment: .leading, spacing: 3) {
                Text("Detectamos tu pago a \(name)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                Text(Money.format(auto.amount, currency: auto.currency) + " · " + auto.merchant
                     + ". A \(name) ya le figura que le pagaste.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    pill("Deshacer", filled: false) { Task { await debts.undoLastAuto() } }
                    pill("Listo", filled: true) { debts.dismissAutoNotice() }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(palette.positive.opacity(scheme == .dark ? 0.16 : 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Preguntas

    private var suggestionsSection: some View {
        VStack(spacing: 0) {
            ShellSectionHeader(title: debts.suggestions.count == 1 ? "¿Esto fue un pago?"
                                                                   : "¿Estos fueron pagos?")
            VStack(spacing: 10) {
                ForEach(debts.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion,
                                   friend: friendsManager.friend(with: suggestion.friendID),
                                   onConfirm: { share in Task { await debts.confirm(suggestion, share: share) } },
                                   onReject: { debts.reject(suggestion) })
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
    }

    // MARK: - Lo que debes

    private var owedSection: some View {
        VStack(spacing: 0) {
            ShellSectionHeader(title: "Lo que debes",
                               trailing: open.isEmpty ? nil : total(open),
                               trailingTint: palette.secondaryLabel)
            MovementCard {
                let rows = open + recentlyPaid
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, share in
                    owedRow(share)
                    if index < rows.count - 1 { MovementSeparator() }
                }
            }
        }
    }

    private func total(_ shares: [OwedShare]) -> String? {
        let currencies = Set(shares.map(\.currency))
        guard currencies.count == 1, let currency = currencies.first else { return nil }
        return Money.format(Money.sum(shares) { $0.remaining }, currency: currency)
    }

    private func owedRow(_ share: OwedShare) -> some View {
        let friend = friendsManager.friend(with: share.creditor)
        return HStack(spacing: 12) {
            FriendAvatar(friend: friend, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(share.isOpen ? "Le debes a " + friend.name : "Le pagaste a " + friend.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(detail(share))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(Money.format(share.isOpen ? share.remaining : share.amount, currency: share.currency))
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(share.isOpen ? palette.label : palette.secondaryLabel)
                    .strikethrough(!share.isOpen)
                if share.isOpen {
                    Button("Ya le pagué") { confirmingManual = share }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                        .buttonStyle(.plain)
                } else {
                    Label("Pagada", systemImage: "checkmark")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(palette.positive)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func detail(_ share: OwedShare) -> String {
        var text = share.merchant
        if let day = share.occurredOn {
            text += " · " + day.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
        }
        if share.isOpen, Money.cents(share.paidAmount) > 0 {
            text += " · abonaste " + Money.format(share.paidAmount, currency: share.currency)
        }
        return text
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Color.white : accent.onSurface(scheme))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(filled ? AnyShapeStyle(accent.color) : AnyShapeStyle(palette.surface), in: Capsule())
                .overlay(Capsule().stroke(filled ? Color.clear : palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// «Yapeaste S/ 50 a JOSEPH M. ¿Era para lo que le debes a Joseph?».
private struct SuggestionCard: View {
    let suggestion: DebtPaymentMatcher.Suggestion
    let friend: Friend
    let onConfirm: (OwedShare) -> Void
    let onReject: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var selectedID: String?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var candidate: DebtPaymentCandidate { suggestion.candidate }

    private var selected: OwedShare? {
        suggestion.shares.first { $0.id == selectedID } ?? suggestion.shares.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sentence)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if suggestion.shares.count > 1 {
                VStack(spacing: 6) {
                    ForEach(suggestion.shares) { share in
                        shareOption(share)
                    }
                }
            }

            if let selected { outcome(for: selected) }

            HStack(spacing: 10) {
                Button(action: onReject) {
                    Text("No")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(palette.neutralSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    if let selected { onConfirm(selected) }
                } label: {
                    Text(suggestion.needsLink ? "Sí, es \(friend.name)" : "Sí, era su pago")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(accent.color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(selected == nil)
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(accent.color.opacity(0.35), lineWidth: 1))
    }

    private var sentence: String {
        let verb = candidate.via == .plin ? "Plineaste" : (candidate.via == .yape ? "Yapeaste" : "Transferiste")
        let day = candidate.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
        return "\(verb) " + Money.format(candidate.amount, currency: candidate.currency)
            + " a " + candidate.payeeName + " · " + day
    }

    private var question: String {
        if suggestion.needsLink {
            return "¿\(candidate.payeeName) es \(friend.name)? Le debes "
                + Money.format(suggestion.shares.first?.remaining ?? 0, currency: candidate.currency)
        }
        return "¿Era para lo que le debes a \(friend.name)?"
    }

    private func shareOption(_ share: OwedShare) -> some View {
        let isOn = share.id == selected?.id
        return Button { selectedID = share.id } label: {
            HStack {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? accent.color : palette.tertiaryLabel)
                Text(share.merchant)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Spacer()
                Text(Money.format(share.remaining, currency: share.currency))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.label)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Qué pasa si dices que sí: salda, abona o sobra.
    private func outcome(for share: OwedShare) -> some View {
        let paid = Money.cents(candidate.amount)
        let owed = Money.cents(share.remaining)
        let text: String
        if paid == owed {
            text = "Salda la deuda de " + share.merchant + "."
        } else if paid < owed {
            text = "Abona " + Money.format(candidate.amount, currency: share.currency) + ". Quedarían "
                + Money.format(Money.subtract(share.remaining, candidate.amount), currency: share.currency) + "."
        } else {
            text = "Salda " + Money.format(share.remaining, currency: share.currency)
                + ". Lo demás no cuenta para esta deuda."
        }
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(palette.secondaryLabel)
    }
}
