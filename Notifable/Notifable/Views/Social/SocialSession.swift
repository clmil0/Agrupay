import SwiftUI

/// El arranque de sesión de la pestaña Social, en un modificador.
///
/// Las tres sub-vistas lo necesitan —cualquiera puede ser la primera que se
/// abra— y antes vivía dentro del `.task` del hub único. Repetirlo tres veces
/// abriría tres sesiones; `didStart` lo deja en una.
struct SocialSessionModifier: ViewModifier {
    @Binding var showProfileSheet: Bool

    @State private var didStart = false
    @State private var auth = SupabaseAuthManager.shared
    @State private var social = SocialProfileStore.shared
    @State private var friendsManager = FriendsManager.shared

    func body(content: Content) -> some View {
        content
            .task {
                guard !didStart else { return }
                didStart = true
                let ready = await auth.ensureSession(
                    defaultName: social.displayName.isEmpty ? "Amigo" : social.displayName)
                // Sin nombre propio, lo primero es ponérselo: el resto de la
                // pestaña no significa nada si tus amigos te ven como «Amigo».
                if ready, social.displayName.isEmpty || social.displayName == "Amigo" {
                    showProfileSheet = true
                }
                await friendsManager.refresh()
            }
            .refreshable { await friendsManager.refresh() }
    }
}

extension View {
    func socialSession(showProfileSheet: Binding<Bool>) -> some View {
        modifier(SocialSessionModifier(showProfileSheet: showProfileSheet))
    }
}

/// El avatar de un amigo: su pingüino, salvo que yo le haya puesto un emoji
/// —esa nota privada manda sobre lo que él eligió—, y si no, su inicial.
struct FriendAvatar: View {
    let friend: Friend
    var size: CGFloat = 44
    /// El hueco entre su anillo Pro y el avatar: la superficie donde se apoya.
    var gap: Color? = nil

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        // Un amigo Pro lleva el anillo quieto de su tema en listas y feed.
        if let ring = SocialRing.friend(friend.style) {
            ZStack {
                SocialRingView(ring: ring, size: size, gap: gap ?? palette.surface)
                face
            }
            .frame(width: size, height: size)
        } else {
            face
        }
    }

    @ViewBuilder
    private var face: some View {
        if !friend.usesEmoji, let penguin = friend.penguin {
            PenguinAvatar(look: penguin, size: size, background: palette.neutralSurface)
        } else {
            Text(friend.glyph)
                .font(friend.usesEmoji ? .system(size: size * 0.45)
                                       : .system(size: size * 0.4, weight: .bold))
                .foregroundStyle(friend.usesEmoji ? palette.label : Color.white)
                .frame(width: size, height: size)
                .background(friend.usesEmoji ? friend.tint.opacity(0.22) : friend.tint, in: Circle())
        }
    }
}
