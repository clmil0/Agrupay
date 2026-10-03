import SwiftUI
import SwiftData

/// Las piezas de Amigos dentro de Social (`2c`).
///
/// Viven en dos vistas y no en una: en la pantalla fusionada, lo que se hace
/// —invitar, cobrar, contestar— va arriba, y la lista de amigos al final,
/// después de lo que te comparten. Cada una guarda su propio estado y sus
/// propias hojas, así que el orden se decide en `SocialView` y aquí no hay que
/// tocar nada.

/// Invitar y cobrar, los cobros que te recuerdan y las solicitudes. «Te
/// deben» y «Lo que debes» viven en la pestaña Cobros (`ReceivablesView`).
struct FriendsActionsSection: View {

    @Environment(\.colorScheme) private var scheme
    @State private var friendsManager = FriendsManager.shared
    @State private var auth = SupabaseAuthManager.shared
    @State private var inviteRouter = FriendInviteRouter.shared
    @State private var reminders = PaymentReminders.shared

    @State private var showInviteSheet = false
    @State private var showsComposer = false
    @State private var showGmailSettings = false
    @State private var invitedCode: String?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var hidesForGoogle: Bool {
        #if DEBUG
        // Modo QA: amigos y cobros inventados, sin cuenta.
        if QAMode.isOn { return false }
        #endif
        return auth.needsGoogleAccount
    }

    var body: some View {
        VStack(spacing: 14) {
            if hidesForGoogle {
                needsGoogle
            } else {
                actions
                remindersSection
                requestsSection
            }
        }
        .onChange(of: auth.isReady) { _, ready in
            guard ready else { return }
            presentPendingInvite()
        }
        .onChange(of: inviteRouter.pendingCode) { _, _ in presentPendingInvite() }
        .task { await reminders.refresh() }
        .sheet(isPresented: $showsComposer) {
            // Lo enviado aparece en Cobros al cambiar de pestaña.
            ReminderComposerSheet(request: ReminderComposerRequest()) { _ in
                Task { await FriendReceivables.shared.refresh() }
            }
        }
        .sheet(isPresented: $showInviteSheet, onDismiss: { invitedCode = nil }) {
            AddFriendSheet(invitedCode: invitedCode, startsOnRedeem: invitedCode != nil)
        }
        .sheet(isPresented: $showGmailSettings) {
            NavigationStack { GmailBanksView() }
                .appAppearance()
                .appTextSize()
        }
    }

    // MARK: - Acciones

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showInviteSheet = true
            } label: {
                actionLabel(icon: "person.badge.plus", title: "Invitar", filled: true)
            }
            .buttonStyle(.plain)

            // «Usar una invitación» ya no compite aquí: vive al pie de la
            // hoja de invitar, plegada, que es donde se busca cuando alguien
            // te pasó un código.
            // Cobrar desde aquí: la deuda se elige dentro. También está en
            // Cobros, junto a lo que te deben.
            Button {
                showsComposer = true
            } label: {
                actionLabel(icon: "bell.badge", title: "Cobrar", filled: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func actionLabel(icon: String, title: String, filled: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(filled ? Color.white : palette.label)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(filled ? AnyShapeStyle(accent.color) : AnyShapeStyle(palette.surface), in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.clear : palette.hairline, lineWidth: 0.5))
    }

    // MARK: - Sin Google (2g)

    private var needsGoogle: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(palette.tertiaryLabel)

            Text("Amigos necesita tu cuenta de Google")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.label)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Text("Conecta tu correo de Google para que nadie pueda hacerse pasar por ti. Es la misma cuenta que lee tus correos del banco.")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .padding(.top, 8)

            Button {
                GmailAuthService.shared.signIn()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Conectar Gmail")
                        .font(.system(size: 15.5, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 22)
                .frame(height: 50)
                .background(accent.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 22)

            Button("Ver Ajustes → Correo y bancos") { showGmailSettings = true }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }

    // MARK: - Recordatorios de cobro

    /// Lo que un amigo te recuerda que le debes. No mueve nada de tus
    /// cuentas: se lee y se cierra. Lo que llegó desde la última visita entra
    /// con destello y saltito (`1b` de «Cobros entre amigos»).
    @ViewBuilder
    private var remindersSection: some View {
        let inbox = reminders.inbox
        if !inbox.isEmpty {
            VStack(spacing: 0) {
                ShellSectionHeader(title: inbox.count == 1 ? "Te recuerdan un pago"
                                                           : "Te recuerdan \(inbox.count) pagos",
                                   trailing: inbox.first.map { Self.arrived($0.createdAt) },
                                   trailingTint: accent.onSurface(scheme))
                MovementCard {
                    ForEach(Array(inbox.enumerated()), id: \.element.id) { index, reminder in
                        ReminderRow(reminder: reminder,
                                    friend: friendsManager.friend(with: reminder.fromUser),
                                    isNew: reminders.isNewArrival(reminder),
                                    onSeen: { reminders.markArrivalSeen(reminder) },
                                    onDone: { Task { await reminders.dismiss(reminder) } })
                            .id(reminder.arrivalKey)
                        if index < inbox.count - 1 { MovementSeparator() }
                    }
                }
            }
        }
    }

    /// «ahora», «hace 5 min», «hace 3 h», «ayer», «hace 4 días».
    private static func arrived(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "ahora" }
        if seconds < 3600 { return "hace \(Int(seconds / 60)) min" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "hace \(Int(seconds / 3600)) h" }
        if calendar.isDateInYesterday(date) { return "ayer" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        return "hace \(days) días"
    }

    // MARK: - Solicitudes (2c)

    @ViewBuilder
    private var requestsSection: some View {
        let incoming = friendsManager.incomingRequests
        let outgoing = friendsManager.outgoingRequests
        if !incoming.isEmpty || !outgoing.isEmpty {
            VStack(spacing: 0) {
                ShellSectionHeader(title: "Solicitudes",
                                   trailing: incoming.isEmpty ? nil
                                       : incoming.count == 1 ? "1 recibida" : "\(incoming.count) recibidas")
                MovementCard {
                    ForEach(Array(incoming.enumerated()), id: \.element.id) { index, request in
                        incomingRow(request)
                        if index < incoming.count - 1 || !outgoing.isEmpty { MovementSeparator() }
                    }
                    ForEach(Array(outgoing.enumerated()), id: \.element.id) { index, request in
                        outgoingRow(request)
                        if index < outgoing.count - 1 { MovementSeparator() }
                    }
                }
            }
        }
    }

    private func incomingRow(_ request: FriendRequest) -> some View {
        let look = request.penguin ?? PenguinLook()
        return HStack(spacing: 12) {
            PenguinAvatar(look: look, size: 44, background: palette.neutralSurface)

            VStack(alignment: .leading, spacing: 2) {
                Text(request.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(look.animal?.name ?? "Pingüino")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Rechazar") {
                Task { await friendsManager.respond(to: request, accept: false) }
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(palette.secondaryLabel)
            .fixedSize()

            Button {
                Task { await friendsManager.respond(to: request, accept: true) }
            } label: {
                Text("Aceptar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(accent.color, in: Capsule())
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func outgoingRow(_ request: FriendRequest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 18))
                .foregroundStyle(palette.tertiaryLabel)
                .frame(width: 44, height: 44)
                .background(palette.track, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Esperando a \(request.displayName)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
                Text(Self.since(request.createdAt))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await friendsManager.cancel(request) }
            } label: {
                Text("Retirar")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(palette.neutralSurface, in: Capsule())
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// «Desde hoy», «Desde ayer», «Desde hace 3 días».
    private static func since(_ date: Date?) -> String {
        guard let date else { return "Enviada" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Desde hoy" }
        if calendar.isDateInYesterday(date) { return "Desde ayer" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: Date())).day ?? 0
        return "Desde hace \(days) días"
    }

    // MARK: - Invitación

    /// Sin sesión no se puede canjear: el código espera en el router hasta que
    /// `auth.isReady`.
    private func presentPendingInvite() {
        guard auth.isReady, inviteRouter.pendingCode != nil, let code = inviteRouter.take() else { return }
        invitedCode = code
        showInviteSheet = true
    }
}

/// La lista de amigos, al final de Social.
struct FriendsRosterSection: View {

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var auth = SupabaseAuthManager.shared
    @State private var selectedFriend: Friend?

    init() {
        let window = Period(granularity: .mes, reference: Date()).dataWindow()
        let start = window.start
        let end = window.end
        _expenses = Query(filter: #Predicate<Expense> { $0.date >= start && $0.date < end },
                          sort: \Expense.date, order: .reverse)
    }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var totals: PeriodTotals {
        Accounting.totals(expenses: expenses, incomes: [],
                          period: Period(granularity: .mes, reference: Date()),
                          usdToPen: rates.usdToPenRate)
    }

    var body: some View {
        let friends = friendsManager.friends

        VStack(spacing: 0) {
            if friends.isEmpty {
                if !auth.needsGoogleAccount {
                    ShellEmptyState(icon: "person.2",
                                    title: "Todavía no tienes amigos aquí",
                                    message: "Crea una invitación o usa la de alguien para empezar.")
                }
            } else {
                ShellSectionHeader(title: friends.count == 1 ? "1 amigo" : "\(friends.count) amigos")
                MovementCard {
                    ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                        friendRow(friend)
                        if index < friends.count - 1 { MovementSeparator() }
                    }
                }
            }
        }
        .sheet(item: $selectedFriend) { friend in
            FriendProfileView(friend: friend, totals: totals,
                              incoming: friendsManager.acceptedIncoming.first { $0.sharerID == friend.id })
        }
    }

    // MARK: - Fila

    private func friendRow(_ friend: Friend) -> some View {
        let state = shareState(with: friend)

        return Button {
            selectedFriend = friend
        } label: {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend)

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: state.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(state.label)
                            .font(.system(size: 12.5))
                    }
                    .foregroundStyle(palette.secondaryLabel)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Los cuatro estados posibles de una amistad, dichos desde mi lado.
    private func shareState(with friend: Friend) -> (icon: String, label: String) {
        let mine = friendsManager.myShare(toward: friend.id)
        let iShare = (mine?.shareTotal ?? false) || !(mine?.shareCategories.isEmpty ?? true)
        let theyShare = friendsManager.acceptedIncoming.contains { $0.sharerID == friend.id }
        let theyOffered = friendsManager.pendingIncoming.contains { $0.sharerID == friend.id }

        switch (iShare, theyShare) {
        case (true, true):   return ("arrow.left.arrow.right", "Recíproco")
        case (true, false):  return theyOffered
            ? ("clock", "Te quiere compartir")
            : ("arrow.right", "Sólo tú le compartes")
        case (false, true):  return ("arrow.left", "Sólo él te comparte")
        case (false, false): return ("minus", "Sin compartir")
        }
    }
}

// MARK: - Recordatorio

/// Un cobro que te recuerdan. Si llegó desde la última visita entra con la
/// animación del modo suave: aparece bajando 8 pt, un destello del tema que
/// se apaga en 3 s y un saltito del avatar. «Listo» lo desvanece y lo cierra.
private struct ReminderRow: View {
    let reminder: PaymentReminder
    let friend: Friend
    let isNew: Bool
    let onSeen: () -> Void
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var origin: Date?
    @State private var running = false
    @State private var leaving = false

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private enum Channel: Hashable { case rowOpacity, rowY, wash, hopSX, hopSY, hopY }

    /// Los tiempos del diseño con 200 ms menos de espera: aquí la fila ya
    /// llega tras el paso de pantalla, y más espera dejaba la tarjeta vacía.
    private static let arrival: KeyMotion<Channel> = {
        var m = KeyMotion<Channel>(rest: [.rowOpacity: 1, .hopSX: 1, .hopSY: 1])
        m.add([(0, [.rowOpacity: 0, .rowY: -8]), (1, [.rowOpacity: 1, .rowY: 0])],
              at: 300, duration: 480, curve: .css(0.2, 0.8, 0.3, 1))
        m.add([(0, [.wash: 0]), (0.08, [.wash: 1]), (0.35, [.wash: 1]), (1, [.wash: 0])],
              at: 360, duration: 3400, curve: .cssEaseOut)
        m.add([(0, [:]), (0.18, [.hopSX: 1.1, .hopSY: 0.88]), (0.42, [.hopY: -9, .hopSX: 0.94, .hopSY: 1.08]),
               (0.66, [.hopSX: 1.08, .hopSY: 0.92]), (0.82, [.hopSX: 0.98, .hopSY: 1.02]), (1, [:])],
              at: 850, duration: 620, curve: .cssEaseInOut)
        return m
    }()

    var body: some View {
        TimelineView(.animation(paused: !running)) { context in
            // Antes del primer fotograma ya escondida: si no, destella.
            let t: Double? = running ? origin.map { context.date.timeIntervalSince($0) * 1000 }
                                     : (isNew && origin == nil ? 0 : nil)
            let v = { (channel: Channel) in
                t.map { Self.arrival.value(channel, at: $0) } ?? (Self.arrival.rest[channel] ?? 0)
            }
            content(v)
        }
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving ? 0.97 : 1)
        .onAppear {
            guard isNew, origin == nil else { return }
            origin = Date()
            running = true
            onSeen()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrival.end / 1000) { running = false }
        }
    }

    private func content(_ v: (Channel) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend)
                    .scaleEffect(x: v(.hopSX), y: v(.hopSY), anchor: .bottom)
                    .offset(y: v(.hopY))

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name + " te recuerda un pago")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)

                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let amount = reminder.amount {
                    Text(Money.format(amount, currency: reminder.currency))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.label)
                }
            }

            if !reminder.message.isEmpty {
                Text("«" + reminder.message + "»")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button {
                    withAnimation(.easeIn(duration: 0.26)) { leaving = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: onDone)
                } label: {
                    Text("Listo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent.onSurface(scheme))
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(accent.color.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(leaving)
            }
        }
        .padding(14)
        .background(accent.color.opacity(0.16 * v(.wash)))
        .opacity(v(.rowOpacity))
        .offset(y: v(.rowY))
    }

    private var detail: String {
        guard let day = reminder.occurredOn else { return reminder.merchant }
        return reminder.merchant + " · " + day.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "es_ES")))
    }
}
