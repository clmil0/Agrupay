import SwiftUI
import SwiftData

/// Social (`2g`): Actividad y Amigos en una sola pantalla.
///
/// Estaban en dos píldoras, y se pagaba caro: los amigos vivían en una y lo
/// que te comparten en otra, así que aceptar una solicitud y ver su gasto
/// eran dos viajes. Ahora es un solo scroll, en el orden en que se usa —lo
/// tuyo, lo que hay que atender, lo que te comparten, y al final la lista
/// entera.
///
/// Las piezas de Amigos viven en `FriendsSections`, cada una con su estado:
/// aquí sólo se decide el orden.
/// - Note: `SocialHubView` y no `SocialView` porque `Views/SocialView.swift`
///   —la pantalla social anterior al rediseño, que ya no usa nadie— sigue en
///   el proyecto con ese nombre.
struct SocialHubView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var auth = SupabaseAuthManager.shared
    @State private var social = SocialProfileStore.shared

    @State private var showProfileSheet = false
    @State private var selectedFriend: Friend?
    @State private var expandedFriendID: String?
    /// Amigos cuyas categorías ya se abrieron en carrusel (`2d`) al tocar «+N».
    @State private var carouselFriendIDs: Set<String> = []

    init(scrollToTopTrigger: Binding<Bool>, progress: ScrollProgress) {
        self._scrollToTopTrigger = scrollToTopTrigger
        self.progress = progress

        // Sólo el mes en curso: es lo único que esta pantalla enseña, y
        // cargar el historial entero para un total del mes materializa
        // decenas de miles de objetos.
        let window = Period(granularity: .mes, reference: Date()).dataWindow()
        let start = window.start
        let end = window.end
        _expenses = Query(filter: #Predicate<Expense> { $0.date >= start && $0.date < end },
                          sort: \Expense.date, order: .reverse)
    }

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private var isConnecting: Bool {
        #if DEBUG
        // Modo QA: amigos inventados, sin sesión.
        if QAMode.isOn { return false }
        #endif
        return !auth.isReady && !auth.needsGoogleAccount
    }

    private var totals: PeriodTotals {
        Accounting.totals(expenses: expenses, incomes: [],
                          period: Period(granularity: .mes, reference: Date()),
                          usdToPen: rates.usdToPenRate)
    }

    var body: some View {
        let pending = friendsManager.pendingIncoming
        let feed = friendsManager.acceptedIncoming

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 12) {
                myCard

                FriendsActionsSection()

                if isConnecting {
                    ShellCard {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Conectando…")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.secondaryLabel)
                        }
                    }
                } else if pending.isEmpty && feed.isEmpty {
                    // Sin amigos, el vacío lo pone la lista de abajo: dos
                    // carteles seguidos diciendo lo mismo sobran.
                    if !friendsManager.friends.isEmpty {
                        ShellEmptyState(icon: "bolt",
                                        title: "Todavía nadie te comparte",
                                        message: "Pídeles a tus amigos que te compartan su gasto del mes.")
                    }
                } else {
                    VStack(spacing: 0) {
                        ShellSectionHeader(title: "De tus amigos",
                                           trailing: feed.isEmpty ? nil
                                               : feed.count == 1 ? "1 te comparte" : "\(feed.count) te comparten")
                        VStack(spacing: 10) {
                            ForEach(pending, id: \.id) { row in
                                requestCard(row)
                            }

                            ForEach(feed, id: \.id) { row in
                                feedCard(row)
                            }
                        }
                    }
                }

                FriendsRosterSection()
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
        .socialSession(showProfileSheet: $showProfileSheet)
        .sheet(isPresented: $showProfileSheet) { MyProfileSheet() }
        .sheet(item: $selectedFriend) { friend in
            FriendProfileView(friend: friend, totals: totals,
                              incoming: friendsManager.acceptedIncoming.first { $0.sharerID == friend.id })
        }
    }

    // MARK: - Tu tarjeta (2h)

    /// Cuántos amigos ven algo de tu gasto este mes.
    private var viewers: Int {
        friendsManager.outgoing.filter { $0.shareTotal || !$0.shareCategories.isEmpty }.count
    }

    private var myCard: some View {
        Button {
            showProfileSheet = true
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                SocialBannerView(index: social.bannerIndex)
                    .frame(height: 104)

                HStack(alignment: .bottom, spacing: 12) {
                    PenguinAvatar(look: social.penguin, size: 92, background: palette.background)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(social.displayName.isEmpty ? "Tu nombre" : social.displayName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(social.displayName.isEmpty ? palette.tertiaryLabel : palette.label)
                            .lineLimit(1)
                        if !social.status.isEmpty {
                            Text("«" + social.status + "»")
                                .font(.system(size: 12.5))
                                .foregroundStyle(palette.secondaryLabel)
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 6)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, -38)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tu gasto de " + Period.spanishMonthName(for: Date()).lowercased())
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                        Text(Money.format(totals.spent))
                            .font(.system(size: 28, weight: .bold))
                            .tracking(-0.5)
                            .foregroundStyle(palette.label)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    viewersChip
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Editar tu perfil")
    }

    private var viewersChip: some View {
        let count = viewers
        let tint = count > 0 ? accent.onSurface(scheme) : palette.secondaryLabel
        return HStack(spacing: 5) {
            Image(systemName: count > 0 ? "eye" : "eye.slash")
                .font(.system(size: 11, weight: .semibold))
            Text(count == 0 ? "sólo lo ves tú" : count == 1 ? "lo ve 1 amigo" : "lo ven \(count) amigos")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(count > 0 ? accent.color.opacity(0.12) : palette.track, in: Capsule())
    }

    // MARK: - Solicitudes

    private func requestCard(_ row: FriendShareRow) -> some View {
        let friend = friendsManager.friend(with: row.sharerID)

        return ShellCard {
            HStack(spacing: 12) {
                FriendAvatar(friend: friend)

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text("Quiere compartirte su gasto del mes")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                }

                Spacer(minLength: 6)

                HStack(spacing: 6) {
                    Button {
                        Task { await friendsManager.accept(sharerID: row.sharerID) }
                    } label: {
                        Text("Aceptar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(accent.color, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await friendsManager.ignore(sharerID: row.sharerID) }
                    } label: {
                        Text("Rechazar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.secondaryLabel)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(palette.neutralSurface, in: Capsule())
                            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Feed

    private func feedCard(_ row: FriendShareRow) -> some View {
        let friend = friendsManager.friend(with: row.sharerID)
        let isExpanded = expandedFriendID == friend.id
        let categories = row.categoryTotals

        // Un toque y no un `Button`: dentro va el carrusel de categorías
        // (`2d`), y un `Button` se quedaba con el deslizamiento y abría el
        // perfil en vez de mover la fila.
        return ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    FriendAvatar(friend: friend)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.label)

                        Text(friend.status.isEmpty
                             ? "Su gasto de " + Period.spanishMonthName(for: Date()).lowercased()
                             : "«" + friend.status + "»")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if let total = row.totalAmount, row.shareTotal {
                        Text(Money.format(total))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(palette.label)
                    }
                }

                if !categories.isEmpty {
                    categoryChips(categories, friendID: friend.id)

                    // Sólo cuando comparte total **y** categorías tiene
                    // sentido avisar de que el desglose no cubre todo.
                    if isExpanded, row.shareTotal {
                        Text("El resto de su total no está desglosado.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedFriend = friend }
        .accessibilityAddTraits(.isButton)
        .onLongPressGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                expandedFriendID = isExpanded ? nil : friend.id
            }
        }
    }

    /// Una sola línea, sin partir ningún chip (`2b`): caben los que caben y
    /// el resto se cuenta en «+N». Tocar «+N» vuelve la fila un carrusel que
    /// se desliza, con fundido al borde (`2d`).
    @ViewBuilder
    private func categoryChips(_ categories: [FriendShareRow.CategoryAmount], friendID: String) -> some View {
        if carouselFriendIDs.contains(friendID) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.name) { categoryChip($0) }
                }
                .padding(.horizontal, 14)
            }
            // Hasta el borde de la tarjeta, para que el fundido diga «hay más».
            .padding(.horizontal, -14)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: 0.84),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .transition(.opacity)
        } else {
            // De la fila entera a la de un chip y «+N»: la primera que quepa.
            ViewThatFits(in: .horizontal) {
                ForEach((1...categories.count).reversed(), id: \.self) { shown in
                    HStack(spacing: 6) {
                        ForEach(categories.prefix(shown), id: \.name) { categoryChip($0) }
                        if shown < categories.count {
                            moreChip(categories.count - shown, friendID: friendID)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func categoryChip(_ category: FriendShareRow.CategoryAmount) -> some View {
        let tint = CategoryStyle.color(for: category.name, accent: accent.color)
        return HStack(spacing: 4) {
            Image(systemName: CategoryStyle.icon(for: category.name))
                .font(.system(size: 10, weight: .semibold))
            Text(category.name + " " + Money.formatCompact(category.amount)
                .replacingOccurrences(of: "S/ ", with: ""))
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    private func moreChip(_ hidden: Int, friendID: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { _ = carouselFriendIDs.insert(friendID) }
        } label: {
            Text("+\(hidden)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(palette.track, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(hidden == 1 ? "1 categoría más" : "\(hidden) categorías más")
    }
}
