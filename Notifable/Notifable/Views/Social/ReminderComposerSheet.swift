import SwiftUI

/// «Recordar a Joseph» («Soluciones de cobro», 05): la deuda ya existe desde
/// que se compartió el gasto, así que aquí sólo va el mensaje y qué tan
/// fuerte se le cobra. Ya no crea deudas ni pide montos.
struct ReminderComposerSheet: View {
    let share: ReceivableShare
    /// Se mandó: el nombre de a quién.
    var onSent: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var friendsManager = FriendsManager.shared
    @State private var reminders = PaymentReminders.shared
    @State private var message = ReminderComposerSheet.defaultMessage
    /// Arranca con la de Notificaciones › Al cobrarle a un amigo.
    @State private var intensity: PaymentReminder.Intensity = NotificationSettings.defaultIntensity
    @AppStorage(ProStore.enabledKey) private var isPro = false
    @State private var paywall: ProStore.Feature?
    @State private var isSending = false
    @State private var outcome: String?

    static let defaultMessage = "Yo a la firme no sé cómo es que creí en ti causa"

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var friend: Friend { friendsManager.friend(with: share.debtor) }
    private var canSend: Bool { !isSending && !share.sentToday }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DebtPayHead(title: friend.name + " · " + share.merchant,
                                amount: Money.format(share.remaining, currency: share.currency),
                                detail: "Te debe desde el " + ReceivablesView.dayShort(share.date))
                    messageSection
                    intensitySection
                    if let outcome {
                        ShellNote(icon: "exclamationmark.circle", text: outcome)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(palette.background)
            .navigationTitle("Recordar a " + friend.name)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { sendBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .proPaywall($paywall)
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .trackScreen("reminder_composer", feature: .paymentReminder)
    }

    // MARK: - Mensaje

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: "Mensaje · opcional")
            TextField("Escríbele algo", text: $message, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .padding(13)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5))
                .onChange(of: message) { _, value in
                    if value.count > 240 { message = String(value.prefix(240)) }
                }
        }
    }

    // MARK: - Intensidad

    /// Quien cobra elige qué tan fuerte cobra (`1` de «Cobros entre amigos»).
    private var intensitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: "¿Qué tan fuerte le cobras?")
            HStack(spacing: 10) {
                intensityOption(.soft, icon: "bell",
                                title: "Suave",
                                detail: "Le llega una notificación y lo ve en su lista de Amigos")
                intensityOption(.intense, icon: "bell.and.waves.left.and.right",
                                title: "Intenso",
                                detail: "Además, cuando abra la app, tu pingüino le aparece en pantalla cobrándole")
            }
        }
    }

    private func intensityOption(_ value: PaymentReminder.Intensity, icon: String,
                                 title: String, detail: String) -> some View {
        let selected = intensity == value
        return Button {
            // «Intenso» es de Pro: sin él, se abre el paywall y queda «Suave».
            guard value == .soft || isPro else { paywall = .alerts; return }
            withAnimation(.easeOut(duration: 0.15)) { intensity = value }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if value == .intense && !isPro { ProBadge() }
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? accent.color : palette.tertiaryLabel)
                }
                .foregroundStyle(selected ? accent.onSurface(scheme) : palette.label)

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? accent.color.opacity(0.12) : palette.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? accent.color.opacity(0.5) : palette.hairline, lineWidth: selected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Enviar

    private var sendBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if isSending {
                        ProgressView().tint(accent.buttonText).controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(share.sentToday ? "Ya se lo recordaste hoy" : "Enviar")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(accent.buttonFill.opacity(canSend ? 1 : 0.4),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(palette.background)
    }

    private func send() async {
        isSending = true
        defer { isSending = false }

        // El monto original de su parte: así el disparador del servidor no la
        // toca (`debt_share_from_reminder` nunca la baja de lo pagado).
        let result = await reminders.send(
            debtKey: share.debtKey,
            merchant: share.merchant,
            occurredOn: share.occurredOn,
            currency: share.currency,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            intensity: isPro ? intensity : .soft,
            to: [share.debtor],
            amounts: [share.debtor: share.amount]
        )

        if result.failed {
            Analytics.error("payment_reminder", code: "send_failed")
            outcome = "No se pudo enviar. " + (reminders.lastErrorMessage ?? "Revisa tu conexión.")
            return
        }
        Analytics.track(.featureUsed, ["feature": AppFeature.paymentReminder.rawValue, "action": "sent",
                                       "friends": 1, "intense": isPro && intensity == .intense])
        if isPro, intensity == .intense { Analytics.proFeatureUsed(.alerts) }

        if result.delivered > 0 {
            onSent?(friend.name)
            dismiss()
        } else {
            outcome = "Ya se lo recordaste hoy. Mañana puedes volver a hacerlo."
        }
    }
}

/// La cabecera de las hojas de una deuda: «Valentín · Cevichería El Muelle»,
/// el monto grande y qué es ese monto.
struct DebtPayHead: View {
    let title: String
    let amount: String
    let detail: String

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
            Text(amount)
                .font(.system(size: 32, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(palette.label)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
