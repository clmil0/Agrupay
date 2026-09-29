import SwiftData
import SwiftUI

/// «Recordar un pago»: elegir la deuda, a quién y cuánto, en una sola hoja.
///
/// El monto es **opcional** a propósito: la mayoría de las veces basta con
/// «esto me lo debes» y los dos saben de cuánto era. Si se quiere repartir, el
/// interruptor divide en partes iguales **contándome a mí**, que es como se
/// parte una cuenta de verdad, y lo que no se reparte queda como mío.
struct ReminderComposerSheet: View {

    /// La deuda desde la que se abrió, si vino de su ficha.
    var initialDebt: Expense?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

    @State private var friendsManager = FriendsManager.shared
    @State private var reminders = PaymentReminders.shared

    @State private var debt: Expense?
    @State private var showsDebtPicker = false
    @State private var search = ""
    @State private var searchQuery = ""
    @State private var selected: Set<String> = []
    @State private var message = ReminderComposerSheet.defaultMessage
    @State private var intensity: PaymentReminder.Intensity = .soft
    @State private var splitEnabled = false
    /// Monto escrito por amigo. Lo que no esté aquí va sin cifra.
    @State private var amounts: [String: String] = [:]
    @State private var alreadySent: [String: PaymentReminders.SentInfo] = [:]
    @State private var isSending = false
    @State private var outcome: String?

    static let defaultMessage = "Yo a la firme no sé cómo es que creí en ti causa"

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    // MARK: - Datos

    /// Lo marcado por cobrar y todavía sin saldar: lo que se cobra casi siempre.
    private var debts: [Expense] {
        expenses.filter { $0.isDebt && Money.cents(Accounting.outstanding(of: $0)) > 0 }
    }

    /// El resto del historial, **sólo tras buscar**: montar miles de filas para
    /// que el 95 % de las veces se elija una de las de arriba es trabajo tirado.
    private var searchResults: [Expense] {
        guard searchQuery.count >= 2 else { return [] }
        return expenses
            .filter { !$0.isDebt && $0.merchant.localizedCaseInsensitiveContains(searchQuery) }
            .prefix(20)
            .map { $0 }
    }

    private var friends: [Friend] { friendsManager.friends }

    private var total: Double {
        guard let debt else { return 0 }
        let outstanding = Accounting.outstanding(of: debt)
        return Money.cents(outstanding) > 0 ? outstanding : debt.amount
    }

    private var currency: String { debt?.currency ?? "PEN" }

    /// Lo que suman los montos escritos.
    private var assigned: Double {
        Money.sum(Array(selected)) { amounts[$0].flatMap(Money.parse) ?? 0 }
    }

    /// Lo que queda para mí: repartir cuenta al que cobra.
    private var mine: Double { Money.subtract(total, assigned) }

    private var canSend: Bool {
        debt != nil && !sendableFriends.isEmpty && !isSending
            && !(splitEnabled && Money.cents(mine) < 0)
    }

    /// Los elegidos a los que hoy sí se les puede escribir.
    private var sendableFriends: [String] {
        selected.filter { alreadySent[$0]?.blocksToday != true }
    }

    // MARK: - Cuerpo

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    debtSection
                    friendsSection
                    messageSection
                    intensitySection
                    if debt != nil, !selected.isEmpty { splitSection }
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
            .navigationTitle("Recordar un pago")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { sendBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .appAppearance()
            .appTextSize()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(palette.background)
        .task {
            debt = initialDebt ?? debts.first
            await loadSentStatus()
        }
        .onChange(of: debt?.id) { _, _ in
            Task { await loadSentStatus() }
        }
    }

    // MARK: - Deuda

    @ViewBuilder
    private var debtSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: "Qué le recuerdas")

            if let debt, !showsDebtPicker {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsDebtPicker = true }
                } label: {
                    HStack(spacing: 12) {
                        MovementIcon(icon: MovementStyle.icon(for: debt),
                                     color: MovementStyle.color(for: debt, accent: accent.color, scheme: scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Accounting.displayName(debt.merchant))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.label)
                                .lineLimit(1)
                            Text(debt.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
                                 + " · " + Money.format(total, currency: currency))
                                .font(.system(size: 12.5))
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        Spacer(minLength: 8)
                        Text("Cambiar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5))
            } else {
                debtPicker
            }
        }
    }

    private var debtPicker: some View {
        VStack(spacing: 0) {
            if debts.isEmpty {
                Text("No tienes nada marcado por cobrar. Búscalo por comercio.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MovementCard {
                ForEach(Array(debts.prefix(12).enumerated()), id: \.element.id) { index, expense in
                    debtRow(expense)
                    if index < min(debts.count, 12) - 1 { MovementSeparator() }
                }
            }

            // «Otros»: el historial sólo aparece cuando se busca.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.secondaryLabel)
                    TextField("Otros · busca por comercio", text: $search)
                        .submitLabel(.search)
                        .onSubmit { searchQuery = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if !search.isEmpty {
                        Button {
                            search = ""
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(palette.secondaryLabel)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5))

                if !searchQuery.isEmpty {
                    if searchResults.isEmpty {
                        Text("Nada con «\(searchQuery)».")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.tertiaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MovementCard {
                            ForEach(Array(searchResults.enumerated()), id: \.element.id) { index, expense in
                                debtRow(expense)
                                if index < searchResults.count - 1 { MovementSeparator() }
                            }
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func debtRow(_ expense: Expense) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                debt = expense
                showsDebtPicker = false
                amounts = [:]
                splitEnabled = false
            }
        } label: {
            HStack(spacing: 12) {
                MovementIcon(icon: MovementStyle.icon(for: expense),
                             color: MovementStyle.color(for: expense, accent: accent.color, scheme: scheme),
                             size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Accounting.displayName(expense.merchant))
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(expense.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES"))))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 8)
                Text(Money.format(Accounting.outstanding(of: expense), currency: expense.currency))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Amigos

    @ViewBuilder
    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ShellSectionHeader(title: "A quién")
                Spacer()
                if friends.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let all = Set(friends.map(\.id))
                            selected = selected == all ? [] : all
                            if splitEnabled { splitEvenly() }
                        }
                    } label: {
                        Text(selected.count == friends.count ? "Ninguno" : "Todos")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(accent.onSurface(scheme))
                    }
                    .buttonStyle(.plain)
                }
            }

            if friends.isEmpty {
                Text("Todavía no tienes amigos aquí. Invita a alguien desde Amigos.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(friends) { friend in
                            friendChip(friend)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .padding(.horizontal, -2)
            }
        }
    }

    private func friendChip(_ friend: Friend) -> some View {
        let isOn = selected.contains(friend.id)
        let blocked = alreadySent[friend.id]?.blocksToday == true

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOn { selected.remove(friend.id); amounts[friend.id] = nil }
                else { selected.insert(friend.id) }
                if splitEnabled { splitEvenly() }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    FriendAvatar(friend: friend)
                        .overlay(
                            Circle().stroke(isOn ? accent.color : Color.clear, lineWidth: 2.5)
                                .padding(-2.5)
                        )
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 18, height: 18)
                            .background(accent.color, in: Circle())
                    }
                }

                Text(friend.name)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .regular))
                    .foregroundStyle(isOn ? palette.label : palette.secondaryLabel)
                    .lineLimit(1)
                    .frame(width: 66)
                    .multilineTextAlignment(.center)

                if blocked {
                    Text("hoy ya")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.warning)
                }
            }
            .opacity(blocked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(friend.name + (blocked ? ", ya se lo recordaste hoy" : ""))
    }

    // MARK: - Mensaje

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShellSectionHeader(title: "Mensaje")
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
            withAnimation(.easeOut(duration: 0.15)) { intensity = value }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
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

    // MARK: - Repartir

    private var splitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { splitEnabled }, set: { on in
                withAnimation(.easeInOut(duration: 0.2)) {
                    splitEnabled = on
                    if on { splitEvenly() } else { amounts = [:] }
                }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repartir la cuenta")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(splitEnabled
                         ? "En partes iguales, contándote a ti"
                         : "Sin monto: sólo el recordatorio")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
            .tint(accent.color)

            if splitEnabled {
                ForEach(friends.filter { selected.contains($0.id) }) { friend in
                    amountRow(friend)
                }

                HStack {
                    Text(mineLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Money.cents(mine) < 0 ? palette.negative : palette.secondaryLabel)
                    Spacer()
                    Button("Partes iguales") {
                        withAnimation(.easeInOut(duration: 0.2)) { splitEvenly() }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(palette.hairline, lineWidth: 0.5))
    }

    private var mineLabel: String {
        if Money.cents(mine) < 0 {
            return "Te pasaste " + Money.format(abs(mine), currency: currency)
        }
        return "Tú pones " + Money.format(mine, currency: currency)
    }

    private func amountRow(_ friend: Friend) -> some View {
        HStack(spacing: 10) {
            FriendAvatar(friend: friend, size: 34)

            Text(friend.name)
                .font(.system(size: 14.5))
                .foregroundStyle(palette.label)
                .lineLimit(1)

            Spacer(minLength: 8)

            TextField("0.00", text: Binding(
                get: { amounts[friend.id] ?? "" },
                set: { amounts[friend.id] = clampedAmount($0, for: friend.id) }
            ))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 90)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(palette.neutralSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Lo que se teclea para un amigo: sin signo, a lo más dos decimales
    /// (`sanitizedAmount`) y nunca más de lo que queda de la cuenta. Entre
    /// todos no pasan del total: lo mínimo que te toca a ti es 0.
    private func clampedAmount(_ input: String, for id: String) -> String {
        let text = TransactionDraft.sanitizedAmount(input)
        guard let value = Money.parse(text) else { return text }
        let others = Money.sum(Array(selected.filter { $0 != id })) { amounts[$0].flatMap(Money.parse) ?? 0 }
        let available = max(0, Money.subtract(total, others))
        return Money.cents(value) > Money.cents(available) ? Money.decimalText(available) : text
    }

    /// En partes iguales contando a quien cobra: la cuenta de 120 entre dos
    /// amigos y yo son 40 cada uno.
    private func splitEvenly() {
        let people = selected.count + 1
        guard people > 1, Money.cents(total) > 0 else { return }
        let share = Money.normalized(total / Double(people))
        for id in selected { amounts[id] = Money.decimalText(share) }
    }

    // MARK: - Enviar

    private var sendBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            Button {
                Task { await send() }
            } label: {
                HStack(spacing: 8) {
                    if isSending { ProgressView().tint(.white).controlSize(.small) }
                    Text(sendTitle)
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(accent.color.opacity(canSend ? 1 : 0.4),
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

    private var sendTitle: String {
        let count = sendableFriends.count
        if debt == nil { return "Elige qué le recuerdas" }
        if selected.isEmpty { return "Elige a quién" }
        if count == 0 { return "Ya se lo recordaste hoy" }
        return count == 1 ? "Enviar recordatorio" : "Enviar a \(count) amigos"
    }

    private func loadSentStatus() async {
        guard let debt else { return }
        alreadySent = await reminders.sentStatus(debtKey: TransactionKey.key(for: debt))
    }

    private func send() async {
        guard let debt else { return }
        isSending = true
        defer { isSending = false }

        var byFriend: [String: Double] = [:]
        if splitEnabled {
            for id in sendableFriends {
                if let value = amounts[id].flatMap(Money.parse), Money.cents(value) > 0 {
                    byFriend[id] = value
                }
            }
        }

        let result = await reminders.send(
            debtKey: TransactionKey.key(for: debt),
            merchant: Accounting.displayName(debt.merchant),
            occurredOn: debt.date,
            currency: currency,
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            intensity: intensity,
            to: sendableFriends,
            amounts: byFriend
        )

        if result.failed {
            outcome = "No se pudo enviar. " + (reminders.lastErrorMessage ?? "Revisa tu conexión.")
            return
        }

        await loadSentStatus()

        if result.delivered > 0 {
            dismiss()
        } else {
            outcome = "Ya se lo recordaste hoy. Mañana puedes volver a hacerlo."
        }
    }
}
