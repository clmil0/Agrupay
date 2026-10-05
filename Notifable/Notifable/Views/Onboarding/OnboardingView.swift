import SwiftUI
import SwiftData

/// Primera apertura de la app. Cinco pasos encadenados:
///
/// 1. **Carrusel** de tres pantallas que enseñan la UI real en pequeño —el
///    correo convirtiéndose en gasto, la barra de ritmo, la comparación con
///    amigos—. Cada una se anima al entrar: lo que hay que entender antes de
///    dar permiso sobre el correo es qué se gana a cambio, y verlo moverse lo
///    explica mejor que un párrafo.
/// 2. **Login**, con la comparación lado a lado. "Sin cuenta" no es un
///    callejón: es un modo de uso completo donde los gastos se anotan a mano.
/// 3. **Recuperar** — sólo si entró con Google y esa cuenta ya tenía respaldo.
/// 4. **Cuánto correo leer** — 1 M, 3 M, 6 M, 1 A u otro, o no leer nada.
/// 5. La app.
struct OnboardingView: View {

    /// Lo pone en `true` el último paso; `NotifableApp` deja de presentar esta
    /// pantalla a partir de ahí.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("appAccentColor") private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @Environment(\.colorScheme) private var scheme

    @StateObject private var gmailAuth = GmailAuthService.shared

    enum Step: Equatable {
        case slides
        /// Todo lo que sigue a entrar con Google vive en `GmailLinkFlow`, que
        /// es la misma pieza que usa Ajustes → Gmail y bancos.
        case link
    }

    @State private var step: Step = .slides
    @State private var page = 0
    @State private var isConnecting = false
    @State private var showNoAccountConfirm = false
    /// Alto real del primer correo de la diapositiva 1, medido una vez con
    /// `GeometryReader`. `nil`/`.infinity` no se puede animar —SwiftUI no
    /// tiene de dónde interpolar—, así que sin este número el colapso se
    /// quedaba a medias en vez de subir del todo.
    @State private var firstMailHeight: CGFloat = 0
    /// Lo mismo que `firstMailHeight`, pero para el correo y el "registrado"
    /// del gasto de Yape una vez categorizado: también colapsan, para hacer
    /// sitio a los cuatro gastos que caen debajo.
    @State private var yapeChromeHeight: CGFloat = 0

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var palette: Palette { Palette(scheme) }

    private static let lastSlide = 2

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()

            switch step {
            case .slides:
                carousel
            case .link:
                GmailLinkFlow { finish() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: step)
        .onChange(of: gmailAuth.isAuthenticated) { _, isAuthenticated in
            guard isAuthenticated, isConnecting else { return }
            isConnecting = false
            withAnimation(.snappy) { step = .link }
        }
    }

    // MARK: - Carrusel + login

    private var carousel: some View {
        ZStack(alignment: .top) {
            TabView(selection: $page) {
                slideMail.tag(0)
                slidePace.tag(1)
                slideFriends.tag(2)
                loginPage.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack {
                Spacer()
                if page <= Self.lastSlide {
                    Button("Saltar") { withAnimation(.snappy) { page = 3 } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.secondaryLabel)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            if page <= Self.lastSlide { footer }
        }
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0...Self.lastSlide, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? accent.color : palette.tertiaryLabel.opacity(0.45))
                        .frame(width: index == page ? 22 : 7, height: 7)
                        .animation(.snappy, value: page)
                }
            }

            Button {
                withAnimation(.snappy) { page += 1 }
            } label: {
                Text(page == Self.lastSlide ? "Empezar" : "Siguiente")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.buttonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(accent.buttonFill)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 28)
    }

    // MARK: - 1. El correo se convierte en gasto

    private var slideMail: some View {
        OnboardingSlide(
            isActive: page == 0,
            title: "Tus gastos se anotan solos",
            subtitle: "Vincula tu Gmail y AgruPay lee los avisos de tu banco. Mantén presionado un gasto para categorizarlo, editarlo o marcarlo por cobrar.",
            footnote: (icon: "lock.fill",
                       text: "Solo lectura. No escribimos ni enviamos correos, y tus gastos se quedan en tu iPhone.")
        ) { beat in
            // El primer correo se muestra, se registra... y luego le toca el
            // turno al segundo: en vez de dejar los dos apilados a la vez, el
            // primero se desvanece y el de Yape sube a su lugar. Así, cuando
            // se mantiene presionado, el menú y el modal tienen sitio debajo
            // en vez de taparlo.
            let collapseAt = 2.9
            let risen = beat >= collapseAt
            let doneAt = Self.categorizeTiming(collapseAt: collapseAt).doneAt

            VStack(spacing: 0) {
                // Alineado con la tarjeta "Gasto de septiembre" del carrusel
                // 2, no pegado arriba del todo.
                Color.clear.frame(height: 24)

                // El espaciador de 14 va DENTRO de lo que se mide y se
                // colapsa: si se queda fuera (p. ej. como `spacing` del
                // `VStack` exterior), sigue empujando la fila de Yape aunque
                // el correo ya mida 0, y se queda corta sin llegar arriba.
                VStack(spacing: 0) {
                    mailToExpense(
                        beat: beat, mailDelay: 0, rowDelay: 0.6,
                        provider: "gmail_icon",
                        sender: "notificaciones@notificacionesbcp.com.pe",
                        time: "09:42",
                        subject: "Realizaste un consumo con tu Tarjeta de Crédito BCP",
                        icon: "cart.fill", tint: .orange,
                        merchant: "Plaza Vea",
                        detail: "Supermercado · hoy 09:42",
                        amount: "S/ 84.90")
                    Color.clear.frame(height: 14)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                // Antes de medir (primer instante), sin restricción: así no se
                // recorta nada mientras `firstMailHeight` todavía es 0.
                .frame(height: risen ? 0 : (firstMailHeight > 0 ? firstMailHeight : nil), alignment: .top)
                .clipped()
                .opacity(risen ? 0 : 1)
                .animation(.easeInOut(duration: 0.7), value: risen)

                categorizeMail(beat: beat, mailDelay: 1.3, rowDelay: 1.9, collapseAt: collapseAt)

                // La fila de bancos ya cumplió su papel en la primera mitad
                // (vincula Gmail); una vez categorizado el segundo
                // gasto, lo que sigue conviene es la prueba de que esto va a
                // seguir pasando solo: más gastos, en categorías distintas,
                // cayendo abajo. El propio correo de Yape también colapsa
                // (`categorizeMail` lo hace internamente) para hacerles sitio:
                // los cinco —Yape más los cuatro nuevos— tienen que caber sin
                // tapar ninguno.
                moreExpensesList(beat: beat, startAt: doneAt + 0.5)
            }
            .onPreferenceChange(HeightPreferenceKey.self) { firstMailHeight = $0 }
            // Alto fijo, no medido: con los cuatro gastos nuevos siempre en el
            // árbol (para que "Tus gastos se anotan solos" no se mueva ni un
            // punto), medir el alto natural de partida los contaría aunque
            // todavía no se vean, y la ilustración reservaría mucho más sitio
            // del que hace falta desde el primer fotograma. 396 es el alto que
            // ocupa el estado final ya asentado (24 de margen arriba + primer
            // correo y encabezado de Yape colapsados + su fila + las cuatro de
            // abajo enteras).
            .frame(height: 396, alignment: .top)
        }
    }

    private func mailToExpense(beat: Double, mailDelay: Double, rowDelay: Double,
                               provider: String,
                               sender: String, time: String, subject: String,
                               icon: String, tint: Color,
                               merchant: String, detail: String, amount: String) -> some View {
        VStack(spacing: 0) {
            mailBanner(beat: beat, mailDelay: mailDelay, provider: provider,
                       sender: sender, time: time, subject: subject)
            registeredLabel(beat: beat, mailDelay: mailDelay, rowDelay: rowDelay)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(merchant)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.label)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(amount)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.label)
            }
            .padding(10)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .reveal(beat, after: rowDelay, offset: 14)
        }
    }

    /// El correo que llega, tal cual se ve arriba del gasto que produce. El
    /// icono de la izquierda es el proveedor real: sin él, "vincula tu Gmail"
    /// no se reconocía en la ilustración. Sólo Gmail mientras Outlook no
    /// exista: enseñar su icono prometía algo que la app no hace.
    private func mailBanner(beat: Double, mailDelay: Double, provider: String,
                            sender: String, time: String, subject: String) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white)
                    .frame(width: 26, height: 26)
                Image(provider)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(sender)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.tertiaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(time)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.tertiaryLabel)
                }
                Text(subject)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.track)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .reveal(beat, after: mailDelay)
    }

    /// El parpadeo es el momento en que la app hace su trabajo: aparece entre
    /// el correo y el gasto, que es exactamente lo que cuenta.
    private func registeredLabel(beat: Double, mailDelay: Double, rowDelay: Double) -> some View {
        Label("REGISTRADO EN AGRUPAY", systemImage: "arrow.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(palette.tertiaryLabel)
            .padding(.vertical, 5)
            .opacity(beat > mailDelay + 0.35 ? 1 : 0)
            .blink(active: beat > mailDelay + 0.35 && beat < rowDelay + 0.4)
    }

    /// El menú y el modal se piden despacio a propósito: es el tramo que hay
    /// que leer, no sólo mirar pasar. `slideMail` necesita los mismos números
    /// para saber cuándo terminó, así que viven en un solo sitio.
    private static func categorizeTiming(collapseAt: Double) -> (menuAt: Double, modalAt: Double, pickAt: Double, doneAt: Double) {
        // El primer correo tarda ~0.7s en desvanecerse y en lo que el de Yape
        // sube a su lugar (ver `slideMail`): el menú espera a que eso termine.
        let menuAt = collapseAt + 0.9
        let modalAt = menuAt + 0.8
        let pickAt = modalAt + 0.9
        let doneAt = pickAt + 0.7
        return (menuAt, modalAt, pickAt, doneAt)
    }

    /// El segundo correo del carrusel: además de convertirse en gasto, muestra
    /// el gesto que categoriza —mantener presionado abre el menú, "Categorizar"
    /// abre el modal, y elegir "Comida" deja el gasto clasificado—, porque ese
    /// gesto es la otra mitad de "tus gastos se anotan solos".
    private func categorizeMail(beat: Double, mailDelay: Double, rowDelay: Double,
                                collapseAt: Double) -> some View {
        let timing = Self.categorizeTiming(collapseAt: collapseAt)
        let categorized = beat >= timing.doneAt
        let menuVisible = beat >= timing.menuAt && beat < timing.modalAt
        let modalVisible = beat >= timing.modalAt && beat < timing.doneAt
        // Una vez categorizado y ya asentado, el correo y el "registrado" de
        // Yape también colapsan —igual que hizo el primer correo—, para
        // hacerles sitio a los cuatro gastos que caen debajo sin tapar a
        // ninguno.
        let chromeGoneAt = timing.doneAt + 0.3
        let chromeGone = beat >= chromeGoneAt

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                mailBanner(beat: beat, mailDelay: mailDelay, provider: "gmail_icon",
                           sender: "notificaciones@yape.pe", time: "21:04",
                           subject: "Constancia de Yapeo · Monto S/ 120.00 a JORGE M.")
                registeredLabel(beat: beat, mailDelay: mailDelay, rowDelay: rowDelay)
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { yapeChromeHeight = geo.size.height }
                }
            )
            .frame(height: chromeGone ? 0 : (yapeChromeHeight > 0 ? yapeChromeHeight : nil), alignment: .top)
            .clipped()
            .opacity(chromeGone ? 0 : 1)
            .animation(.easeInOut(duration: 0.6), value: chromeGone)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(palette.tertiaryLabel.opacity(0.18)).frame(width: 34, height: 34)
                    Image("yape_icon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .opacity(categorized ? 0 : 1)

                    Circle().fill(Color.orange.opacity(0.18)).frame(width: 34, height: 34)
                        .opacity(categorized ? 1 : 0)
                    Image(systemName: "fork.knife")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                        .opacity(categorized ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Yape · Jorge M.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.label)
                        if categorized {
                            Text("COMIDA")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.16))
                                .clipShape(Capsule())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(categorized ? "Comida · hoy 21:04" : "Sin clasificar · hoy 21:04")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("S/ 120.00")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.label)
            }
            .padding(10)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
            .scaleEffect(menuVisible ? 1.03 : 1)
            .shadow(color: .black.opacity(menuVisible ? 0.16 : 0), radius: 14, y: 6)
            .reveal(beat, after: rowDelay, offset: 44)
            // Debajo de la fila, no encima: para cuando se abren, el primer
            // correo ya se desvaneció y esta fila subió a su lugar, así que
            // abajo queda libre.
            .overlay(alignment: .top) {
                categorizeContextMenu
                    .opacity(menuVisible ? 1 : 0)
                    .scaleEffect(menuVisible ? 1 : 0.92, anchor: .top)
                    .offset(y: 66)
            }
            .overlay(alignment: .top) {
                categoryPickerModal(picked: beat >= timing.pickAt)
                    .opacity(modalVisible ? 1 : 0)
                    .scaleEffect(modalVisible ? 1 : 0.92, anchor: .top)
                    .offset(y: 66)
            }
            .animation(.easeOut(duration: 0.25), value: menuVisible)
            .animation(.easeOut(duration: 0.25), value: modalVisible)
            .animation(.easeInOut(duration: 0.35), value: categorized)
        }
    }

    private var categorizeContextMenu: some View {
        VStack(spacing: 0) {
            menuRow("Marcar por cobrar", "hourglass", highlighted: false)
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            menuRow("Categorizar", "tag", highlighted: true)
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            menuRow("Editar", "pencil", highlighted: false)
        }
        .frame(width: 200)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
    }

    private func menuRow(_ title: String, _ icon: String, highlighted: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            Spacer(minLength: 8)
            Image(systemName: icon).font(.system(size: 12))
        }
        .foregroundStyle(palette.label)
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(highlighted ? palette.label.opacity(0.08) : .clear)
    }

    private func categoryPickerModal(picked: Bool) -> some View {
        VStack(spacing: 0) {
            Text("Elige una categoría")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 10)
            Rectangle().fill(palette.hairline).frame(height: 0.5)
            categoryModalRow(icon: "fork.knife", tint: .orange, name: "Comida",
                             trailing: "bolt.fill", trailingTint: .green, highlighted: picked)
            Rectangle().fill(palette.hairline).frame(height: 0.5).padding(.leading, 50)
            categoryModalRow(icon: "car.fill", tint: .blue, name: "Transporte",
                             trailing: nil, trailingTint: .clear, highlighted: false)
            Rectangle().fill(palette.hairline).frame(height: 0.5).padding(.leading, 50)
            categoryModalRow(icon: "basket.fill", tint: .green, name: "Mercado",
                             trailing: nil, trailingTint: .clear, highlighted: false)
            Rectangle().fill(palette.hairline).frame(height: 0.5).padding(.leading, 50)
            categoryModalRow(icon: "ellipsis.circle.fill", tint: .green, name: "Otros",
                             trailing: nil, trailingTint: .clear, highlighted: false)
        }
        .frame(width: 236)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
    }

    private func categoryModalRow(icon: String, tint: Color, name: String,
                                  trailing: String?, trailingTint: Color, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.2)).frame(width: 26, height: 26)
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            }
            Text(name).font(.system(size: 12)).foregroundStyle(palette.label)
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 10)).foregroundStyle(trailingTint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(highlighted ? Color.orange.opacity(0.12) : .clear)
    }

    private struct MoreExpense {
        let id: String
        let delay: Double
        let icon: String
        let tint: Color
        let merchant: String
        let detail: String
        let amount: String
    }

    /// Lo que sigue a categorizar el gasto de Yape: cuatro más, en categorías
    /// distintas, cayendo uno tras otro —la prueba de que esto no fue cosa de
    /// una vez, sino de que AgruPay lo va a seguir haciendo solo. Mismo
    /// formato y alto que la fila de Yape de arriba. Los cinco —Yape más
    /// estos cuatro— se quedan a la vista a la vez, sin tapar ninguno: el
    /// correo y el "registrado" de Yape colapsan antes (ver `categorizeMail`)
    /// para hacerles sitio.
    private func moreExpensesList(beat: Double, startAt: Double) -> some View {
        let rows: [MoreExpense] = [
            MoreExpense(id: "uber", delay: startAt, icon: "car.fill", tint: .blue,
                        merchant: "Uber", detail: "Transporte · hoy 08:15", amount: "S/ 18.50"),
            MoreExpense(id: "netflix", delay: startAt + 0.4, icon: "play.tv.fill", tint: accent.color,
                        merchant: "Netflix", detail: "Entretenimiento · suscripción", amount: "S/ 34.90"),
            MoreExpense(id: "inkafarma", delay: startAt + 0.8, icon: "cross.case.fill", tint: .pink,
                        merchant: "Inkafarma", detail: "Salud · hoy 14:20", amount: "S/ 22.00"),
            MoreExpense(id: "falabella", delay: startAt + 1.2, icon: "bag.fill", tint: .indigo,
                        merchant: "Falabella", detail: "Compras · hoy 16:45", amount: "S/ 156.00")
        ]

        return VStack(spacing: 10) {
            ForEach(rows, id: \.id) { row in
                extraExpenseRow(beat: beat, after: row.delay, icon: row.icon, tint: row.tint,
                                merchant: row.merchant, detail: row.detail, amount: row.amount)
            }
        }
        .padding(.top, 14)
    }

    private func extraExpenseRow(beat: Double, after delay: Double, icon: String, tint: Color,
                                 merchant: String, detail: String, amount: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(merchant)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.label)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(amount)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.label)
        }
        .padding(10)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .reveal(beat, after: delay, offset: 20)
    }

    // MARK: - 2. El ritmo del mes

    private var slidePace: some View {
        OnboardingSlide(
            isActive: page == 1,
            title: "Sabes si vas rápido antes de fin de mes",
            subtitle: "Ves de un vistazo en qué se te fue el mes. Y a las categorías que quieras ponles un límite: la marca te dice por dónde va el mes y si vas más rápido que él.",
            footnote: nil
        ) { beat in
            VStack(spacing: 12) {
                monthSummaryCard(beat: beat)

                Text("MIS CATEGORÍAS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reveal(beat, after: 0.9)

                categoryRow(icon: "fork.knife", tint: .orange, title: "Comida",
                            detail: "4 comercios", amount: "S/ 512.00", action: "Poner límite")
                    .reveal(beat, after: 1.05)

                limitCategoryRow(beat: beat)
                    .reveal(beat, after: 1.25)

                HStack {
                    Text("por aquí va el mes")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.tertiaryLabel)
                    Spacer()
                    Text("quedan 18 días")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .reveal(beat, after: 1.4)
            }
        }
    }

    private static let spendSegments: [(color: Color, ratio: CGFloat)] = [
        (.orange, 0.40), (.green, 0.19), (.purple, 0.14), (.blue, 0.12), (Color(.systemGray3), 0.15)
    ]

    private func monthSummaryCard(beat: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GASTO DE SEPTIEMBRE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)

            Text("S/ 1,284.50")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(palette.label)
                .opacity(beat > 0.1 ? 1 : 0.25)
                .animation(.easeOut(duration: 0.9), value: beat > 0.1)

            // La barra crece de izquierda a derecha, un segmento por categoría:
            // ver de qué está hecho el mes es el argumento de la pantalla.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(Self.spendSegments.enumerated()), id: \.offset) { _, segment in
                        Capsule().fill(segment.color).frame(width: geo.size.width * segment.ratio)
                    }
                }
                .frame(width: geo.size.width * (beat > 0.05 ? 1 : 0), alignment: .leading)
                .clipShape(Capsule())
                .animation(.timingCurve(0.25, 0.9, 0.3, 1, duration: 1.1), value: beat > 0.05)
            }
            .frame(height: 14)
            .padding(.top, 9)

            HStack(spacing: 6) {
                legendChip("Comida", "40%", .orange)
                legendChip("Mercado", "19%", .green)
                legendChip("Servicios", "14%", .purple)
            }
            .padding(.top, 6)
            .reveal(beat, after: 0.5, offset: 6)
        }
        .padding(14)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    private func legendChip(_ name: String, _ percent: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 8, height: 8)
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.label)
            Text(percent).font(.system(size: 10)).foregroundStyle(palette.secondaryLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(palette.track.opacity(0.7))
        .clipShape(Capsule())
    }

    private func categoryRow(icon: String, tint: Color, title: String,
                             detail: String, amount: String, action: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.2)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(palette.label)
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondaryLabel)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amount).font(.system(size: 16, weight: .bold)).foregroundStyle(palette.label)
                Text(action).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent.onSurface(scheme))
            }
        }
        .padding(12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    /// La categoría con límite: la marca negra es dónde debería ir el mes, y el
    /// relleno naranja/rojo es dónde va de verdad. Cuando lo pasa, va rápido.
    private func limitCategoryRow(beat: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.2)).frame(width: 40, height: 40)
                    Image(systemName: "car.fill").font(.system(size: 16)).foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transporte").font(.system(size: 14, weight: .bold)).foregroundStyle(palette.label)
                    Text("6 comercios").font(.system(size: 11)).foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("S/ 150.00").font(.system(size: 16, weight: .bold)).foregroundStyle(palette.warning)
                    Text("de S/ 250").font(.system(size: 10)).foregroundStyle(palette.warning)
                }
            }
            .padding(12)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule()
                        .fill(palette.warning)
                        .frame(width: geo.size.width * (beat > 1.3 ? 0.6 : 0))
                        .animation(.timingCurve(0.25, 0.9, 0.3, 1, duration: 1.0), value: beat > 1.3)
                    Capsule()
                        .fill(palette.label)
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * 0.40)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - 3. Amigos

    private var slideFriends: some View {
        OnboardingSlide(
            isActive: page == 2,
            title: "Y si quieres, lo comparas con tus patas",
            subtitle: "Tú eliges, por persona, si ve tu total del mes, algunas categorías o nada. Ellos deciden lo mismo contigo.",
            footnote: (icon: "eye.slash.fill",
                       text: "Nunca sale un movimiento ni un comercio de tu teléfono: solo los totales que tú marcaste.")
        ) { beat in
            VStack(spacing: 12) {
                profileHeaderCard(beat: beat)
                friendsListCard(beat: beat)
            }
        }
    }

    private func profileHeaderCard(beat: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(red: 0.04, green: 0.52, blue: 1), Color(red: 0.2, green: 0.68, blue: 0.9)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 56)
                Text("Editar")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.24))
                    .clipShape(Capsule())
                    .padding(9)
            }
            // El avatar se ancla al borde izquierdo del banner con `overlay`,
            // no con `offset` sobre un `HStack`: así su posición horizontal no
            // depende de nada más y no se puede correr hacia la derecha.
            .overlay(alignment: .bottomLeading) {
                profileAvatar.padding(.leading, 12).offset(y: 36)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 11) {
                    Color.clear.frame(width: 54, height: 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Carlos Lopez").font(.system(size: 15, weight: .bold)).foregroundStyle(palette.label)
                        Text("Ahorrando para el viaje a Cusco").font(.system(size: 10)).foregroundStyle(palette.secondaryLabel)
                    }
                }

                HStack(spacing: 7) {
                    pillLabel("Compartes con 2 de 4", filled: true)
                    pillLabel("1 te comparten", filled: false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .reveal(beat, after: 0)
    }

    private var profileAvatar: some View {
        ZStack {
            Circle().fill(palette.surface).frame(width: 54, height: 54)
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            Circle().fill(accent.buttonFill).frame(width: 48, height: 48)
            Text("C").font(.system(size: 19, weight: .bold)).foregroundStyle(accent.buttonText)
        }
    }

    private func pillLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(filled ? accent.buttonText : palette.secondaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(filled ? accent.buttonFill : palette.track)
            .clipShape(Capsule())
    }

    private func friendsListCard(beat: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("TE COMPARTEN", count: 1)
            sharedFriendRow(beat: beat)
            Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 60)
            sectionLabel("SIN COMPARTIR", count: 1)
            notSharedFriendRow
        }
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
        .reveal(beat, after: 0.3, offset: 10)
    }

    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.secondaryLabel)
            Text("· \(count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.tertiaryLabel)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    private func sharedFriendRow(beat: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Capsule()
                    .fill(LinearGradient(colors: [.teal, .teal.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 4, height: 44)
                Circle().fill(Color.teal).frame(width: 38, height: 38)
                    .overlay(Text("M").font(.system(size: 15, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Mamita").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.label)
                        Text("124 d")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.teal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.teal.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    Text("Rosa L. · 3 categorías").font(.system(size: 10)).foregroundStyle(palette.secondaryLabel)
                }
                Spacer(minLength: 6)
                Text("S/ 1,010").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.label)
                Image(systemName: "chevron.up").font(.system(size: 9)).foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 8) {
                friendCategoryBar(icon: "car.fill", name: "Transporte", ratio: 1.0, amount: "S/ 420")
                    .reveal(beat, after: 0.55, offset: 6)
                friendCategoryBar(icon: "fork.knife", name: "Comida", ratio: 0.83, amount: "S/ 350")
                    .reveal(beat, after: 0.65, offset: 6)
                friendCategoryBar(icon: "basket.fill", name: "Mercado", ratio: 0.57, amount: "S/ 240")
                    .reveal(beat, after: 0.75, offset: 6)
                Text("El resto de su total no está desglosado.")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.tertiaryLabel)
            }
            .padding(.leading, 60)
            .padding(.trailing, 14)
            .padding(.bottom, 11)
        }
    }

    private func friendCategoryBar(icon: String, name: String, ratio: Double, amount: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(palette.secondaryLabel).frame(width: 16)
            Text(name).font(.system(size: 10)).foregroundStyle(palette.secondaryLabel).frame(width: 62, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule().fill(accent.color).frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 5)
            Text(amount)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.label)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }

    private var notSharedFriendRow: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(LinearGradient(colors: [.pink, .pink.opacity(0.5)], startPoint: .top, endPoint: .bottom))
                .frame(width: 4, height: 34)
            Circle().fill(Color.pink).frame(width: 32, height: 32)
                .overlay(Text("E").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("Ex tóxica").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondaryLabel)
                Text("Amigos desde agosto").font(.system(size: 9)).foregroundStyle(palette.tertiaryLabel)
            }
            Spacer(minLength: 6)
            pillLabel("Compartir", filled: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .padding(.bottom, 5)
    }

    // MARK: - 4. La decisión

    private var loginPage: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("app_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 44)

                Text("AgruPay")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                    .padding(.top, 10)

                Text("Anotar tus gastos es cosa del pasado")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 24)

                Text("Conecta tu correo y cada consumo queda registrado apenas llega el aviso de tu banco. Sin cuenta también funciona, anotándolos tú.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 28)

                comparison
                    .padding(.top, 22)
                    .padding(.horizontal, 20)

                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.tertiaryLabel)
                    Text("Permiso de solo lectura sobre tu Gmail. Nunca escribimos, enviamos ni borramos correos.")
                        .font(.caption2)
                        .foregroundStyle(palette.tertiaryLabel)
                }
                .padding(.top, 14)
                .padding(.horizontal, 28)

                loginButtons
                    .padding(.top, 26)
                    .padding(.bottom, 34)
            }
        }
        .confirmationDialog("¿Continuar sin cuenta?", isPresented: $showNoAccountConfirm, titleVisibility: .visible) {
            Button("Sin cuenta", role: .destructive) { finish() }
            Button("Conectar") {
                isConnecting = true
                GmailAuthService.shared.signIn()
            }
        } message: {
            Text("Tendrás que anotar cada gasto a mano. Puedes conectar tu correo después en Ajustes.")
        }
    }

    private var comparison: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Text("Con Google").frame(width: 74)
                Text("Sin cuenta").frame(width: 68)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.tertiaryLabel)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            comparisonRow("Lectura automática de gastos del correo", google: true, alone: false)
            comparisonRow("Respaldo en la nube", google: true, alone: false)
            comparisonRow("Sincronización entre dispositivos", google: true, alone: false)
            comparisonRow("Amigos y comparaciones", google: true, alone: false)
            comparisonRow("Presupuesto, categorías y recurrentes", google: true, alone: true, isLast: true)
        }
        .padding(.vertical, 12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.5)
        )
    }

    private func comparisonRow(_ title: String, google: Bool, alone: Bool,
                               isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                mark(google).frame(width: 74)
                mark(alone).frame(width: 68)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if !isLast {
                Rectangle().fill(palette.separator).frame(height: 0.5).padding(.leading, 12)
            }
        }
    }

    private func mark(_ available: Bool) -> some View {
        Image(systemName: available ? "checkmark.circle.fill" : "minus")
            .font(.system(size: available ? 15 : 12, weight: .semibold))
            .foregroundStyle(available ? palette.positive : palette.tertiaryLabel)
    }

    private var loginButtons: some View {
        VStack(spacing: 12) {
            Button {
                isConnecting = true
                GmailAuthService.shared.signIn()
            } label: {
                HStack(spacing: 10) {
                    if isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "envelope.fill").font(.system(size: 15))
                    }
                    Text(isConnecting ? "Conectando…" : "Continuar con Google")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(accent.buttonFill)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)

            // Sin cuenta no hay correo que leer, así que la pantalla de "cuánto
            // leer" no tendría nada que ofrecer: se va directo a la app. Antes de
            // eso, se confirma: es fácil tocarlo sin querer viniendo de "Siguiente".
            Button("Continuar sin cuenta") { showNoAccountConfirm = true }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.secondaryLabel)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Encadenado

    /// Entró con Google: antes de nada, ¿esa cuenta ya tenía un respaldo? Si no
    /// lo tiene —el caso normal de alguien que estrena la app— no se le enseña
    /// una pantalla de recuperación vacía.
    private func finish() {
        // La secuencia ya se hizo aquí dentro; sin esto, la marca que dejó
        // `signIn()` haría que la app la repitiera nada más entrar.
        UserDefaults.standard.set(false, forKey: GmailAuthService.pendingLinkFlowKey)
        hasSeenOnboarding = true
    }
}

// MARK: - Estructura común de las tres primeras

/// Ilustración arriba, título y texto abajo, con un "beat" que avanza mientras
/// la pantalla está visible.
///
/// El beat es el reloj de la animación: cada pieza se compara con él para saber
/// si le toca aparecer. Al salir de la pantalla vuelve a cero, así que la
/// animación se vuelve a ver si el usuario regresa deslizando.
private struct OnboardingSlide<Illustration: View>: View {

    let isActive: Bool
    let title: String
    let subtitle: String
    let footnote: (icon: String, text: String)?
    @ViewBuilder let illustration: (Double) -> Illustration

    @Environment(\.colorScheme) private var scheme
    @State private var beat: Double = 0
    @State private var ticker: Task<Void, Never>?

    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 0) {
            // Fijo, no `Spacer`: si la ilustración cambia de alto —como en la
            // 1, cuando el primer correo colapsa—, un `Spacer` de arriba
            // crecería para absorber ese espacio y empujaría todo hacia abajo
            // en vez de dejar la ilustración anclada arriba.
            Color.clear.frame(height: 12)

            illustration(beat)
                .padding(.horizontal, 22)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.label)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: footnote.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.tertiaryLabel)
                        Text(footnote.text)
                            .font(.caption2)
                            .foregroundStyle(palette.tertiaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 28)
            .frame(height: 190, alignment: .top)

            Spacer(minLength: 96)
        }
        .padding(.top, 44)
        .onAppear { if isActive { start() } }
        .onDisappear { stop() }
        .onChange(of: isActive) { _, active in active ? start() : stop() }
    }

    private func start() {
        stop()
        beat = 0
        ticker = Task { @MainActor in
            // 100 pasos de 100 ms: suficiente para escalonar sin gastar CPU, y
            // con margen para el gesto de categorizar y los cuatro gastos que
            // caen después, en la primera pantalla.
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                beat += 0.1
            }
        }
    }

    private func stop() {
        ticker?.cancel()
        ticker = nil
        beat = 0
    }
}

// MARK: - Medición

/// Para capturar el alto real de una vista y usarlo como punto de partida de
/// una animación —`nil`/`.infinity` no interpolan.
private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Piezas de animación

private extension View {

    /// Equivalente del `agpFadeUp` del diseño: aparece subiendo, cuando el beat
    /// pasa el retardo que le toca.
    func reveal(_ beat: Double, after delay: Double, offset: CGFloat = 12) -> some View {
        let shown = beat >= delay
        return self
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : offset)
            .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.8), value: shown)
    }

    /// `agpBlink`: sólo mientras la app "está procesando" el correo.
    func blink(active: Bool) -> some View {
        modifier(BlinkModifier(active: active))
    }
}

private struct BlinkModifier: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (dim ? 0.35 : 1) : 1)
            .onChange(of: active) { _, isActive in
                guard isActive else { dim = false; return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
