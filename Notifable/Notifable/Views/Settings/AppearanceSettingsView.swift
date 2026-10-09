import SwiftUI

/// Apariencia (`2c`): una vista previa del Resumen, los temas en tres
/// pestañas —un color, dos colores y Premium, con los Premium separados en
/// Día y Noche—, el modo, el tamaño del texto y, plegadas en «Avanzadas», la
/// tipografía, el tinte, los colores de categoría y la animación del dictado.
///
/// Ya no hay modal «Ver todos los temas»: todos están a la vista en su
/// pestaña. La vista previa marca con un anillo lo que acaba de cambiar.
struct AppearanceSettingsView: View {

    /// La parte de la vista previa que se ilumina tras un cambio.
    enum Flash { case surface, cats, type }

    enum Family: String, CaseIterable, Identifiable {
        case single = "Un color"
        case duo = "Dos colores"
        case premium = "Premium"
        var id: String { rawValue }
    }

    static let singleThemes: [AppThemeColor] = [.blue, .purple, .green, .orange, .red, .charcoal,
                                                .lilac, .mint, .salmon, .lightBlue, .pink, .sand, .peony]
    static let duoThemes: [AppThemeColor] = AppThemeColor.allCases.filter(\.isDuotone)

    @Environment(\.colorScheme) private var scheme
    @AppStorage(AppThemeColor.storageKey) private var appAccentColor = AppThemeColor.blue.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.dark.rawValue
    @AppStorage(AppTextSize.storageKey) private var appTextSize = AppTextSize.sistema.rawValue
    @AppStorage(AppFontDesign.storageKey) private var appFontDesign = AppFontDesign.sistema.rawValue
    @AppStorage(AppThemeColor.intenseTintKey) private var intenseThemeTint = false
    @AppStorage(AppThemeColor.themedCategoryColorsKey) private var themedCategoryColors = false
    @AppStorage(DictationStyle.storageKey) private var dictationStyle = DictationStyle.bars.rawValue
    @AppStorage(ProTheme.storageKey) private var proThemeRaw = ""
    @AppStorage(ProStore.enabledKey) private var isPro = false

    @State private var flash: Flash?
    @State private var flashTask: Task<Void, Never>?
    @State private var paywall: ProStore.Feature?
    /// La pestaña elegida a mano; sin elegir, la del tema en uso.
    @State private var pickedFamily: Family?
    @State private var showsAdvanced = false

    private var accent: AppThemeColor { AppThemeColor(rawValue: appAccentColor) ?? .blue }
    private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }
    private var palette: Palette { Palette(scheme, accent: accent, intense: intenseThemeTint) }
    private var textSize: AppTextSize { AppTextSize(rawValue: appTextSize) ?? .sistema }
    private var fontDesign: AppFontDesign { AppFontDesign(rawValue: appFontDesign) ?? .sistema }
    private var activeProTheme: ProTheme? { isPro ? ProTheme(rawValue: proThemeRaw) : nil }

    private var family: Family {
        if let pickedFamily { return pickedFamily }
        if activeProTheme != nil { return .premium }
        return accent.isDuotone ? .duo : .single
    }

    var body: some View {
        SettingsPage(title: "Apariencia") {
            AppearancePreview(palette: palette.themed(activeProTheme), flash: flash,
                              fontDesign: fontDesign.design, amountScale: textSize.amountScale)
                .padding(.horizontal, 16)

            themesSection
            if let activeProTheme {
                ProThemeTuningSection(theme: activeProTheme, onChange: { ring(.surface) })
                    .id(activeProTheme)
            } else {
                modeSection
            }
            textSizeSection
            advancedSection
        }
        .animation(.easeInOut(duration: 0.3), value: appAccentColor)
        .animation(.easeInOut(duration: 0.3), value: proThemeRaw)
        .animation(.easeInOut(duration: 0.3), value: intenseThemeTint)
        .onChange(of: appAccentColor) { _, _ in ring(.surface) }
        .onChange(of: intenseThemeTint) { _, _ in ring(.surface) }
        .onChange(of: themedCategoryColors) { _, _ in ring(.cats) }
        .onChange(of: appFontDesign) { _, _ in ring(.type) }
        .onChange(of: appTextSize) { _, _ in ring(.type) }
        .onDisappear { flashTask?.cancel() }
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
        Analytics.track(.themeChanged, ["theme": theme.rawValue, "pro": false])
        proThemeRaw = ""
        appAccentColor = theme.rawValue
    }

    private func pick(_ theme: ProTheme) {
        guard isPro else {
            Analytics.tap("appearance.locked_theme", ["theme": theme.rawValue])
            paywall = .themes
            return
        }
        Analytics.track(.themeChanged, ["theme": theme.rawValue, "pro": true])
        Analytics.featureUsed(.proTheme)
        Analytics.proFeatureUsed(.themes)
        proThemeRaw = theme.rawValue
        // El resto de la app toma el tono más cercano, para que no
        // desentone con el Resumen.
        appAccentColor = theme.companionAccent.rawValue
        ring(.surface)
    }

    // MARK: - Temas

    private var themesSection: some View {
        SettingsGroup(title: "Temas") {
            VStack(alignment: .leading, spacing: 14) {
                familyTabs

                switch family {
                case .single:
                    basicGrid(Self.singleThemes, columns: 6, size: 42)
                case .duo:
                    basicGrid(Self.duoThemes, columns: 4, size: 50)
                case .premium:
                    VStack(alignment: .leading, spacing: 10) {
                        periodLabel("Día", icon: "sun.max.fill")
                        premiumGrid(ProTheme.day)
                        periodLabel("Noche", icon: "moon.fill")
                            .padding(.top, 2)
                        premiumGrid(ProTheme.night)
                    }
                }

                Text(familyDescription)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var familyTabs: some View {
        HStack(spacing: 4) {
            ForEach(Family.allCases) { item in
                let selected = item == family
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pickedFamily = item }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.rawValue)
                        if item == .premium { ProBadge() }
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? palette.label : palette.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background { if selected { Capsule().fill(palette.selectedFill) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(palette.background, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
    }

    private func periodLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(palette.secondaryLabel)
    }

    private func grid(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    private func basicGrid(_ themes: [AppThemeColor], columns: Int, size: CGFloat) -> some View {
        LazyVGrid(columns: grid(columns), spacing: 12) {
            ForEach(themes) { theme in
                let selected = theme == accent && activeProTheme == nil
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pick(theme) }
                } label: {
                    swatchTile(name: theme.rawValue, selected: selected, size: size) {
                        ThemeSwatch(theme: theme, size: size - 6)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func premiumGrid(_ themes: [ProTheme]) -> some View {
        LazyVGrid(columns: grid(6), spacing: 12) {
            ForEach(themes) { theme in
                let selected = activeProTheme == theme
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { pick(theme) }
                } label: {
                    swatchTile(name: theme.rawValue, selected: selected, size: 42) {
                        ProThemeSwatch(theme: theme, size: 36, sparkle: false)
                            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 0.5))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// Un tema de la cuadrícula: su círculo con el anillo y la palomita si
    /// está elegido, y el nombre debajo.
    private func swatchTile<Swatch: View>(name: String, selected: Bool, size: CGFloat,
                                          @ViewBuilder swatch: () -> Swatch) -> some View {
        VStack(spacing: 5) {
            swatch()
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                        .opacity(selected ? 1 : 0)
                }
                .padding(3)
                .overlay(Circle().stroke(selected ? palette.label : .clear, lineWidth: 2))
                .frame(width: size, height: size)
            Text(name)
                .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? palette.label : palette.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
    }

    private var familyDescription: String {
        if let activeProTheme {
            return "\(activeProTheme.rawValue) · \(activeProTheme.isLight ? "Día" : "Noche") — \(activeProTheme.blurb) Los temas Premium requieren Pro."
        }
        if family == .premium {
            return "Fondos animados de día y de noche. Los temas Premium requieren Pro."
        }
        return accent.isDuotone
            ? "\(accent.rawValue) — El segundo color se usa en ingresos, “hoy” y lo que baja. Incluido sin Pro."
            : "\(accent.rawValue) — Un solo color para gasto, ingresos y “hoy”. Incluido sin Pro."
    }

    // MARK: - Modo y texto

    private var modeSection: some View {
        SettingsGroup(title: "Modo", footer: "Sistema sigue el modo de tu iPhone.") {
            ShellSegment(items: [AppAppearance.dark, .light, .system], selection: appearanceBinding) { option in
                option == .system ? "Sistema" : option.rawValue
            }
            .padding(8)
        }
    }

    private var textSizeSection: some View {
        SettingsGroup(title: "Tamaño del texto") {
            ShellSegment(items: AppTextSize.allCases, selection: textSizeBinding) { $0.rawValue }
                .padding(8)
        }
    }

    // MARK: - Avanzadas

    private var advancedSection: some View {
        SettingsGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { showsAdvanced.toggle() }
            } label: {
                SettingsItem(icon: "slider.horizontal.3", tint: palette.expense,
                             title: "Avanzadas", subtitle: "Tipografía, color y dictado") {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.tertiaryLabel)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvanced ? "Abiertas" : "Cerradas")

            if showsAdvanced {
                SettingsDivider(inset: 14)
                segmentRow("Tipografía") {
                    ShellSegment(items: AppFontDesign.allCases, selection: fontDesignBinding) { $0.rawValue }
                }
                // El tinte es de los temas básicos: los Premium ya traen sus
                // superficies.
                if activeProTheme == nil {
                    SettingsDivider(inset: 14)
                    SettingsToggle(title: "Intensificar el color del tema", subtitle: "Tiñe tarjetas y bordes",
                                   isOn: $intenseThemeTint)
                }
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Categorías con colores del tema", isOn: $themedCategoryColors)
                SettingsDivider(inset: 14)
                segmentRow("Animación al dictar") {
                    ShellSegment(items: [DictationStyle.bars, .blob], selection: dictationBinding) {
                        $0 == .blob ? "Orgánica" : "Barras"
                    }
                }
            }
        }
    }

    private func segmentRow<Segment: View>(_ title: String, @ViewBuilder segment: () -> Segment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .foregroundStyle(palette.label)
            segment()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(get: { appearance }, set: { appearanceRaw = $0.rawValue })
    }

    private var textSizeBinding: Binding<AppTextSize> {
        Binding(get: { textSize }, set: { appTextSize = $0.rawValue })
    }

    private var fontDesignBinding: Binding<AppFontDesign> {
        Binding(get: { fontDesign }, set: { appFontDesign = $0.rawValue })
    }

    private var dictationBinding: Binding<DictationStyle> {
        Binding(get: { DictationStyle(rawValue: dictationStyle) ?? .bars },
                set: { dictationStyle = $0.rawValue })
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
        VStack(alignment: .leading, spacing: 8) {
            // El rótulo de `SettingsGroup`, con «Restablecer» a la derecha.
            HStack {
                Text("Ajustar \(theme.rawValue)".uppercased())
                    .font(.caption)
                    .tracking(0.3)
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                if !isDefault {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toneName = ""
                            intensity = 1
                        }
                        onChange()
                    } label: {
                        Label("Restablecer", systemImage: "arrow.counterclockwise")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.expenseText)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .frame(minHeight: 20)
            .padding(.horizontal, 20)

            SettingsGroup(footer: "Con el cielo más tenue las tarjetas resaltan más. \(theme.rawValue) es de \(theme.isLight ? "Día" : "Noche"): la app va en \(theme.isLight ? "claro" : "oscuro") mientras lo uses.") {
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
                            .tint(palette.expense)
                            .accessibilityLabel("Brillo del cielo")
                            Image(systemName: "sparkles")
                                .font(.footnote)
                                .foregroundStyle(palette.secondaryLabel)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                .fill(RadialGradient(colors: [Color.white.opacity(0.6),
                                              theme.accent(for: tone), theme.base],
                                     center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 30))
                .overlay(Circle().stroke(Color.black.opacity(theme.isLight ? 0.1 : 0), lineWidth: 0.5))
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

// MARK: - Vista previa

/// Mini-Resumen: chip de cuentas, monto con su delta, las barras del
/// gráfico de siempre —carril gris y sólo hoy en color, con su monto— y dos
/// tarjetas. Cifras de muestra fijas.
private struct AppearancePreview: View {
    let palette: Palette
    let flash: AppearanceSettingsView.Flash?
    let fontDesign: Font.Design
    let amountScale: CGFloat

    private static let days = ["D", "L", "M", "X", "J", "V", "S"]
    private static let values: [Double] = [64, 112, 38, 156, 92, 0, 180]

    private var scheme: ColorScheme { palette.scheme }
    private var accent: AppThemeColor { palette.accent }
    private var pro: ProTheme? { palette.pro }
    private var month: String { Period.spanishMonthName(for: Date()).uppercased() }
    private var previousMonth: String {
        let date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        return Period.spanishMonthName(for: date).lowercased()
    }
    /// Las cifras: con serifa en Obsidiana y Marfil, si no la tipografía elegida.
    private var numberDesign: Font.Design { pro?.numberDesign ?? fontDesign }

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
                .ringed(flash == .type, color: palette.expense)

            bars

            HStack(spacing: 10) {
                categoriesCard
                    .ringed(flash == .cats, color: palette.expense, radius: 16)
                pendingCard
                    .ringed(flash == .surface, color: palette.expense, radius: 16)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .fontDesign(fontDesign)
        .padding(14)
        .background {
            // Con tema Pro, la vista previa lleva su cielo animado.
            if let pro {
                ProThemeBackdrop(theme: pro)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(palette.background)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vista previa del resumen con la apariencia elegida")
    }

    private var accountChip: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pro?.soft ?? accent.softFill(scheme))
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "building.columns.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(pro?.accentText ?? accent.onSurface(scheme)))
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

    private var amountStyle: AnyShapeStyle {
        if let gradient = pro?.amountGradient { return AnyShapeStyle(gradient) }
        return AnyShapeStyle(palette.label)
    }

    private var amount: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GASTOS EN " + month)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(palette.secondaryLabel)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("S/ 2,612")
                    .font(.system(size: 34 * amountScale, weight: pro?.numberWeight ?? .bold, design: numberDesign))
                    .tracking(-1.2)
                    .foregroundStyle(amountStyle)
                Text(".40")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.secondaryLabel)
                Text("↑ S/ 318 vs. " + previousMonth)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(deltaText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(deltaBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .padding(.leading, 4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(2)
    }

    private var deltaText: Color {
        if let pro { return pro.accentText }
        return accent.isDuotone ? accent.secondaryOnSurface(scheme) : accent.onSurface(scheme)
    }

    private var deltaBackground: Color {
        if pro == nil, accent.isDuotone { return accent.secondarySoftFill(scheme) }
        return palette.expenseSoft
    }

    private var bars: some View {
        let peak = Self.values.max() ?? 1
        let today = Self.values.count - 1
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Self.values.indices, id: \.self) { index in
                let isToday = index == today
                VStack(spacing: 5) {
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        if isToday {
                            Text("S/ 180")
                                .font(.system(size: 10.5, weight: .semibold, design: numberDesign))
                                .foregroundStyle(palette.expenseText)
                                .fixedSize()
                        }
                        RoundedRectangle(cornerRadius: pro?.barCornerRadius ?? 5, style: .continuous)
                            .fill(isToday ? palette.expense : palette.track)
                            .frame(width: 18, height: max(3, 52 * Self.values[index] / peak))
                    }
                    .frame(height: 68)
                    Text(Self.days[index])
                        .font(.system(size: 9.5, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? palette.expenseText : palette.secondaryLabel)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
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
                .font(.system(size: 24, weight: .bold, design: numberDesign))
                .foregroundStyle(pro?.accentText ?? accent.secondaryOnSurface(scheme))
            Text("de este mes")
                .font(.system(size: 11))
                .foregroundStyle(palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
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
