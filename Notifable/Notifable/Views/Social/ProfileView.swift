import SwiftUI
import SwiftData

/// Social › Mi perfil (`2i`): quién soy para mis amigos y qué ven de mí.
///
/// La vista previa «así te verán tus amigos» es **la misma tarjeta del feed**
/// de Actividad, con los mismos componentes, no una maqueta parecida: lo que
/// editas arriba es literalmente lo que se dibuja abajo, así que no hay margen
/// para que una y otra se desincronicen.
struct ProfileView: View {
    @Binding var scrollToTopTrigger: Bool
    let progress: ScrollProgress

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @State private var social = SocialProfileStore.shared
    @State private var friendsManager = FriendsManager.shared

    @State private var showProfileSheet = false
    @State private var editing: MyProfileSheet.Section?
    @State private var phone = PhoneVerification.shared
    @State private var showsPhone = false

    init(scrollToTopTrigger: Binding<Bool>, progress: ScrollProgress) {
        self._scrollToTopTrigger = scrollToTopTrigger
        self.progress = progress

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

    /// Lo que de verdad sale hacia fuera: la unión de lo que compartes con
    /// cada amigo. Si con uno compartes el total, el total sale.
    private var shared: (total: Bool, categories: [String]) {
        var total = false
        var categories: Set<String> = []
        for row in friendsManager.outgoing {
            total = total || row.shareTotal
            categories.formUnion(row.shareCategories)
        }
        return (total, categories.sorted())
    }

    var body: some View {
        let shared = self.shared
        let totals = self.totals

        TrackableScrollView(scrollToTopTrigger: $scrollToTopTrigger) {
            VStack(spacing: 16) {
                identityCard

                editorRows

                seenTodaySection(shared: shared, totals: totals)

                previewSection(shared: shared, totals: totals)
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
        .sheet(item: $editing) { MyProfileSheet(section: $0) }
        .sheet(isPresented: $showsPhone) { PhoneVerificationSheet() }
        .task { await phone.refresh() }
    }

    // MARK: - Identidad

    private var identityCard: some View {
        VStack(spacing: 10) {
            Button {
                editing = .avatar
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    PenguinAvatar(look: social.penguin, size: 96, background: palette.surface)

                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 30, height: 30)
                        .background(accent.color, in: Circle())
                        .overlay(Circle().stroke(palette.background, lineWidth: 2.5))
                }
            }
            .buttonStyle(.plain)

            Text(social.displayName.isEmpty ? "Sin nombre" : social.displayName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.label)

            if !social.status.isEmpty {
                Text("«" + social.status + "»")
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var editorRows: some View {
        MovementCard {
            editorRow(icon: "paintpalette", title: "Avatar", value: social.penguin.animal?.name ?? "Pingüino",
                      section: .avatar)
            MovementSeparator()
            editorRow(icon: "textformat", title: "Apodo",
                      value: social.displayName.isEmpty ? "Sin definir" : social.displayName,
                      section: .name)
            MovementSeparator()
            editorRow(icon: "quote.bubble", title: "Estado",
                      value: social.status.isEmpty ? "Sin definir" : social.status,
                      section: .status)
            MovementSeparator()
            phoneRow
        }
    }

    /// El celular no es parte de lo que ven tus amigos: abre su propia hoja.
    private var phoneRow: some View {
        Button {
            showsPhone = true
        } label: {
            HStack(spacing: 12) {
                MovementIcon(icon: "phone", color: accent.color, size: 38)

                Text("Celular")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.label)

                Spacer(minLength: 8)

                if let number = phone.formattedPhone {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.positive)
                    Text(number)
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                } else {
                    Text("Sin verificar")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.secondaryLabel)
                }

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

    private func editorRow(icon: String, title: String, value: String,
                           section: MyProfileSheet.Section) -> some View {
        Button {
            editing = section
        } label: {
            HStack(spacing: 12) {
                MovementIcon(icon: icon, color: accent.color, size: 38)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.label)

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)

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

    // MARK: - Qué ven

    private func seenTodaySection(shared: (total: Bool, categories: [String]),
                                  totals: PeriodTotals) -> some View {
        VStack(spacing: 8) {
            ShellSectionHeader(title: "Verá hoy")

            MovementCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total del mes")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(palette.label)
                        Text(shared.total ? "El monto de Resumen, sin desglose"
                                          : "No lo estás compartiendo")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                    }

                    Spacer(minLength: 8)

                    Text(shared.total ? Money.format(totals.spent) : "—")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(shared.total ? palette.label : palette.tertiaryLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                MovementSeparator()

                HStack(spacing: 12) {
                    Text("Categorías elegidas")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(palette.label)

                    Spacer(minLength: 8)

                    Text("\(shared.categories.count) de \(totals.byCategory.count)")
                        .font(.system(size: 13.5))
                        .foregroundStyle(palette.secondaryLabel)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Text("Lo que compartes se elige amigo por amigo, desde su ficha.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.tertiaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
    }

    // MARK: - Vista previa

    private func previewSection(shared: (total: Bool, categories: [String]),
                                totals: PeriodTotals) -> some View {
        VStack(spacing: 8) {
            ShellSectionHeader(title: "Así te verán tus amigos")
            ProfileFriendPreview(shared: shared, totals: totals)
        }
    }
}


/// La tarjeta «así te verán tus amigos»: la misma del feed de Actividad. La
/// usan Social › Mi perfil y Configuración › Perfil (`4a`).
struct ProfileFriendPreview: View {
    let shared: (total: Bool, categories: [String])
    let totals: PeriodTotals

    @Environment(\.colorScheme) private var scheme
    @State private var social = SocialProfileStore.shared

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        let categories = totals.byCategory
            .filter { shared.categories.contains($0.category) }
            .prefix(3)

        ShellCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    PenguinAvatar(look: social.penguin, size: 44,
                                  background: palette.neutralSurface)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(social.displayName.isEmpty ? "Sin nombre" : social.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.label)

                        Text(social.status.isEmpty
                             ? "Su gasto de " + Period.spanishMonthName(for: Date()).lowercased()
                             : "«" + social.status + "»")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if shared.total {
                        Text(Money.format(totals.spent))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(palette.label)
                    }
                }

                if !categories.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(categories), id: \.id) { category in
                            HStack(spacing: 4) {
                                Image(systemName: CategoryStyle.icon(for: category.category))
                                    .font(.system(size: 10, weight: .semibold))
                                Text(category.category)
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(CategoryStyle.color(for: category.category,
                                                                accent: accent.color))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(CategoryStyle.color(for: category.category,
                                                            accent: accent.color).opacity(0.14),
                                        in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                }

                if !shared.total && categories.isEmpty {
                    Text("Ahora mismo no compartes nada con nadie.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.tertiaryLabel)
                }
            }
        }
    }
}
