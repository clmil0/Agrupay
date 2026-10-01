import SwiftUI

/// Apariencia y resumen (`4h`): una vista previa del Resumen, los temas por
/// familia —un color, dos colores y los Pro con fondo animado al final—,
/// modo, texto, color y las estadísticas del Resumen.
///
/// Antes eran pestañas (Color · Texto · Voz) con la vista previa fija arriba;
/// ahora es una sola lista, y Estadísticas vive aquí en vez de tener fila
/// propia en la raíz. La vista previa marca con un anillo lo que acaba de
/// cambiar.
struct AppearanceSettingsView: View {

    /// La parte de la vista previa que se ilumina tras un cambio.
    enum Flash { case surface, cats, type, dict }

    /// Los de la fila «Un color»: los clásicos. Los pastel de un color están
    /// en «Ver todos los temas».
    static let singleThemes: [AppThemeColor] = [.blue, .purple, .green, .orange, .red, .charcoal]
    static let duoThemes: [AppThemeColor] = AppThemeColor.allCases.filter(\.isDuotone)

    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue
    @AppStorage(AppTextSize.storageKey) private var appTextSize = AppTextSize.sistema.rawValue
    @AppStorage(AppFontDesign.storageKey) private var appFontDesign = AppFontDesign.sistema.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(AppThemeColor.themedCategoryColorsKey) private var themedCategoryColors = false
    @AppStorage(DictationStyle.storageKey) private var dictationStyle = DictationStyle.bars.rawValue
    @AppStorage(DashboardStatsSettings.key) private var statsRaw = DashboardStatsSettings.defaultValue
    @AppStorage(ProTheme.storageKey) private var proThemeRaw = ""
    @AppStorage(ProStore.enabledKey) private var isPro = false

    @State private var flash: Flash?
    @State private var flashTask: Task<Void, Never>?
    @State private var showsThemeGallery = false
    @State private var paywall: ProStore.Feature?

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }
    private var palette: Palette { Palette(scheme, accent: accent, intense: intenseThemeTint) }
    private var textSize: AppTextSize { AppTextSize(rawValue: appTextSize) ?? .sistema }
    private var fontDesign: AppFontDesign { AppFontDesign(rawValue: appFontDesign) ?? .sistema }
    private var activeProTheme: ProTheme? { isPro ? ProTheme(rawValue: proThemeRaw) : nil }

    var body: some View {
        SettingsPage(title: "Apariencia y resumen") {
            AppearancePreview(palette: palette.themed(activeProTheme), flash: flash, dictationStyle: dictationStyle,
                              amountScale: textSize.amountScale)
                .padding(.horizontal, 16)

            themesSection
            if let activeProTheme {
                ProThemeTuningSection(theme: activeProTheme, onChange: { ring(.surface) })
                    .id(activeProTheme)
            }
            modeSection
            textSection
            colorSection
            voiceSection

            SettingsGroup(title: "Resumen") {
                SettingsLink(icon: "chart.xyaxis.line", tint: Color(hex: 0x5E5CE6),
                             title: "Estadísticas", value: statsValue) {
                    StatsSettingsView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appAccentColor)
        .animation(.easeInOut(duration: 0.3), value: intenseThemeTint)
        .onChange(of: appAccentColor) { _, raw in
            if let theme = AppThemeColor(rawValue: raw) { AppThemeColor.noteUsed(theme) }
            ring(.surface)
        }
        .onChange(of: intenseThemeTint) { _, _ in ring(.surface) }
        .onChange(of: themedCategoryColors) { _, _ in ring(.cats) }
        .onChange(of: appFontDesign) { _, _ in ring(.type) }
        .onChange(of: appTextSize) { _, _ in ring(.type) }
        .onChange(of: dictationStyle) { _, _ in ring(.dict) }
        .onDisappear { flashTask?.cancel() }
        .fullScreenCover(isPresented: $showsThemeGallery) {
            ThemeGalleryView(current: accent) { theme in
                withAnimation(.easeInOut(duration: 0.2)) { pick(theme) }
            }
            .appAppearance()
            .appTextSize()
        }
        .proPaywall($paywall)
    }

    /// Enciende el anillo de una parte de la vista previa durante un segundo.
    private func ring(_ part: Flash) {
        withAnimation(.easeOut(duration: 0.25)) { flash = part }
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) { flash = nil }
        }
    }

    /// Un tema básico quita el tema Pro que hubiera.
    private func pick(_ theme: AppThemeColor) {
        proThemeRaw = ""
        appAccentColor = theme.rawValue
    }

    private var statsValue: String {
        let count = DashboardStatsSettings.decode(statsRaw).count
        return count == 0 ? "Ninguna" : "\(count) de \(DashboardStat.allCases.count)"
    }

    // MARK: - Temas

    private var themesSection: some View {
        SettingsGroup(title: "Temas") {
            VStack(alignment: .leading, spacing: 10) {
                familyLabel("Un color")
                swatchRow(Self.singleThemes)

                familyLabel("Dos colores")
                    .padding(.top, 4)
                swatchRow(Self.duoThemes)

                HStack(spacing: 8) {
                    familyLabel("Premium · con fondo animado")
                    if !isPro { ProBadge() }
                }
                .padding(.top, 4)
                HStack(spacing: 14) {
                    ForEach(ProTheme.allCases) { theme in
                        let selected = activeProTheme == theme
                        Button {
                            guard isPro else { paywall = .themes; return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proThemeRaw = theme.rawValue
                                // El resto de la app toma el tono más
                                // cercano, para que no desentone con el Resumen.
                                appAccentColor = theme.companionAccent.rawValue
                            }
                            ring(.surface)
                        } label: {
                            ProThemeSwatch(theme: theme, size: 40)
                                .padding(3)
                                .overlay(Circle().stroke(selected ? palette.label : .clear, lineWidth: 2))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }

                Button("Ver todos los temas") { showsThemeGallery = true }
                    .font(.subheadline)
                    .foregroundStyle(accent.onSurface(scheme))
                    .buttonStyle(.plain)
                    .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func familyLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(palette.secondaryLabel)
    }

    private func swatchRow(_ themes: [AppThemeColor]) -> some View {
        HStack(spacing: 14) {
            ForEach(themes) { theme in
                let selected = theme == accent && activeProTheme == nil
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pick(theme) }
                } label: {
                    ThemeSwatch(theme: theme, size: 40)
                        .padding(3)
                        .overlay(Circle().stroke(selected ? palette.label : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: - Modo, texto y color

    private var modeSection: some View {
        SettingsGroup(title: "Modo",
                      footer: activeProTheme == nil ? nil : "Los temas Pro son de noche: mientras uses \(activeProTheme?.rawValue ?? ""), la app va en oscuro.") {
            ShellSegment(items: [AppAppearance.dark, .light, .system], selection: appearanceBinding) { option in
                option == .system ? "Sistema" : option.rawValue
            }
            .padding(8)
            .disabled(activeProTheme != nil)
            .opacity(activeProTheme == nil ? 1 : 0.5)
        }
    }

    private var textSection: some View {
        SettingsGroup(title: "Texto") {
            Menu {
                Picker("Tipografía", selection: $appFontDesign) {
                    ForEach(AppFontDesign.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
            } label: {
                SettingsItem(title: "Tipografía") { SettingsValueChevron(value: fontDesign.rawValue) }
            }
            .buttonStyle(.plain)
            SettingsDivider(inset: 14)
            Menu {
                Picker("Tamaño", selection: $appTextSize) {
                    ForEach(AppTextSize.allCases) { option in
                        Text(option.rawValue).tag(option.rawValue)
                    }
                }
            } label: {
                SettingsItem(title: "Tamaño",
                             subtitle: textSize == .sistema ? "El que tengas configurado en iOS" : nil) {
                    SettingsValueChevron(value: textSize.rawValue)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var colorSection: some View {
        SettingsGroup(title: "Color") {
            SettingsToggle(title: "Intensificar el color del tema", subtitle: "Tiñe tarjetas y bordes",
                           isOn: $intenseThemeTint)
            SettingsDivider(inset: 14)
            SettingsToggle(title: "Categorías con colores del tema", isOn: $themedCategoryColors)
        }
    }

    private var voiceSection: some View {
        SettingsGroup(title: "Dictado") {
            Menu {
                Picker("Animación al escuchar", selection: $dictationStyle) {
                    Text("Barras").tag(DictationStyle.bars.rawValue)
                    Text("Orgánica").tag(DictationStyle.blob.rawValue)
                }
            } label: {
                SettingsItem(title: "Animación al escuchar",
                             subtitle: "También se ve en la píldora «Dictar» de la vista previa") {
                    SettingsValueChevron(value: dictationStyle == DictationStyle.blob.rawValue ? "Orgánica" : "Barras")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(get: { appearance }, set: { appearanceRaw = $0.rawValue })
    }
}

// MARK: - Ajustes del tema Pro

/// Matiz e intensidad del cielo del tema Pro elegido. El matiz es una lista
/// cerrada de variantes y no una rueda libre: cada una gira el tono sin
/// tocar la luminosidad, así que todos los textos se siguen leyendo.
private struct ProThemeTuningSection: View {
    let theme: ProTheme
    let onChange: () -> Void

    @Environment(\.colorScheme) private var scheme
    @AppStorage private var toneName: String
    @AppStorage(ProTheme.skyIntensityKey) private var intensity = 1.0

    init(theme: ProTheme, onChange: @escaping () -> Void) {
        self.theme = theme
        self.onChange = onChange
        _toneName = AppStorage(wrappedValue: "", theme.toneKey)
    }

    private var palette: Palette { Palette(scheme).themed(theme) }
    private var selected: ProThemeTone { theme.tone(named: toneName) }
    private var isDefault: Bool { selected == theme.tones[0] && intensity >= 1 }

    var body: some View {
        SettingsGroup(title: "Ajustar \(theme.rawValue)",
                      footer: "Con el cielo más tenue el fondo se oscurece y las tarjetas resaltan más.") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Matiz")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.label)
                        Spacer()
                        Text(selected.name)
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    HStack(spacing: 14) {
                        ForEach(theme.tones) { tone in
                            toneButton(tone)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Brillo del cielo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.label)
                        Spacer()
                        Text("\(Int((intensity * 100).rounded())) %")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(palette.secondaryLabel)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "moon.fill")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryLabel)
                        Slider(value: $intensity, in: ProTheme.skyIntensityRange) { editing in
                            if !editing { onChange() }
                        }
                        .accessibilityLabel("Brillo del cielo")
                        Image(systemName: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(palette.secondaryLabel)
                    }
                }

                if !isDefault {
                    Button("Restablecer \(theme.rawValue)") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toneName = ""
                            intensity = 1
                        }
                        onChange()
                    }
                    .font(.subheadline)
                    .foregroundStyle(palette.expenseText)
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toneButton(_ tone: ProThemeTone) -> some View {
        let isSelected = tone == selected
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                toneName = tone == theme.tones[0] ? "" : tone.name
            }
            onChange()
        } label: {
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.55),
                                              theme.accent(for: tone), theme.base],
                                     center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 30))
                .frame(width: 40, height: 40)
                .padding(3)
                .overlay(Circle().stroke(isSelected ? palette.label : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tone.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Indicador de dictado en miniatura

/// Las mismas animaciones de la hoja de dictado, a escala de muestra.
struct DictationIndicator: View {
    enum Size { case pill, tile }

    let style: DictationStyle
    let size: Size

    private var accent: AppThemeColor { .current }

    var body: some View {
        switch style {
        case .bars:
            DictationBars(level: 0.55, isActive: true,
                          count: size == .pill ? 5 : 14,
                          height: size == .pill ? 18 : 40,
                          spacing: 3)
                .frame(width: size == .pill ? 26 : nil)
        case .blob:
            let diameter: CGFloat = size == .pill ? 26 : 44
            ZStack {
                DictationBlob(level: 0.3, isActive: true, size: diameter)
                Circle()
                    .fill(accent.color)
                    .frame(width: diameter * 0.72, height: diameter * 0.72)
                Image(systemName: "mic.fill")
                    .font(.system(size: diameter * 0.33, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Vista previa

/// Mini-Resumen: chip de cuentas, monto con su delta, barras, dos tarjetas,
/// la píldora de Dictar y el +. Cifras de muestra fijas.
private struct AppearancePreview: View {
    let palette: Palette
    let flash: AppearanceSettingsView.Flash?
    let dictationStyle: String
    let amountScale: CGFloat

    private static let bars: [Double] = [64, 92, 38, 12, 71, 55, 84]

    private var scheme: ColorScheme { palette.scheme }
    private var accent: AppThemeColor { palette.accent }
    private var month: String { Period.spanishMonthName(for: Date()).uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                accountChip
                Spacer()
                Text("VISTA PREVIA")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(palette.tertiaryLabel)
            }

            amount
                .ringed(flash == .type, color: accent.color)

            bars

            HStack(spacing: 10) {
                categoriesCard
                    .ringed(flash == .cats, color: accent.color, radius: 16)
                pendingCard
                    .ringed(flash == .surface, color: accent.color, radius: 16)
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                dictationPill
                    .ringed(flash == .dict, color: accent.color, radius: 19)
                Spacer()
                Circle()
                    .fill(palette.expense)
                    .frame(width: 42, height: 42)
                    .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: palette.expense.opacity(0.38), radius: 11)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background {
            // Con tema Pro, la vista previa lleva su cielo animado.
            if let pro = palette.pro {
                ProThemeBackdrop(theme: pro)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.background)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(palette.label.opacity(0.09), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vista previa del resumen con la apariencia elegida")
    }

    private var accountChip: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.softFill(scheme))
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "building.columns.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(accent.onSurface(scheme)))
            Text("Todas las cuentas")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(palette.label)
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GASTADO EN " + month)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(palette.secondaryLabel)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("S/ 2,612")
                    .font(.system(size: 34 * amountScale, weight: .bold))
                    .tracking(-1.2)
                    .foregroundStyle(palette.label)
                Text(".40")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                Text("↑ S/ 318 vs. mes anterior")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.isDuotone ? accent.secondaryOnSurface(scheme) : accent.onSurface(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accent.isDuotone ? accent.secondarySoftFill(scheme) : palette.expenseSoft,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.leading, 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(2)
    }

    private var bars: some View {
        let top = palette.expense.mixed(with: .white, amount: 0.28, scheme: scheme)
        let peak = Self.bars.max() ?? 1
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, value in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinearGradient(colors: [palette.expense, top], startPoint: .bottom, endPoint: .top))
                    .frame(height: max(4, 58 * value / peak))
                    .opacity(index == Self.bars.count - 1 ? 1 : 0.55)
            }
        }
        .frame(height: 58)
    }

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Categorías")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.label)
            ForEach(["Comida", "Transporte"], id: \.self) { name in
                let color = CategoryStyle.color(for: name, accent: accent.color)
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color.opacity(0.22))
                        .frame(width: 22, height: 22)
                        .overlay(Image(systemName: CategoryStyle.icon(for: name))
                            .font(.system(size: 11))
                            .foregroundStyle(color))
                    Text(name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.label)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pendientes")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.label)
            Text("3")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(accent.secondaryOnSurface(scheme))
            Text("de este mes")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    private var dictationPill: some View {
        HStack(spacing: 8) {
            DictationIndicator(style: DictationStyle(rawValue: dictationStyle) ?? .bars, size: .pill)
                .frame(width: 30, height: 30)
            Text("Escuchando…")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent.onSurface(scheme))
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 38)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }
}

private extension View {
    /// El anillo de «esto cambió»: borde del acento con un halo suave.
    func ringed(_ on: Bool, color: Color, radius: CGFloat = 10) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(color, lineWidth: 2)
                .padding(-2)
                .background(
                    RoundedRectangle(cornerRadius: radius + 5, style: .continuous)
                        .stroke(color.opacity(0.22), lineWidth: 5)
                        .padding(-4.5)
                )
                .opacity(on ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Muestra de tema

/// Círculo del tema: entero en los de un color, partido a la mitad en los de
/// dos, para que se note de un vistazo.
struct ThemeSwatch: View {
    let theme: AppThemeColor
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            if theme.isDuotone {
                Circle()
                    .trim(from: 0, to: 0.5)
                    .fill(theme.color)
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.5, to: 1)
                    .fill(theme.secondaryColor)
                    .rotationEffect(.degrees(90))
            } else {
                Circle().fill(theme.color)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Galería de temas

/// Modal a pantalla completa con todos los temas (`1e`). Cada tarjeta es un
/// mini-Resumen con los colores de ese tema; elegir uno sólo lo marca, y
/// "Usar …" lo aplica y cierra.
struct ThemeGalleryView: View {

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos"
        case single = "Un color"
        case duo = "Dos colores"
        var id: String { rawValue }
    }

    let current: AppThemeColor
    var onApply: (AppThemeColor) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var draft: AppThemeColor
    @State private var filter: Filter = .all

    init(current: AppThemeColor, onApply: @escaping (AppThemeColor) -> Void) {
        self.current = current
        self.onApply = onApply
        _draft = State(initialValue: current)
    }

    /// La galería se pinta con el tema que se está probando, no con el guardado.
    private var palette: Palette { Palette(scheme, accent: draft).withoutPro() }

    private var themes: [AppThemeColor] {
        let filtered = AppThemeColor.allCases.filter { theme in
            switch filter {
            case .all: return true
            case .single: return !theme.isDuotone
            case .duo: return theme.isDuotone
            }
        }
        // El tema en uso va primero.
        return filtered.filter { $0 == current } + filtered.filter { $0 != current }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Filtro", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)],
                          spacing: 11) {
                    ForEach(themes) { theme in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { draft = theme }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            ThemeGalleryCard(theme: theme, isSelected: draft == theme, palette: palette)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.rawValue)
                        .accessibilityAddTraits(draft == theme ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .animation(.easeInOut(duration: 0.2), value: filter)
            }

            footer
        }
        .background(palette.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("Temas")
                .font(.title2.bold())
                .foregroundStyle(palette.label)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 30, height: 30)
                    .background(palette.track)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Text(draft.isDuotone
                 ? "El segundo color se usa en ingresos, “hoy” y lo que baja."
                 : "Un solo color para gasto, ingresos y “hoy”.")
                .font(.caption)
                .foregroundStyle(palette.secondaryLabel)
                .multilineTextAlignment(.center)

            Button {
                onApply(draft)
                dismiss()
            } label: {
                Text(draft == current ? "Seguir con " + draft.rawValue : "Usar " + draft.rawValue)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(draft.color)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            palette.surfaceElevated.opacity(0.92)
                .overlay(alignment: .top) {
                    Rectangle().fill(palette.separator).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Mini-Resumen con los colores de un tema.
private struct ThemeGalleryCard: View {

    let theme: AppThemeColor
    let isSelected: Bool
    let palette: Palette

    private var scheme: ColorScheme { palette.scheme }
    private var dark: Bool { scheme == .dark }
    private var miniTrack: Color { dark ? Color.white.opacity(0.14) : Color(red: 0.890, green: 0.890, blue: 0.909) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("GASTADO")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.onSurface(scheme))
                Text("S/ 1,842")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(dark ? Color.white : Color.black)
                    .padding(.top, 2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(miniTrack)
                        Capsule()
                            .fill(theme.color)
                            .frame(width: geo.size.width * 0.72)
                    }
                }
                .frame(height: 5)
                .padding(.top, 6)

                HStack(spacing: 4) {
                    Capsule().fill(theme.color)
                    Capsule().fill(theme.isDuotone ? theme.secondaryColor : theme.color.opacity(0.45))
                    Capsule().fill(miniTrack)
                }
                .frame(height: 12)
                .padding(.top, 7)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (dark ? Color(red: 0.082, green: 0.082, blue: 0.090) : Color.white)
                    .mixed(with: theme.color, amount: dark ? 0.08 : 0.05, scheme: scheme)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 6) {
                ThemeSwatch(theme: theme, size: 14)
                Text(theme.rawValue)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(theme.onSurface(scheme))
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(9)
        // Seleccionado = tinte del propio tema, sin borde de color.
        .background(isSelected ? theme.softFill(scheme) : Palette(scheme, accent: theme).withoutPro().surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette(scheme, accent: theme).withoutPro().hairline, lineWidth: 0.5)
        )
    }
}
