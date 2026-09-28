import SwiftUI
import SwiftData

/// El logo de una cuenta: el de su banco o billetera si hay asset, y si no un
/// símbolo (efectivo, una tarjeta sin banco, una persona).
struct AccountLogo: View {
    let institution: Institution?
    var size: CGFloat = 26

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        if let asset = institution?.logoAsset {
            Image(asset)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .background(Color.white)
                .clipShape(Circle())
        } else {
            Image(systemName: institution?.symbol ?? "person.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(palette.secondaryLabel)
                .frame(width: size, height: size)
                .background(palette.track, in: Circle())
        }
    }
}

/// Cómo se llama y cómo se dibuja una cuenta del catálogo, ya con el nombre
/// que le diste en «Tus cuentas».
struct AccountBadge: Equatable {
    let name: String
    let institution: Institution?
}

// MARK: - Carrusel (`2c`)

/// Historial › Movimientos: las cuentas tuyas como tarjetas, para filtrar la
/// lista por una. «Todas» va primero y «Editar» queda fijo al borde derecho,
/// siempre a mano aunque haya diez cuentas.
///
/// Cada tarjeta se viste como la de su banco —el degradado de su marca, un
/// motivo propio (la franja naranja del BCP, la banda azul de Interbank…) y el
/// chip—, con la proporción de una tarjeta física (152 × 96, casi 1.586 : 1).
/// Así se reconoce de un vistazo sin leer el nombre. La elegida lleva un aro
/// por fuera, separado del borde: el color de la tarjeta ya es del banco, así
/// que el estado no puede ir en el relleno.
struct AccountCarousel: View {
    let accounts: [DetectedAccount]
    let name: (DetectedAccount) -> String
    /// Movimientos de la lista actual (Gastos, Ingresos o Por cobrar) por
    /// cuenta. Una cuenta sin ninguno sigue ahí: el carrusel no salta al
    /// cambiar de pestaña.
    let counts: [String: Int]
    let total: Int
    @Binding var selection: String?
    let onEdit: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    private static let cardSize = CGSize(width: 152, height: 96)
    private static let radius: CGFloat = 12
    private static let editWidth: CGFloat = 52
    /// Aire alrededor de las tarjetas para que el aro de la elegida y la
    /// sombra no se corten contra el borde del `ScrollView`.
    private static let ringRoom: CGFloat = 5

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                card(selected: selection == nil, face: .all, label: "Todas las cuentas") {
                    selection = nil
                } top: {
                    stackedCards
                    Spacer(minLength: 4)
                    digits(accounts.count == 1 ? "1 cuenta" : "\(accounts.count) cuentas")
                } bottom: {
                    title("Todas")
                    line(movements(total))
                }

                ForEach(accounts) { account in
                    let isOn = selection == account.key
                    let institution = account.institution ?? account.via
                    card(selected: isOn, face: CardFace(institution), label: name(account)) {
                        selection = isOn ? nil : account.key
                    } top: {
                        logo(institution)
                        Spacer(minLength: 4)
                        if let last = account.digits {
                            digits("•• " + last)
                        } else {
                            contactless
                        }
                    } bottom: {
                        title(name(account))
                        line(movements(counts[account.key] ?? 0))
                    }
                }
            }
            .padding(.vertical, Self.ringRoom + 3)
            .padding(.leading, ShellMetrics.sideInset)
            .padding(.trailing, ShellMetrics.sideInset + Self.editWidth + 14)
        }
        .overlay(alignment: .trailing) { editTile }
    }

    private func movements(_ count: Int) -> String {
        count == 1 ? "1 movimiento" : "\(count) movimientos"
    }

    // MARK: Piezas

    private func card<Top: View, Bottom: View>(selected: Bool,
                                               face: CardFace,
                                               label: String,
                                               action: @escaping () -> Void,
                                               @ViewBuilder top: () -> Top,
                                               @ViewBuilder bottom: () -> Bottom) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) { top() }
                    .frame(height: 20)
                Spacer(minLength: 0)
                EMVChip()
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 1) { bottom() }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height, alignment: .topLeading)
            .background { CardBackground(face: face) }
            .clipShape(shape)
            // Filo de luz arriba y sombra abajo: el borde de una tarjeta de
            // plástico, no una línea dibujada.
            .overlay(shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75))
            .shadow(color: face.shadow.opacity(scheme == .dark ? 0.45 : 0.28), radius: 6, y: 3)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Self.radius + 4, style: .continuous)
                        .strokeBorder(scheme == .dark ? palette.label : accent.color, lineWidth: 2)
                        .padding(-Self.ringRoom)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// El logo sobre la tarjeta. Sin asset (efectivo, una tarjeta sin banco)
    /// va el símbolo en blanco sobre un vidrio, que sí se lee sobre el color.
    @ViewBuilder
    private func logo(_ institution: Institution?) -> some View {
        if institution?.logoAsset != nil {
            AccountLogo(institution: institution, size: 20)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.75))
        } else {
            Image(systemName: institution?.symbol ?? "person.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.22), in: Circle())
        }
    }

    private var contactless: some View {
        Image(systemName: "wave.3.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
    }

    /// El ícono de «Todas»: dos tarjetas encimadas.
    private var stackedCards: some View {
        HStack(spacing: -8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white.opacity(0.35))
                .frame(width: 14, height: 20)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white.opacity(0.85))
                .frame(width: 14, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(.black.opacity(0.25), lineWidth: 1))
        }
    }

    private func digits(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
    }

    /// Fijo al borde, sobre un degradado que funde las tarjetas que pasan por
    /// debajo.
    private var editTile: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)

        return HStack(spacing: 0) {
            LinearGradient(colors: [palette.background.opacity(0), palette.background],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 30)

            Button(action: onEdit) {
                Text("Editar")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accent.onSurface(scheme))
                    .frame(width: Self.editWidth, height: Self.cardSize.height)
                    .background(palette.background, in: shape)
                    .overlay(shape.strokeBorder(palette.secondaryLabel.opacity(0.45),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Editar tus cuentas")
            .padding(.trailing, ShellMetrics.sideInset)
            .frame(maxHeight: .infinity)
            .background(palette.background)
        }
        .frame(height: Self.cardSize.height + 2 * (Self.ringRoom + 3))
    }
}

// MARK: - Cara de la tarjeta

/// Cómo se viste cada banco: los colores de su degradado y el motivo que lo
/// distingue. Son aproximaciones a la tarjeta real, no la tarjeta: nada de
/// logos de red ni textos que no son de la app.
struct CardFace: Equatable {
    enum Motif: Equatable {
        /// BBVA: círculos grandes y translúcidos, como su tarjeta azul.
        case rings
        /// BCP: franja naranja en diagonal sobre el azul.
        case stripe(Color)
        /// Interbank: banda ancha de otro color cruzando la esquina.
        case band(Color)
        /// Yape y Plin: una mancha de color que asoma por abajo.
        case blob(Color)
        /// Scotiabank, efectivo, genéricas: un arco de luz.
        case arc
    }

    let colors: [Color]
    let motif: Motif
    var shadow: Color { colors.last ?? .black }

    static let all = CardFace(colors: [Color(hex: 0x3A3A40), Color(hex: 0x16161A)], motif: .arc)

    init(colors: [Color], motif: Motif) {
        self.colors = colors
        self.motif = motif
    }

    init(_ institution: Institution?) {
        switch institution {
        case .bbva?:
            self.init(colors: [Color(hex: 0x1973B8), Color(hex: 0x072146)], motif: .rings)
        case .bcp?:
            self.init(colors: [Color(hex: 0x0A3A9E), Color(hex: 0x002169)], motif: .stripe(Color(hex: 0xFF7800)))
        case .interbank?:
            self.init(colors: [Color(hex: 0x12B563), Color(hex: 0x05783D)], motif: .band(Color(hex: 0x0039A6)))
        case .scotiabank?:
            self.init(colors: [Color(hex: 0xF0282E), Color(hex: 0x9E0A0F)], motif: .arc)
        case .yape?:
            self.init(colors: [Color(hex: 0x8E2BA3), Color(hex: 0x4A0F5C)], motif: .blob(Color(hex: 0x10D4C2)))
        case .plin?:
            self.init(colors: [Color(hex: 0x16C7E0), Color(hex: 0x0070B8)], motif: .blob(Color(hex: 0x7CF2FF)))
        case .efectivo?:
            self.init(colors: [Color(hex: 0x22C58B), Color(hex: 0x087A55)], motif: .arc)
        case .tarjeta?, nil:
            self.init(colors: [Color(hex: 0x5B6270), Color(hex: 0x262A33)], motif: .arc)
        }
    }
}

/// El fondo de la tarjeta: degradado, motivo y un brillo diagonal encima.
private struct CardBackground: View {
    let face: CardFace

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                LinearGradient(colors: face.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

                motif(w: w, h: h)

                // Brillo de plástico: una luz suave que cruza de arriba a la
                // izquierda hacia el centro.
                LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.0)],
                               startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.7))
                    .blendMode(.softLight)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func motif(w: CGFloat, h: CGFloat) -> some View {
        switch face.motif {
        case .rings:
            ZStack {
                Circle().stroke(.white.opacity(0.10), lineWidth: 14)
                    .frame(width: h * 1.5, height: h * 1.5)
                    .position(x: w * 0.92, y: h * 0.15)
                Circle().fill(.white.opacity(0.07))
                    .frame(width: h * 1.1, height: h * 1.1)
                    .position(x: w * 1.0, y: h * 1.0)
            }
        case .stripe(let color):
            Path { p in
                p.move(to: CGPoint(x: w * 0.62, y: h))
                p.addLine(to: CGPoint(x: w * 0.86, y: h))
                p.addLine(to: CGPoint(x: w * 1.1, y: 0))
                p.addLine(to: CGPoint(x: w * 0.86, y: 0))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [color, color.opacity(0.75)],
                                 startPoint: .bottom, endPoint: .top))
            .opacity(0.9)
        case .band(let color):
            Path { p in
                p.move(to: CGPoint(x: w * 0.45, y: h))
                p.addQuadCurve(to: CGPoint(x: w, y: h * 0.25),
                               control: CGPoint(x: w * 0.8, y: h * 0.85))
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }
            .fill(color.opacity(0.85))
        case .blob(let color):
            Ellipse()
                .fill(RadialGradient(colors: [color.opacity(0.75), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: w * 0.45))
                .frame(width: w * 1.0, height: h * 1.1)
                .position(x: w * 0.95, y: h * 0.95)
        case .arc:
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 10)
                .frame(width: w * 0.9, height: w * 0.9)
                .position(x: w * 0.95, y: h * 1.05)
        }
    }
}

/// El chip de contacto, en dorado. Es lo que hace que un rectángulo de color
/// se lea como tarjeta.
private struct EMVChip: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [Color(hex: 0xF4DC9A), Color(hex: 0xC9A24E)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 20, height: 15)
            .overlay {
                // Las pistas del contacto: una línea al medio y dos cortes.
                ZStack {
                    Rectangle().fill(.black.opacity(0.22)).frame(height: 0.75)
                    HStack(spacing: 6) {
                        Rectangle().fill(.black.opacity(0.22)).frame(width: 0.75)
                        Rectangle().fill(.black.opacity(0.22)).frame(width: 0.75)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay(shape.stroke(.black.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Tus cuentas (`1c`)

/// «Editar» del carrusel: las cuentas detectadas en tus movimientos, cuáles
/// son tuyas, cómo se llaman y en qué orden van.
///
/// Todo lo que esté aquí marcado es tuyo, y lo que se mueva **hacia** una
/// cuenta tuya es traslado: no cuenta como gasto (ni como ingreso del otro
/// lado). No hay «agrupar»: la app no lleva saldos, sólo evita contar dos
/// veces el mismo dinero.
///
/// Los cambios son un borrador hasta «Listo»; «Cancelar» no toca nada.
struct AccountsSheet: View {
    let catalog: AccountCatalog

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @State private var draft: AccountPreferences
    @State private var query = ""

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    init(catalog: AccountCatalog, preferences: AccountPreferences) {
        self.catalog = catalog
        _draft = State(initialValue: preferences)
    }

    // MARK: Datos

    private func matches(_ account: DetectedAccount) -> Bool {
        let needle = AccountResolver.folded(query)
        guard !needle.isEmpty else { return true }
        return AccountResolver.folded(draft.name(for: account)).contains(needle)
            || AccountResolver.folded(account.detectedName).contains(needle)
            || (account.digits?.contains(needle) ?? false)
    }

    private var mine: [DetectedAccount] {
        draft.carousel(from: catalog).filter(matches)
    }

    /// Primero tus tarjetas apagadas, luego los destinatarios por cuántas
    /// veces les enviaste: el tuyo suele estar entre los primeros.
    private var others: [DetectedAccount] {
        catalog.accounts.values
            .filter { !draft.isMine($0.key) && matches($0) }
            .sorted { a, b in
                if a.isOrigin != b.isOrigin { return a.isOrigin }
                if a.count != b.count { return a.count > b.count }
                return a.detectedName < b.detectedName
            }
    }

    // MARK: Vista

    var body: some View {
        let mine = self.mine
        let others = self.others

        NavigationStack {
            List {
                Section {
                    Text("Marca las cuentas que son tuyas. Lo que se mueva hacia ellas se registra como traslado y no cuenta como gasto.")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryLabel)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 0, trailing: 6))
                }

                if !mine.isEmpty {
                    Section {
                        ForEach(mine) { account in
                            row(account, isMine: true)
                        }
                        .onMove(perform: query.isEmpty ? move : nil)
                    } header: {
                        header("En tu carrusel", count: mine.count)
                    } footer: {
                        Text("Mantén pulsado para cambiar el orden. Toca el nombre para renombrarla.")
                    }
                }

                if !others.isEmpty {
                    Section {
                        ForEach(others) { account in
                            row(account, isMine: false)
                        }
                    } header: {
                        header("Otras detectadas", count: others.count)
                    } footer: {
                        Text("Si un destinatario eres tú —tu Plin, tu otra cuenta—, márcalo: lo que le envíes dejará de contar como gasto, y lo que te llegue de él, como ingreso.")
                    }
                }

                if mine.isEmpty && others.isEmpty {
                    Section {
                        VStack(spacing: 6) {
                            Text(query.isEmpty ? "Aún no hay cuentas" : "Sin coincidencias")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(palette.label)
                            Text("Las cuentas aparecen aquí cuando la app lee un aviso de ese banco o billetera.")
                                .font(.system(size: 13.5))
                                .foregroundStyle(palette.secondaryLabel)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // Sin el margen de arriba de la lista, el texto queda pegado al
            // buscador en vez de a una pantalla de distancia.
            .contentMargins(.top, 0, for: .scrollContent)
            .searchable(text: $query,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Busca entre las cuentas detectadas")
            .navigationTitle("Tus cuentas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(accent.onSurface(scheme))
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
        }
    }

    private func row(_ account: DetectedAccount, isMine: Bool) -> some View {
        HStack(spacing: 10) {
            if isMine {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.tertiaryLabel)
                    .frame(width: 14)
            }

            AccountLogo(institution: account.institution ?? account.via, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                if isMine {
                    TextField(account.detectedName, text: nameBinding(account))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                } else {
                    Text(draft.name(for: account))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                }

                Text(meta(account))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Toggle("", isOn: mineBinding(account))
                .labelsHidden()
                .tint(accent.color)
                .accessibilityLabel(draft.name(for: account) + ", es tuya")
        }
        .padding(.vertical, 2)
    }

    private func meta(_ account: DetectedAccount) -> String {
        let count = account.count == 1 ? "1 movimiento" : "\(account.count) movimientos"
        let renamed = draft.names[account.key].map { !$0.isEmpty } ?? false
        var parts: [String] = []
        if account.isOrigin {
            if let digits = account.digits { parts.append("•••• " + digits) }
            if account.institution == .efectivo { parts.append("Anotados a mano") }
            if renamed { parts.insert(account.detectedName, at: 0) }
        } else {
            if renamed { parts.append(account.detectedName) }
            if let phone = account.phone { parts.append("Cel. •" + phone) }
            switch account.via {
            case .yape?: parts.append("Por Yape")
            case .plin?: parts.append("Por Plin")
            case .bbva?: parts.append("Transferencia BBVA")
            case .some(let other): parts.append("Por " + other.name)
            case nil:    parts.append("Te envía dinero")
            }
        }
        parts.append(count)
        return parts.joined(separator: " · ")
    }

    // MARK: Borrador

    private func nameBinding(_ account: DetectedAccount) -> Binding<String> {
        Binding {
            draft.name(for: account)
        } set: { value in
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            var unnamed = draft
            unnamed.names[account.key] = nil
            draft.names[account.key] = trimmed.isEmpty || trimmed == unnamed.name(for: account) ? nil : value
        }
    }

    private func mineBinding(_ account: DetectedAccount) -> Binding<Bool> {
        Binding {
            draft.isMine(account.key)
        } set: { isOn in
            withAnimation(.easeInOut(duration: 0.22)) {
                // Sólo se guarda lo que difiere del valor por defecto.
                draft.mine[account.key] = isOn == AccountResolver.isOrigin(account.key) ? nil : isOn
                draft.order.removeAll { $0 == account.key }
                if isOn { draft.order = draft.carousel(from: catalog).map(\.key).filter { $0 != account.key } + [account.key] }
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var keys = draft.carousel(from: catalog).map(\.key)
        keys.move(fromOffsets: source, toOffset: destination)
        draft.order = keys
    }

    private func save() {
        AccountBook.shared.replace(with: draft)
        TransferDetector.apply(in: modelContext, preferences: draft)
        dismiss()
    }
}

fileprivate extension Color {
    /// `0xRRGGBB`, para escribir los colores de marca tal como se publican.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
