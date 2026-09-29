import SwiftUI
import SwiftData

/// Configuración › Perfil (`4a`): avatar, apodo y estado, con la vista previa
/// de lo que ven tus amigos debajo. Las mismas hojas de edición que Social ›
/// Mi perfil, para que se edite igual desde los dos lados.
struct ProfileSettingsView: View {

    @Environment(\.colorScheme) private var scheme
    @Query private var expenses: [Expense]
    @StateObject private var rates = ExchangeRateService.shared
    @State private var social = SocialProfileStore.shared
    @State private var friendsManager = FriendsManager.shared
    @State private var editing: MyProfileSheet.Section?

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

    /// La unión de lo que compartes con cada amigo (ver `ProfileView`).
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
        SettingsPage(title: "Perfil") {
            identity

            SettingsGroup {
                SettingsButton(icon: "pawprint.fill", tint: Color(hex: 0x0A84FF), title: "Avatar",
                               value: social.penguin.animal?.name ?? "Pingüino") { editing = .avatar }
                SettingsDivider()
                SettingsButton(icon: "person.text.rectangle.fill", tint: Color(hex: 0x0A84FF), title: "Apodo",
                               value: social.displayName.isEmpty ? "Sin definir" : social.displayName) { editing = .name }
                SettingsDivider()
                SettingsButton(icon: "quote.opening", tint: Color(hex: 0x0A84FF), title: "Estado",
                               value: social.status.isEmpty ? "Sin definir" : social.status) { editing = .status }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("ASÍ TE VERÁN TUS AMIGOS")
                    .font(.caption)
                    .tracking(0.3)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 20)
                ProfileFriendPreview(shared: shared, totals: totals)
                    .padding(.horizontal, 16)
                Text("Lo que compartes se elige amigo por amigo, desde su ficha.")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.horizontal, 20)
            }
        }
        .sheet(item: $editing) { MyProfileSheet(section: $0) }
    }

    private var identity: some View {
        VStack(spacing: 8) {
            Button { editing = .avatar } label: {
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
            .accessibilityLabel("Cambiar avatar")

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
    }
}
