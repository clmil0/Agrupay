import SwiftUI

/// La cápsula de la izquierda del header de Amigos (`1a`): tu pingüino, tu
/// apodo y cuántos amigos ven tu gasto. Es la pareja de `MailStatusChip` en
/// Movimientos: ese lado quedaba vacío y Mi perfil ocupaba una pestaña de la
/// píldora. Tocarla abre Mi perfil en una hoja.
struct ProfileChip: View {
    let action: () -> Void

    @State private var social = SocialProfileStore.shared
    @State private var friendsManager = FriendsManager.shared

    @Environment(\.colorScheme) private var scheme
    @Environment(\.proTheme) private var proTheme
    private var palette: Palette { Palette(scheme).themed(proTheme) }

    /// Amigos con los que compartes algo: el total o alguna categoría.
    private var viewers: Int {
        friendsManager.outgoing.filter { $0.shareTotal || !$0.shareCategories.isEmpty }.count
    }

    private var name: String {
        social.displayName.isEmpty ? "Mi perfil" : social.displayName
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                PenguinAvatar(look: social.penguin, size: 26, background: palette.selectedFill)

                Text(name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                if viewers > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(viewers)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(palette.secondaryLabel)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .frame(height: ShellMetrics.headerControl)
            .background(palette.surface, in: Capsule())
            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewers > 0
            ? "Mi perfil, \(name). \(viewers) \(viewers == 1 ? "amigo ve" : "amigos ven") tu gasto"
            : "Mi perfil, \(name)")
        .accessibilityHint("Abre tu perfil")
    }
}

/// Mi perfil en una hoja, como el estado del correo: lo mismo que era la
/// pestaña, con «Listo» arriba.
struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var progress = ScrollProgress()
    @State private var scrollToTopTrigger = false

    var body: some View {
        NavigationStack {
            ProfileView(scrollToTopTrigger: $scrollToTopTrigger, progress: progress, topInset: 8)
                .navigationTitle("Mi perfil")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Listo") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }
}
