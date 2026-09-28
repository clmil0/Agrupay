import SwiftUI

/// El ícono de un movimiento en el lenguaje nuevo: cuadrado redondeado de
/// 44 pt (radio 13) con el color de la categoría al 18 % y el símbolo al 100 %.
///
/// Sustituye al círculo de 48 pt de `DashboardView`. El cuadrado redondeado
/// alinea con el radio de las tarjetas (22) y con el de los cuadros de
/// categoría del resto del rediseño; el círculo se queda para los avatares de
/// personas, que es donde sí significa algo distinto.
struct MovementIcon: View {
    let icon: String
    let color: Color
    var size: CGFloat = 44

    @Environment(\.colorScheme) private var scheme

    /// Los íconos de billetera y banco son imágenes de marca: no se tiñen.
    private var isAsset: Bool {
        Institution.allCases.contains { $0.logoAsset == icon }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.295, style: .continuous)
                .fill(color.opacity(scheme == .dark ? 0.22 : 0.18))

            if isAsset {
                Image(icon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size * 0.55, height: size * 0.55)
                    .clipShape(Circle())
            } else {
                Image(systemName: icon)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// El logo de Yape, Plin o BBVA en miniatura, con un aro del color de la
/// tarjeta para despegarlo del ícono de la categoría.
struct SourceBadge: View {
    let asset: String
    var size: CGFloat = 17

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(asset)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Palette(scheme).surface, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Ícono y color de un gasto. Extraído de `DashboardView` para que la fila
/// nueva y la antigua no se separen mientras conviven.
enum MovementStyle {

    /// Ya clasificado, el gasto lleva el ícono de su categoría aunque haya
    /// llegado por Yape o Plin: el origen sigue en el subtítulo, y el logo de
    /// la billetera no dice en qué se fue el dinero.
    private static func isClassified(_ expense: Expense) -> Bool {
        expense.category != Accounting.unclassified && !expense.isTransfer
    }

    static func icon(for expense: Expense) -> String {
        if expense.isReversal || expense.isVoided { return "arrow.uturn.backward" }
        if isClassified(expense) { return CategoryStyle.icon(for: expense.category) }
        if expense.merchant.hasPrefix("PLIN - ") { return "plin_icon" }
        if expense.merchant.hasPrefix("YAPE - ") { return "yape_icon" }
        if expense.merchant.hasPrefix("BBVA - ") { return "bbva_icon" }
        if expense.merchant.lowercased().contains("apple") { return "applelogo" }
        return CategoryStyle.icon(for: expense.category)
    }

    /// El logo de la billetera o el banco, en pequeño sobre la esquina del
    /// ícono, cuando éste ya es el de la categoría: así se sigue viendo por
    /// dónde salió el dinero. Sin clasificar no hace falta: el ícono entero
    /// ya es el logo.
    static func sourceBadge(for expense: Expense) -> String? {
        guard !expense.isReversal, !expense.isVoided,
              let logo = institution(for: expense)?.logoAsset,
              icon(for: expense) != logo else { return nil }
        return logo
    }

    /// El banco o la billetera por la que salió el dinero: el prefijo que
    /// ponen los lectores de Yape/Plin/BBVA o, si no, el banco del correo
    /// (una compra con tarjeta BCP, Interbank…).
    static func institution(for expense: Expense) -> Institution? {
        if expense.merchant.hasPrefix("PLIN - ") { return .plin }
        if expense.merchant.hasPrefix("YAPE - ") { return .yape }
        if expense.merchant.hasPrefix("BBVA - ") { return .bbva }
        return expense.sourceBank.flatMap { Institution(name: $0) }
    }

    static func color(for expense: Expense, accent: Color, scheme: ColorScheme) -> Color {
        if expense.isReversal || expense.isVoided { return Palette(scheme).warning }
        if isClassified(expense) { return CategoryStyle.color(for: expense.category, accent: accent) }
        if expense.merchant.hasPrefix("PLIN - ") { return Color(red: 0, green: 0.7, blue: 0.9) }
        if expense.merchant.hasPrefix("YAPE - ") { return Color(red: 0.5, green: 0, blue: 0.5) }
        if expense.merchant.hasPrefix("BBVA - ") { return Color(red: 0.0, green: 0.27, blue: 0.51) }
        if expense.merchant.lowercased().contains("apple") { return scheme == .dark ? .white : .black }
        return CategoryStyle.color(for: expense.category, accent: accent)
    }

    /// El origen del movimiento para el subtítulo: la billetera con la que se
    /// pagó o la tarjeta. No se inventa "Efectivo" cuando no se sabe: si el
    /// correo no dijo de dónde salió el dinero, el subtítulo es sólo la
    /// categoría.
    static func source(for expense: Expense) -> String? {
        if expense.merchant.hasPrefix("PLIN - ") { return "Plin" }
        if expense.merchant.hasPrefix("YAPE - ") { return "Yape" }
        if expense.merchant.hasPrefix("BBVA - ") { return "BBVA" }
        if let card = expense.cardLastDigits, !card.isEmpty { return "•••• " + card }
        return nil
    }

    /// El subtítulo de un traslado donde se lo vea suelto (Hoy, una búsqueda):
    /// explica por qué no suma.
    static let transferNote = "Traslado entre tus cuentas"
}

/// Una fila de la lista de Hoy: ícono, comercio, `Categoría · Origen`, monto.
///
/// Sin categoría, el subtítulo se cambia por un chip de «Asignar categoría»:
/// clasificar es la acción que la app más necesita del usuario, y esconderla
/// tras una pulsación larga es lo que llenó la bandeja de Pendientes.
struct MovementRow: View {
    let expense: Expense
    /// La hora junto al subtítulo («Supermercado  16:49»): en Movimientos,
    /// donde la cabecera ya dice el día. Con hora, el subtítulo no lleva el
    /// origen: categoría y hora, nada más.
    var showsTime = false
    var onTap: () -> Void = {}
    var onAssignCategory: () -> Void = {}
    /// En modo selección (Pendientes «Por día», Movimientos › Seleccionar):
    /// `true`/`false` dibuja la casilla a la izquierda y el toque elige. `nil`
    /// fuera de ese modo. Es la misma fila en los dos sitios a propósito: un
    /// movimiento se reconoce por su fila, no por la pantalla en la que está.
    var selection: Bool? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @State private var confirmsDelete = false
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    /// Un traslado o una anulación no se clasifican: no son gasto.
    private var isUnclassified: Bool {
        expense.category == Accounting.unclassified && expense.countsAsSpending
    }

    /// Un gasto marcado «por cobrar», o con abonos ya recibidos. La fila no
    /// cambia de color por eso —eso volvía la lista un semáforo—, sólo añade
    /// una línea que dice cuánto falta.
    private var debtNote: String? {
        let paid = Accounting.paid(of: expense)
        let outstanding = Accounting.outstanding(of: expense)
        guard expense.isDebt || expense.debtSettled || Money.cents(paid) > 0 else { return nil }
        if expense.debtSettled && !expense.isDebt { return "Deuda saldada" }
        if Money.isZero(outstanding) { return "Cobrado" }
        return "Por cobrar · falta " + Money.format(outstanding, currency: expense.currency)
    }

    /// Un gasto recién borrado —el aviso de anulación al elegir la compra—
    /// puede volver a dibujarse un fotograma antes de que `@Query` lo saque de
    /// la lista. Leer cualquier propiedad suya ahí es un error fatal de
    /// SwiftData.
    var body: some View {
        if expense.isDeleted || expense.modelContext == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let selection {
                SelectionCheck(state: selection ? .on : .off, size: 22)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            MovementIcon(icon: MovementStyle.icon(for: expense),
                         color: MovementStyle.color(for: expense, accent: accent.color, scheme: scheme),
                         size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = MovementStyle.sourceBadge(for: expense) {
                        SourceBadge(asset: badge)
                            .offset(x: 4, y: 4)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(expense.isReversal ? "Anulación de compra" : Accounting.displayName(expense.merchant))
                        .font(.system(size: 15.5, weight: .semibold))
                        .strikethrough(expense.isVoided)
                        .foregroundStyle(expense.isVoided ? palette.secondaryLabel : palette.label)
                        .lineLimit(1)

                    if expense.isSubscription {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent.color)
                    }
                }

                if isUnclassified && selection != nil {
                    // Eligiendo, el chip «Asignar categoría» sería un botón
                    // dentro de otro: se asigna desde la barra.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(MovementStyle.source(for: expense) ?? Accounting.unclassified)
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.secondaryLabel)
                            .lineLimit(1)
                        if showsTime { TimeLabel(date: expense.date) }
                    }
                } else if isUnclassified && showsTime {
                    // Movimientos: el chip y la hora, como el resto de filas.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        assignRow(showsSource: false)
                        TimeLabel(date: expense.date)
                    }
                } else if isUnclassified {
                    // `ViewThatFits`: con un comercio de nombre corto entran
                    // el chip y el origen; con uno largo, el origen se retira
                    // entero en vez de quedarse en unos puntos suspensivos que
                    // no dicen nada. El chip nunca se encoge: es la acción.
                    ViewThatFits(in: .horizontal) {
                        assignRow(showsSource: true)
                        assignRow(showsSource: false)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        subtitleLine
                        if showsTime { TimeLabel(date: expense.date) }
                    }
                }

                if let debtNote {
                    Text(debtNote)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(expense.debtSettled && !expense.isDebt ? palette.positive : palette.warning)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(amountText)
                .font(.system(size: 15.5, weight: .semibold))
                .monospacedDigit()
                .strikethrough(expense.isVoided)
                .foregroundStyle(expense.countsAsSpending ? palette.label : palette.secondaryLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(accent.color.opacity(selection == true ? 0.07 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                // El menú se cierra con su propia animación y con la fila
                // levantada en un overlay aparte: mutar aquí hace crecer la
                // fila real por debajo de ese overlay y lo que se ve al
                // aterrizar es un salto ya consumado.
                let expense = expense
                let context = modelContext
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    expense.toggleDebt(in: context)
                }
            } label: {
                Label(expense.isDebt ? "Ya no es por cobrar" : "Por cobrar",
                      systemImage: "exclamationmark.circle")
            }

            Button {
                onAssignCategory()
            } label: {
                Label("Categorizar", systemImage: "tag")
            }

            // Se confirma aparte: el menú se abre con una pulsación larga y
            // un toque de más no debería bastar para perder un movimiento.
            // Una parte de un pago dividido no se borra suelta —las demás
            // dejarían de cuadrar—: se deshace la división desde su ficha.
            if expense.splitOf == nil {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("¿Eliminar movimiento?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                let expense = expense
                let context = modelContext
                withAnimation(.easeInOut(duration: 0.25)) {
                    expense.deleteRecordingRecovery(in: context)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrará de tus cuentas. Esto no se puede deshacer.")
        }
    }

    /// La fila de «sin categoría», con o sin el origen del movimiento.
    private func assignRow(showsSource: Bool) -> some View {
        HStack(spacing: 5) {
            Button(action: onAssignCategory) {
                Text("Asignar categoría")
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                    .foregroundStyle(accent.onSurface(scheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(accent.color.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)

            if showsSource, let source = MovementStyle.source(for: expense) {
                Text(source)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
                    .fixedSize()
            }
        }
    }

    /// «Salud · ●madre +2» cuando el movimiento lleva etiqueta; si no, el
    /// «Categoría · Origen» de siempre.
    ///
    /// La etiqueta **desplaza al origen**, no se añade: en una línea de 12.5 pt
    /// no caben las dos cosas, y saber que el gasto es de tu madre dice más que
    /// saber que llegó por Yape —que además ya se ve en el ícono—. El punto de
    /// color es lo único que la distingue de la categoría, que va en gris y
    /// sin punto.
    ///
    /// Si no cabe, la categoría se abrevia («Entretenimiento» → «Entr.») antes
    /// que cortar la línea con puntos suspensivos o partirla en dos.
    private var subtitleLine: some View {
        ViewThatFits(in: .horizontal) {
            subtitleLine(abbreviated: false)
            subtitleLine(abbreviated: true)
        }
    }

    private var categoryName: String { expense.category }

    @ViewBuilder
    private func subtitleLine(abbreviated: Bool) -> some View {
        let category = abbreviated ? CategoryStyle.shortName(for: categoryName) : categoryName
        if let tag = expense.tags.first, expense.countsAsSpending {
            HStack(spacing: 5) {
                Text(category + " ·")
                    .fixedSize()
                    .foregroundStyle(palette.secondaryLabel)

                Circle()
                    .fill(TagCatalog.shared.color(for: tag))
                    .frame(width: 7, height: 7)

                Text(tag)
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.label)
                    .lineLimit(1)
                    .fixedSize(horizontal: !abbreviated, vertical: false)

                if expense.tags.count > 1 {
                    Text("+\(expense.tags.count - 1)")
                        .foregroundStyle(palette.secondaryLabel)
                        .fixedSize()
                }
            }
            .font(.system(size: 12.5))
        } else {
            // Sin cortar en la versión completa: si no entra, `ViewThatFits`
            // pasa a la abreviada, y ésa sí se corta si hace falta.
            Text(subtitle(category: category))
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)
                .lineLimit(1)
                .fixedSize(horizontal: !abbreviated, vertical: false)
        }
    }

    private func subtitle(category: String) -> String {
        if expense.isReversal {
            let card = expense.cardLastDigits.map { " · •••• " + $0 } ?? ""
            return "Toca para elegir cuál" + card
        }
        if expense.isVoided { return "Anulada por el banco" }
        if expense.isTransfer { return MovementStyle.transferNote }
        // En Movimientos, «Categoría  16:49»: el origen ya lo dice el ícono.
        if !showsTime, let source = MovementStyle.source(for: expense) {
            return category + " · " + source
        }
        return category
    }

    /// El guion es un menos tipográfico (U+2013), no un guion de teclado: a
    /// 16.5 pt semibold el guion corto se lee como parte del número.
    private var amountText: String {
        let paid = Accounting.paid(of: expense)
        let outstanding = Accounting.outstanding(of: expense)
        let displayed = (expense.isDebt || Money.cents(paid) > 0) ? outstanding : expense.amount
        // Un traslado no resta: el dinero sigue siendo tuyo. Un aviso de
        // anulación tampoco: no es un gasto.
        return (expense.isTransfer || expense.isReversal ? "" : "–") + Money.format(displayed, currency: expense.currency)
    }
}

/// Fila de ingreso, con el mismo esqueleto que la de gasto.
struct IncomeRow: View {
    let income: Income
    var showsTime = false
    var onTap: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @State private var showsDestino = false
    @State private var confirmsDelete = false
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        let (color, icon) = IncomeStyle.iconAndColor(for: income, accent: accent.incomeFillColor)

        HStack(spacing: 12) {
            MovementIcon(icon: icon, color: color, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(income.title ?? income.source)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(palette.label)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(income.isTransfer ? MovementStyle.transferNote : income.source)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                    if showsTime { TimeLabel(date: income.date) }
                }
            }

            Spacer(minLength: 8)

            // Un traslado no es ingreso: sin «+» y sin el color de ingreso.
            Text((income.isTransfer ? "" : "+") + Money.format(income.amount, currency: income.currency))
                .font(.system(size: 15.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(income.isTransfer ? palette.secondaryLabel : accent.incomeColor(scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                showsDestino = true
            } label: {
                Label("Asignar a deuda", systemImage: "scope")
            }

            Button(role: .destructive) {
                confirmsDelete = true
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
        // Desde la hoja se puede ir a la deuda (`ActivityFocus`): se cierra
        // para que se abra su detalle.
        .onReceive(NotificationCenter.default.publisher(for: ActivityFocus.notification)) { _ in
            showsDestino = false
        }
        // La misma hoja que «¿A dónde va?» en el detalle del ingreso.
        .sheet(isPresented: $showsDestino) {
            IncomeDestinoSheet(income: income)
        }
        .confirmationDialog("¿Eliminar este ingreso?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                let income = income
                let context = modelContext
                withAnimation(.easeInOut(duration: 0.25)) {
                    income.deleteRestoringDebt(in: context)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(income.debtReference != nil
                 ? "Se borrará de tus cuentas y lo que devuelve volverá a figurar como pendiente. Esto no se puede deshacer."
                 : "Se borrará de tus cuentas. Esto no se puede deshacer.")
        }
    }
}

/// La tarjeta que agrupa las filas de un día: radio 20, superficie con
/// hairline y separadores internos sangrados 66 pt —el ancho del ícono más su
/// margen—, para que la línea arranque bajo el texto y no bajo el ícono.
struct MovementCard<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            // El resaltado de una fila nueva no se sale por las esquinas.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.5)
            )
    }
}

struct MovementSeparator: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Palette(scheme).separator)
            .frame(height: 0.5)
            .padding(.leading, 66)
    }
}

/// Cómo se nombra un día en las cabeceras de las listas.
enum MovementDay {
    /// «Hoy», «Ayer», y para el resto el día de la semana con su fecha.
    static func label(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }

        let formatter = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
            ? longThisYear : longOtherYear
        return formatter.string(from: day).capitalizedFirst
    }

    /// «Hoy», «Ayer», «21 de setiembre»: la cabecera corta de Movimientos
    /// (`1b`), donde la hora ya va en cada fila.
    static func shortLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }

        let formatter = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
            ? shortThisYear : shortOtherYear
        return formatter.string(from: day)
    }

    // Creados una vez: armar un `DateFormatter` es caro, y en Movimientos se
    // pedía uno por cabecera de día justo mientras la lista se desliza y
    // monta filas nuevas. Nunca se modifican después, así que compartirlos
    // es seguro.
    private static let longThisYear = formatter("EEEE d 'de' MMMM")
    private static let longOtherYear = formatter("EEEE d 'de' MMMM, yyyy")
    private static let shortThisYear = formatter("d 'de' MMMM")
    private static let shortOtherYear = formatter("d 'de' MMMM, yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = format
        return formatter
    }
}

/// «16:49», en gris y con cifras tabulares, al lado del subtítulo de una fila.
private struct TimeLabel: View {
    let date: Date
    @Environment(\.colorScheme) private var scheme

    /// Armado una vez y no por fila: la lista monta filas mientras se desliza.
    private static let style = Date.FormatStyle.dateTime
        .hour(.twoDigits(amPM: .omitted)).minute()
        .locale(Locale(identifier: "es_ES"))

    var body: some View {
        Text(date.formatted(Self.style))
            .font(.system(size: 12.5))
            .monospacedDigit()
            .foregroundStyle(Palette(scheme).secondaryLabel)
            .fixedSize()
    }
}
