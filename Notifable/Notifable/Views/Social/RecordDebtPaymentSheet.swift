import SwiftUI

/// «Registrar pago» desde Cobros: un amigo te pagó por fuera (efectivo, un
/// Yape cuyo correo no llegó). Todo o un abono; el monto se recorta a lo que
/// falta y la línea de abajo dice qué va a pasar antes de tocar «Registrar».
struct RecordDebtPaymentSheet: View {
    let share: ReceivableShare
    let friend: Friend
    /// El aviso que se enseña al volver: «Deuda de Joseph saldada».
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var receivables = FriendReceivables.shared

    private enum Mode: Hashable { case all, partial }
    @State private var mode: Mode = .all
    @State private var input = ""
    @State private var isSaving = false
    @State private var failed = false
    @FocusState private var amountFocused: Bool

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var typed: Double { Money.parse(input) ?? 0 }
    private var amount: Double { mode == .all ? share.remaining : min(typed, share.remaining) }
    private var canSave: Bool { !isSaving && (mode == .all || Money.cents(typed) > 0) }

    private func format(_ value: Double) -> String { Money.format(value, currency: share.currency) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(friend.name + " · " + share.merchant)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                    Text(format(share.remaining))
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.8)
                        .foregroundStyle(palette.label)
                    Text(Money.cents(share.paidAmount) > 0
                         ? "Falta de " + format(share.amount) + " · ya abonó " + format(share.paidAmount)
                         : "Lo que falta de la deuda")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .padding(.top, 8)
                .padding(.bottom, 4)

                ShellSegment(items: [Mode.all, Mode.partial], selection: $mode) {
                    $0 == .all ? "Pagó todo" : "Un abono"
                }

                if mode == .partial {
                    HStack(spacing: 8) {
                        Text(share.currency == "USD" ? "$" : "S/")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(palette.secondaryLabel)
                        TextField("0.00", text: $input)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 17, weight: .semibold))
                            .focused($amountFocused)
                            .onChange(of: input) { _, value in
                                let clean = TransactionDraft.sanitizedAmount(value)
                                if clean != value { input = clean }
                            }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(palette.hairline, lineWidth: 0.5))
                    .transition(.opacity)
                }

                Text(failed ? "No se pudo registrar. " + (receivables.lastErrorMessage ?? "Revisa tu conexión.")
                            : outcome)
                    .font(.system(size: 12.5))
                    .foregroundStyle(failed ? palette.negative : palette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)

                Button { Task { await save() } } label: {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().tint(.white).controlSize(.small) }
                        Text("Registrar")
                            .font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(accent.color.opacity(canSave ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .background(palette.background)
            .navigationTitle("Registrar pago")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: mode)
            .onChange(of: mode) { _, value in amountFocused = value == .partial }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.height(mode == .partial ? 400 : 340)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
    }

    /// Qué pasa si se registra: salda, abona o sobra.
    private var outcome: String {
        guard mode == .partial else { return "Salda la deuda. Pasa a Cobros cerrados como pagada." }
        if Money.cents(typed) <= 0 { return "Escribe cuánto te abonó." }
        if Money.cents(typed) >= Money.cents(share.remaining) {
            return "Salda " + format(share.remaining) + ". Lo demás no cuenta para esta deuda."
        }
        return "Abona " + format(typed) + ". Quedarían " + format(Money.subtract(share.remaining, typed)) + "."
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        failed = false
        defer { isSaving = false }
        let settles = Money.cents(amount) >= Money.cents(share.remaining)
        guard let applied = await receivables.recordPayment(share, amount: amount) else {
            failed = true
            return
        }
        onDone(settles ? "Deuda de " + friend.name + " saldada" : "Abono de " + format(applied) + " registrado")
        dismiss()
    }
}
