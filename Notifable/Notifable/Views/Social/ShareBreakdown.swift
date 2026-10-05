import SwiftUI

/// Un dato compartido en una pastilla: «Total del mes» o una categoría con
/// su ícono y, si se da, su monto corto («Comida 612»).
struct SocialShareChip: View {
    let icon: String
    let label: String
    let tint: Color?
    var small = false

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    /// La pastilla del total: neutra, sin color de categoría.
    static func total(_ label: String = "Total del mes", small: Bool = false) -> SocialShareChip {
        SocialShareChip(icon: "banknote", label: label, tint: nil, small: small)
    }

    static func category(_ name: String, amount: Double? = nil, accent: Color, small: Bool = false) -> SocialShareChip {
        let label = amount.map {
            name + " " + Money.formatCompact($0).replacingOccurrences(of: "S/ ", with: "")
        } ?? name
        return SocialShareChip(icon: CategoryStyle.icon(for: name), label: label,
                               tint: CategoryStyle.color(for: name, accent: accent), small: small)
    }

    var body: some View {
        HStack(spacing: small ? 3 : 4) {
            Image(systemName: icon)
                .font(.system(size: small ? 9.5 : 10, weight: .semibold))
            Text(label)
                .font(.system(size: small ? 11 : 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? palette.label)
        .padding(.horizontal, small ? 7 : 9)
        .padding(.vertical, small ? 3 : 5)
        .background(tint.map { $0.opacity(0.14) } ?? palette.track, in: Capsule())
        .fixedSize()
    }
}

/// «Compartes», desplegado bajo tu tarjeta al tocar «lo ven N amigos»: qué
/// sale de tu gasto y hacia quién. Por dato (cada dato con quién lo ve) o
/// por amigo (cada amigo con lo que ve).
struct ShareBreakdown: View {
    let totals: PeriodTotals

    @Environment(\.colorScheme) private var scheme
    @State private var friendsManager = FriendsManager.shared
    @State private var byFriend = false
    /// Quien sólo recibe de ti ya no sale en la lista del final de Social:
    /// su ficha se abre desde aquí.
    @State private var selectedFriend: Friend?

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private struct Sharer: Identifiable {
        let friend: Friend
        let row: FriendShareRow
        var id: String { friend.id }
    }

    private var sharers: [Sharer] {
        friendsManager.outgoing
            .filter { $0.shareTotal || !$0.shareCategories.isEmpty }
            .map { Sharer(friend: friendsManager.friend(with: $0.viewerID), row: $0) }
    }

    /// Las categorías que alguien ve, en el orden de Resumen (de más a menos).
    private func sharedCategories(_ sharers: [Sharer]) -> [String] {
        let shared = Set(sharers.flatMap(\.row.shareCategories))
        let ordered = totals.byCategory.map(\.category).filter { shared.contains($0) }
        return ordered + shared.subtracting(ordered).sorted()
    }

    private func amount(of category: String) -> Double? {
        totals.byCategory.first { $0.category == category }?.total
    }

    var body: some View {
        let sharers = self.sharers

        VStack(alignment: .leading, spacing: 10) {
            modePicker

            if byFriend {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sharers) { sharer in friendRow(sharer) }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let total = sharers.filter(\.row.shareTotal)
                    if !total.isEmpty {
                        dataRow(SocialShareChip.total(), who: total.map(\.friend))
                    }
                    ForEach(sharedCategories(sharers), id: \.self) { category in
                        dataRow(SocialShareChip.category(category, amount: amount(of: category), accent: accent.color),
                                who: sharers.filter { $0.row.shareCategories.contains(category) }.map(\.friend))
                    }
                }
            }

            Text("Lo que compartes se elige amigo por amigo, desde su ficha.")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.hairline).frame(height: 0.5)
        }
        .sheet(item: $selectedFriend) { friend in
            FriendProfileView(friend: friend, totals: totals,
                              incoming: friendsManager.acceptedIncoming.first { $0.sharerID == friend.id })
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton("Por dato", on: !byFriend) { byFriend = false }
            modeButton("Por amigo", on: byFriend) { byFriend = true }
        }
        .padding(2)
        .background(palette.background, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    private func modeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { action() }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(on ? palette.label : palette.secondaryLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(on ? palette.track : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func dataRow(_ chip: SocialShareChip, who: [Friend]) -> some View {
        HStack(spacing: 8) {
            chip

            Text(who.map(\.name).joined(separator: ", "))
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(spacing: -6) {
                ForEach(who.prefix(4)) { friend in
                    FriendAvatar(friend: friend, size: 22)
                        .padding(1.5)
                        .background(palette.surface, in: Circle())
                }
            }
            .padding(.leading, 6)
        }
        .frame(minHeight: 30)
    }

    private func friendRow(_ sharer: Sharer) -> some View {
        Button { selectedFriend = sharer.friend } label: { friendRowContent(sharer) }
            .buttonStyle(.plain)
    }

    private func friendRowContent(_ sharer: Sharer) -> some View {
        HStack(spacing: 10) {
            FriendAvatar(friend: sharer.friend, size: 26)

            Text(sharer.friend.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.label)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)

            TagFlowLayout(spacing: 4, lineSpacing: 4) {
                if sharer.row.shareTotal { SocialShareChip.total("Total", small: true) }
                ForEach(sharer.row.shareCategories, id: \.self) { category in
                    SocialShareChip.category(category, accent: accent.color, small: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.tertiaryLabel)
        }
        .contentShape(Rectangle())
    }
}
