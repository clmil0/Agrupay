import SwiftData
import SwiftUI

/// Social › Cobros («Social Cobros.dc.html»): lo que te deben y lo que debes.
///
/// «Te deben» va agrupado por amigo, de quien más debe a quien menos, con
/// cuántas veces y cuándo le cobraste cada deuda. Lo cerrado (pagado,
/// perdonado, archivado) se pliega al pie. Debajo, «Lo que debes»
/// (`FriendDebtsSection`), que antes vivía en Amigos.
///
/// Cobrar algo nuevo va en la cifra «Cobrar» del resumen o, sin deudas
/// abiertas, en el botón de debajo del vacío.
struct ReceivablesView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    @Environment(\.modelContext) private var modelContext

    @State private var receivables = FriendReceivables.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var auth = SupabaseAuthManager.shared

    @State private var expandedFriendID: String?
    @State private var didAutoExpand = false
    @State private var showsClosed = false
    @State private var composer: ReminderComposerRequest?
    @State private var paying: ReceivableShare?
    @State private var managing: ReceivableShare?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private var palette: Palette { Palette(scheme).themed(proTheme) }
    private var accent: AppThemeColor { .current }

    private var hidesForGoogle: Bool {
        #if DEBUG
        if QAMode.isOn { return false }
        #endif
        return auth.needsGoogleAccount
    }

    var body: some View {
        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 14) {
                if hidesForGoogle {
                    ShellEmptyState(icon: "person.crop.circle.badge.xmark",
                                    title: "Cobros necesita tu cuenta de Google",
                                    message: "Conéctala desde Amigos para cobrarle a tus amigos y ver lo que te deben.")
                } else {
                    owedToMe
                    FriendDebtsSection()
                    if let error = receivables.lastErrorMessage {
                        ShellNote(icon: "exclamationmark.circle", text: error)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, ShellMetrics.sideInset)
            .padding(.top, ShellMetrics.contentTopInset)
            .padding(.bottom, ShellMetrics.contentBottomInset)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            progress.update(offset)
        }
        .overlay(alignment: .top) { toastView }
        .task { await receivables.refresh() }
        .onChange(of: groups.first?.friendID, initial: true) { _, first in
            // La primera vez se abre el amigo que más debe, como en el diseño.
            guard !didAutoExpand, let first else { return }
            didAutoExpand = true
            expandedFriendID = first
        }
        .animation(.easeInOut(duration: 0.22), value: receivables.shares)
        .sheet(item: $composer) { request in
            ReminderComposerSheet(request: request) { names in
                if let friendID = request.friendID { expandedFriendID = friendID }
                flash(names.count == 1 ? "Recordatorio enviado a " + names[0] : "Recordatorios enviados")
                Task { await receivables.refresh() }
            }
        }
        .sheet(item: $paying) { share in
            RecordDebtPaymentSheet(share: share, friend: friendsManager.friend(with: share.debtor)) { message in
                flash(message)
            }
        }
        .confirmationDialog(managing.map { $0.merchant + " · " + Money.format($0.remaining, currency: $0.currency) } ?? "",
                            isPresented: Binding(get: { managing != nil }, set: { if !$0 { managing = nil } }),
                            titleVisibility: .visible,
                            presenting: managing) { share in
            let name = friendsManager.friend(with: share.debtor).name
            Button("Perdonar deuda", role: .destructive) {
                Task {
                    if await receivables.close(share, as: .forgiven) {
                        flash("Le perdonaste la deuda a " + name)
                    }
                }
            }
            Button("Archivar sin avisar") {
                Task {
                    if await receivables.close(share, as: .archived) { flash("Deuda archivada") }
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { share in
            Text("Perdonar la cierra y le avisa a \(friendsManager.friend(with: share.debtor).name). Archivar solo la quita de tu lista.")
        }
    }

    // MARK: - Datos

    private struct FriendGroup: Identifiable {
        let friendID: String
        let shares: [ReceivableShare]
        var id: String { friendID }

        var remaining: Double { Money.sum(shares) { $0.remaining } }
        var reminders: [Date] { shares.flatMap(\.reminders).sorted() }
        var oldest: Date { shares.map(\.date).min() ?? Date() }
        var sentToday: Bool { shares.contains(where: \.sentToday) }
        var currency: String { shares.first?.currency ?? "PEN" }
    }

    /// De quien más debe a quien menos; dentro, de la deuda más vieja a la
    /// más nueva.
    private var groups: [FriendGroup] {
        Dictionary(grouping: receivables.open, by: \.debtor)
            .map { FriendGroup(friendID: $0.key, shares: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.remaining > $1.remaining }
    }

    /// Las cifras del resumen suman una sola moneda: la de soles si hay
    /// varias. Casi siempre es una.
    private var summaryCurrency: String {
        let currencies = Set(receivables.open.map(\.currency))
        return currencies.count == 1 ? currencies.first! : "PEN"
    }

    private var summaryShares: [ReceivableShare] {
        receivables.open.filter { $0.currency == summaryCurrency }
    }

    // MARK: - Te deben

    @ViewBuilder
    private var owedToMe: some View {
        let groups = groups
        let closed = receivables.closed

        if !receivables.hasLoaded && receivables.shares.isEmpty {
            ShellCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Cargando lo que te deben…")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
        } else if groups.isEmpty && closed.isEmpty {
            ShellCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nadie te debe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text("Cuando le cobres a un amigo con monto, su deuda aparece aquí con cada vez que le recordaste.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            newChargeButton
        } else {
            VStack(spacing: 10) {
                if groups.isEmpty { newChargeButton } else { summaryCard(groups) }

                MovementCard {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { MovementSeparator() }
                        friendRow(group)
                    }
                    if !closed.isEmpty {
                        if !groups.isEmpty {
                            Rectangle().fill(palette.separator).frame(height: 0.5)
                        }
                        closedSection(closed)
                    }
                }
            }
        }
    }

    // MARK: Resumen

    private func summaryCard(_ groups: [FriendGroup]) -> some View {
        let shares = summaryShares
        let currency = summaryCurrency
        let total = Money.sum(shares) { $0.remaining }
        let original = Money.sum(shares) { $0.amount }
        let paid = Money.sum(shares) { $0.paidAmount }
        let calendar = Calendar.current
        let thisMonth = receivables.shares.flatMap(\.reminders)
            .filter { calendar.isDate($0, equalTo: Date(), toGranularity: .month) }.count
        let oldest = receivables.open.map { Self.days(since: $0.date) }.max() ?? 0
        let debts = receivables.open.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Te deben")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                    Text(Money.format(total, currency: currency))
                        .font(.system(size: 28, weight: .bold, design: proTheme?.numberDesign ?? .default))
                        .tracking(-0.5)
                        .foregroundStyle(palette.label)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text((groups.count == 1 ? "1 amigo · " : "\(groups.count) amigos · ")
                     + (debts == 1 ? "1 deuda" : "\(debts) deudas"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.bottom, 5)
            }

            VStack(spacing: 6) {
                PaceBar(fraction: original > 0 ? paid / original : 0)
                HStack {
                    Text("Abonado " + Money.format(paid, currency: currency))
                    Spacer()
                    Text("de " + Money.format(original, currency: currency))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryLabel)
            }

            HStack(spacing: 6) {
                summaryTile(value: "\(thisMonth)",
                            label: "cobros en " + Self.monthShort(Date()))
                summaryTile(value: oldest == 1 ? "1 día" : "\(oldest) días",
                            label: "la más antigua",
                            tint: oldest > 14 ? palette.warning : nil)
                Button { remindNext() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "bell.badge")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Cobrar")
                                .font(.system(size: 15, weight: .bold))
                        }
                        Text("a un amigo ›")
                            .font(.system(size: 11, weight: .medium))
                            .opacity(0.9)
                    }
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(accent.buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private func summaryTile(value: String, label: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint ?? palette.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(palette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Por amigo

    private func friendRow(_ group: FriendGroup) -> some View {
        let friend = friendsManager.friend(with: group.friendID)
        let isOpen = expandedFriendID == group.friendID
        let reminders = group.reminders
        let oldest = Self.days(since: group.oldest)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    expandedFriendID = isOpen ? nil : group.friendID
                }
            } label: {
                HStack(spacing: 12) {
                    FriendAvatar(friend: friend)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.name)
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(palette.label)
                            .lineLimit(1)
                        Text((group.shares.count == 1 ? group.shares[0].merchant : "\(group.shares.count) deudas")
                             + " · hace " + (oldest == 1 ? "1 día" : "\(oldest) días"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                        Group {
                            if group.sentToday {
                                Text("Hoy ya le cobraste · van \(reminders.count)")
                                    .foregroundStyle(palette.positive)
                            } else if let last = reminders.last {
                                Text("Cobrado " + Self.times(reminders.count) + " · último " + Self.relative(last))
                                    .foregroundStyle(accent.onSurface(scheme))
                            } else {
                                Text("Nunca le cobraste")
                                    .foregroundStyle(accent.onSurface(scheme))
                            }
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Money.format(group.remaining, currency: group.currency))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(palette.label)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.tertiaryLabel)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Plegar" : "Ver sus deudas")

            if isOpen {
                VStack(spacing: 0) {
                    ForEach(group.shares) { share in
                        debtRow(share, friend: friend)
                    }
                }
                .padding(.leading, 66)
                .padding(.trailing, 14)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    private func debtRow(_ share: ReceivableShare, friend: Friend) -> some View {
        let age = Self.days(since: share.date)
        let isPartial = Money.cents(share.paidAmount) > 0

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(share.merchant)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Money.format(share.remaining, currency: share.currency))
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(palette.label)
            }

            HStack(spacing: 6) {
                Text(Self.dayShort(share.date) + " ·")
                    .foregroundStyle(palette.secondaryLabel)
                Text(age == 0 ? "hoy" : age == 1 ? "ayer" : "\(age) días")
                    .fontWeight(age > 14 ? .semibold : .regular)
                    .foregroundStyle(age > 14 ? palette.warning : palette.secondaryLabel)
                if isPartial {
                    chip("Abonó " + Money.format(share.paidAmount, currency: share.currency)
                         + " de " + Money.format(share.amount, currency: share.currency),
                         fg: palette.warning, bg: palette.warning.opacity(0.12))
                } else {
                    chip("Pendiente", fg: palette.secondaryLabel, bg: palette.track)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(1)

            VStack(alignment: .leading, spacing: 5) {
                Text(share.reminders.isEmpty ? "Todavía no le cobras" : "Le cobraste " + Self.times(share.reminders.count))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                if !share.reminders.isEmpty {
                    TagFlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(share.reminders.reversed(), id: \.self) { day in
                            if Calendar.current.isDateInToday(day) {
                                chip("Hoy", fg: palette.positive, bg: palette.positive.opacity(0.12))
                            } else {
                                chip(Self.dayShort(day), fg: palette.secondaryLabel, bg: palette.neutralSurface)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 6) {
                if share.sentToday {
                    pill("Enviado hoy", style: .done) {}
                        .disabled(true)
                } else {
                    pill("Recordar", style: .filled) { remind(share) }
                }
                pill("Registrar pago", style: .outline) { paying = share }
                Spacer(minLength: 0)
                Button { managing = share } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(palette.secondaryLabel)
                        .frame(width: 32, height: 32)
                        .background(palette.background, in: Circle())
                        .overlay(Circle().stroke(palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Más opciones")
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.separator).frame(height: 0.5)
        }
    }

    // MARK: Cerrados

    private func closedSection(_ closed: [ReceivableShare]) -> some View {
        let recovered = Money.sum(closed.filter { $0.status == .paid && $0.currency == summaryCurrency }) { $0.amount }

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showsClosed.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cobros cerrados")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(palette.label)
                        Text((closed.count == 1 ? "1 cerrada" : "\(closed.count) cerradas")
                             + " · recuperaste " + Money.format(recovered, currency: summaryCurrency))
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.tertiaryLabel)
                        .rotationEffect(.degrees(showsClosed ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsClosed {
                ForEach(closed) { share in
                    MovementSeparator()
                    closedRow(share)
                }
                .transition(.opacity)
            }
        }
    }

    private func closedRow(_ share: ReceivableShare) -> some View {
        let friend = friendsManager.friend(with: share.debtor)
        let (title, label, tint): (String, String, Color) = switch share.status {
        case .forgiven: ("Perdonaste a " + friend.name, "Perdonada", palette.secondaryLabel)
        case .archived: ("Archivada · " + friend.name, "Archivada", palette.tertiaryLabel)
        default:        (friend.name + " te pagó", "Pagada", palette.positive)
        }
        var detail = share.merchant
        if let closedOn = share.closedOn { detail += " · " + Self.dayShort(closedOn) }
        if let via = share.via, ["Yape", "Plin"].contains(via) { detail += " · " + via }
        detail += " · " + (share.reminders.isEmpty ? "sin cobros" : Self.times(share.reminders.count))

        return HStack(spacing: 12) {
            FriendAvatar(friend: friend, size: 38)
                .padding(.horizontal, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(Money.format(share.amount, currency: share.currency))
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .strikethrough()
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Piezas

    /// Sin deudas abiertas no hay resumen ni su cifra «Cobrar»: el cobro
    /// nuevo entra por aquí.
    private var newChargeButton: some View {
        Button { remindNext() } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 13, weight: .semibold))
                Text("Cobrar a un amigo")
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .foregroundStyle(accent.buttonText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(accent.buttonFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
            .fixedSize()
    }

    private enum PillStyle { case filled, outline, done }

    private func pill(_ title: String, style: PillStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style == .filled ? Color.white
                                 : style == .done ? palette.secondaryLabel : accent.onSurface(scheme))
                .padding(.horizontal, style == .filled ? 14 : 12)
                .frame(height: 32)
                .background(style == .filled ? AnyShapeStyle(accent.color)
                            : style == .done ? AnyShapeStyle(palette.track) : AnyShapeStyle(palette.background),
                            in: Capsule())
                .overlay(Capsule().stroke(style == .outline ? palette.hairline : .clear, lineWidth: 0.5))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.label, in: Capsule())
                .padding(.top, ShellMetrics.headerHeight + 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Acciones

    private func remind(_ share: ReceivableShare) {
        guard let request = ReminderComposerRequest.forShare(share, in: modelContext) else {
            flash("Ese gasto ya no está en tu historial")
            return
        }
        composer = request
    }

    /// «Cobrar a un amigo»: la deuda más antigua sin cobrar hoy, o el
    /// compositor vacío para cobrar algo nuevo.
    private func remindNext() {
        let next = receivables.open.filter { !$0.sentToday }.min { $0.date < $1.date }
        composer = next.flatMap { ReminderComposerRequest.forShare($0, in: modelContext) }
            ?? ReminderComposerRequest()
    }

    private func flash(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    // MARK: - Formatos

    private static let spanish = Locale(identifier: "es_ES")

    /// «15 sept».
    static func dayShort(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(spanish))
    }

    /// «sept.» para «cobros en sept.».
    private static func monthShort(_ date: Date) -> String {
        let month = date.formatted(.dateTime.month(.abbreviated).locale(spanish))
        return month.hasSuffix(".") ? month : month + "."
    }

    private static func days(since date: Date) -> Int {
        let calendar = Calendar.current
        return max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: Date())).day ?? 0)
    }

    private static func relative(_ date: Date) -> String {
        let n = days(since: date)
        return n == 0 ? "hoy" : n == 1 ? "ayer" : "hace \(n) días"
    }

    private static func times(_ count: Int) -> String {
        count == 1 ? "1 vez" : "\(count) veces"
    }
}

// MARK: - Abrir el compositor

/// Con qué se abre «Recordar un pago»: la deuda, el amigo y su monto.
struct ReminderComposerRequest: Identifiable {
    let id = UUID()
    var debt: Expense?
    var friendID: String?
    var amount: Double?

    /// Para volver a cobrarle una deuda de Cobros. `nil` si el gasto ya no
    /// está en este teléfono (se borró): sin él no hay `debt_key` que renovar.
    @MainActor
    static func forShare(_ share: ReceivableShare, in context: ModelContext) -> ReminderComposerRequest? {
        // Sólo los días alrededor del gasto: la llave sale del propio gasto, y
        // recorrer el historial entero para una deuda es trabajo tirado.
        var descriptor = FetchDescriptor<Expense>()
        if let day = share.occurredOn {
            let start = day.addingTimeInterval(-2 * 86_400)
            let end = day.addingTimeInterval(3 * 86_400)
            descriptor.predicate = #Predicate { $0.date >= start && $0.date < end }
        }
        let expenses = (try? context.fetch(descriptor)) ?? []
        guard let debt = TransactionKey.expensesByLookupKey(expenses)[share.debtKey] else { return nil }
        // El monto sólo si no abonó nada: renovarlo con lo que falta
        // achicaría la deuda en el servidor (`debt_share_from_reminder`).
        let amount = Money.cents(share.paidAmount) == 0 ? share.amount : nil
        return ReminderComposerRequest(debt: debt, friendID: share.debtor, amount: amount)
    }
}
