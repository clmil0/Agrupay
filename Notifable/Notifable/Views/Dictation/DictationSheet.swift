import SwiftData
import SwiftUI

/// Dictado por voz (diseño «Dictado por voz», `1a` / `1c`).
///
/// Sube desde el mic de la píldora de acciones. La transcripción aparece
/// mientras se habla; cada movimiento entendido genera su tarjeta, que se
/// registra sola a los 5 s salvo que se cancele o se edite. Si falta un dato,
/// lo pregunta («¿De cuánto?») y la siguiente frase lo completa.
///
/// «Listo» cierra el movimiento que se está diciendo sin esperar al silencio;
/// sólo cierra la hoja cuando ya no queda nada por entender. El botón de
/// silenciar pausa la escucha sin terminar el dictado.
struct DictationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DictationStyle.storageKey) private var styleRaw = DictationStyle.bars.rawValue

    @StateObject private var session = DictationSession()

    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }
    private var style: DictationStyle { DictationStyle(rawValue: styleRaw) ?? .bars }

    var body: some View {
        trackedBody.trackScreen("dictation", feature: .dictation)
    }

    /// El `body` de siempre; `body` lo envuelve para contarlo como pantalla.
    @ViewBuilder private var trackedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            DictationHeader(speech: session.speech, session: session, onClose: { dismiss() })
            DictationListeningRow(speech: session.speech, style: style)
            DictationTranscript(speech: session.speech,
                                context: session.story,
                                lastPhrase: session.lastPhrase,
                                question: session.question)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(session.cards) { card in
                        DictationCardView(card: card,
                                          categories: session.categories,
                                          onCancel: { session.cancel(card.id) },
                                          onEdit: { session.edit(card.id) },
                                          onSave: { session.saveEdit(card.id, amount: $0, category: $1) })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.hidden)

            DictationFooter(speech: session.speech, session: session, onDone: {
                if session.done() { dismiss() }
            })
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .background(palette.surfaceElevated.ignoresSafeArea())
        .task { await session.start(context: modelContext) }
        .onDisappear { session.finish() }
    }
}

// MARK: - Cabecera y pie

/// Observan el dictado ellas mismas: la hoja sólo observa la sesión, y la
/// fase del micrófono (preparando, escuchando, sin permiso) vive en `speech`.
private struct DictationHeader: View {
    @ObservedObject var speech: SpeechDictation
    @ObservedObject var session: DictationSession
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }

    var body: some View { header }


    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(palette.label)
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryLabel)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(width: 32, height: 32)
                    .background(palette.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
        }
    }

    private var title: String {
        switch speech.phase {
        case .idle, .starting: return "Preparando…"
        case .listening:       return speech.isMuted ? "Silenciado" : "Escuchando…"
        case .denied:          return "Sin acceso al micrófono"
        case .unavailable:     return "Dictado no disponible"
        }
    }

    private var hint: String {
        switch speech.phase {
        case .denied:
            return "Actívalo en Ajustes para dictar tus gastos."
        case .unavailable(let message):
            return message
        default:
            if speech.isMuted { return "Activa el micrófono para seguir dictando" }
            if session.question != nil { return "Falta un dato: te lo pregunto" }
            let saved = session.savedCount
            if saved > 0 {
                return saved == 1 ? "1 movimiento registrado por voz" : "\(saved) movimientos registrados por voz"
            }
            return "Di el monto y en qué gastaste"
        }
    }

}

private struct DictationFooter: View {
    @ObservedObject var speech: SpeechDictation
    @ObservedObject var session: DictationSession
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View { footer }


    private var footer: some View {
        HStack(spacing: 10) {
            if speech.phase == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Abrir Ajustes")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.secondaryLabel)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            if speech.phase == .listening {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { speech.setMuted(!speech.isMuted) }
                } label: {
                    Image(systemName: speech.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(speech.isMuted ? Color.white : palette.label)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 46, height: 46)
                        .background(speech.isMuted ? AnyShapeStyle(palette.negative)
                                                   : AnyShapeStyle(palette.surface), in: Circle())
                        .overlay(Circle().stroke(palette.hairline, lineWidth: speech.isMuted ? 0 : 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(speech.isMuted ? "Activar micrófono" : "Silenciar micrófono")
            }

            Button {
                onDone()
            } label: {
                HStack(spacing: 8) {
                    if session.isThinking {
                        ProgressView().tint(accent.buttonText).controlSize(.small)
                    }
                    Text(session.isThinking ? "Entendiendo…" : "Listo")
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(accent.buttonText)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(accent.buttonFill.opacity(session.isThinking ? 0.6 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(session.isThinking)
        }
    }
}

// MARK: - Escucha

/// El mic y su animación. Observa el dictado por separado: el volumen cambia
/// decenas de veces por segundo y no debe redibujar la hoja entera.
private struct DictationListeningRow: View {
    @ObservedObject var speech: SpeechDictation
    let style: DictationStyle

    private var isActive: Bool { speech.phase == .listening && !speech.isMuted }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                if style == .blob {
                    DictationBlob(level: speech.level, isActive: isActive)
                }
                DictationMicButton(isActive: isActive)
            }
            .frame(width: 60, height: 60)

            if style == .bars {
                DictationBars(level: speech.level, isActive: isActive)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: 84)
        .padding(.horizontal, 4)
    }
}

/// Lo que se va entendiendo, con su cursor, y la pregunta si falta un dato.
private struct DictationTranscript: View {
    @ObservedObject var speech: SpeechDictation
    /// El relato sin monto que sigue abierto: se muestra delante de lo que se
    /// está diciendo, porque se va a interpretar junto.
    let context: String
    let lastPhrase: String
    let question: DictationSession.Question?

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let caretOn = Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                let live = !speech.partial.isEmpty || !context.isEmpty
                let text = live
                    ? [context, speech.partial].filter { !$0.isEmpty }.joined(separator: " ")
                    : lastPhrase

                (Text(text.isEmpty ? "" : text + " ")
                    .foregroundColor(live ? palette.label : palette.tertiaryLabel)
                 + Text("|")
                    .foregroundColor(speech.phase == .listening && !speech.isMuted && caretOn ? accent.color : .clear))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .lineLimit(4)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeOut(duration: 0.22), value: text)
            }

            if let question {
                HStack(spacing: 7) {
                    Image(systemName: "ear")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.warning)
                    Text(question.text)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(palette.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(minHeight: 66, alignment: .top)
        .padding(.horizontal, 4)
    }
}

// MARK: - Tarjeta

private struct DictationCardView: View {
    let card: DictationCard
    let categories: [String]
    let onCancel: () -> Void
    let onEdit: () -> Void
    let onSave: (Double, String) -> Void

    @Environment(\.colorScheme) private var scheme
    private var palette: Palette { Palette(scheme) }
    private var accent: AppThemeColor { .current }

    @State private var amountText = ""
    @State private var category = ""
    @State private var ring: CGFloat = 1

    private var movement: VoiceMovement { card.movement }
    private var isIncome: Bool { movement.kind == .ingreso }

    private var iconName: String {
        isIncome ? "banknote.fill" : CategoryStyle.icon(for: movement.category)
    }

    private var tint: Color {
        isIncome ? palette.positive : CategoryStyle.color(for: movement.category, accent: accent.color)
    }

    private var subtitle: String {
        let what = isIncome ? "Ingreso" : movement.category
        let calendar = Calendar.current
        let when = calendar.isDateInToday(movement.date) ? nil : MovementDay.label(for: movement.date)
        return ([what, movement.source ?? "Por voz", when].compactMap { $0 }).joined(separator: " · ")
    }

    private var amountLabel: String {
        let value = Money.format(movement.amount ?? 0, currency: movement.currency)
        return (isIncome ? "+" : "–") + value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MovementIcon(icon: iconName, color: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(movement.title ?? "")
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(palette.label)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryLabel)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(amountLabel)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(isIncome ? palette.positive : palette.label)
            }

            switch card.status {
            case .pending: pendingBar
            case .editing: editor
            case .saved:   closedBar(icon: "checkmark.circle.fill", label: "Registrado", tint: palette.positive)
            case .cancelled: closedBar(icon: "xmark.circle.fill", label: "Cancelado", tint: palette.secondaryLabel)
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .opacity(card.status == .cancelled ? 0.5 : 1)
    }

    // MARK: Contando

    private var pendingBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(palette.track, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: ring)
                    .stroke(accent.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)

            Text("Se registra en \(DictationSession.countdownSeconds) s")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.secondaryLabel)

            Spacer(minLength: 6)

            Button(action: onCancel) {
                Text("Cancelar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.negative)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(palette.surfaceElevated, in: Capsule())
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            Button {
                amountText = Money.cents(movement.amount ?? 0) > 0
                    ? String(format: "%.2f", movement.amount ?? 0) : ""
                category = movement.category
                onEdit()
            } label: {
                Text("Editar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.buttonText)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(accent.buttonFill, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { divider }
        .padding(.top, 12)
        .onAppear(perform: runRing)
        .onChange(of: card.countdown) { _, _ in runRing() }
    }

    private func runRing() {
        ring = 1
        withAnimation(.linear(duration: Double(DictationSession.countdownSeconds))) { ring = 0 }
    }

    // MARK: Editando

    private var editor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                field(label: "MONTO") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.label)
                }

                if !isIncome {
                    field(label: "CATEGORÍA") {
                        Menu {
                            ForEach(categories, id: \.self) { name in
                                Button(name) { category = name }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(category == Accounting.unclassified ? "Elegir" : category)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(palette.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.secondaryLabel)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("Pausado. Nada se registra hasta que guardes.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: onCancel) {
                    Text("Descartar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.negative)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Button {
                    guard let amount = Money.parse(amountText), Money.cents(amount) > 0 else { return }
                    onSave(amount, category)
                } label: {
                    Text("Guardar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent.buttonText)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(accent.buttonFill, in: Capsule())
                        .opacity(Money.cents(Money.parse(amountText) ?? 0) > 0 ? 1 : 0.4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { divider }
        .padding(.top, 12)
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(palette.secondaryLabel)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
    }

    // MARK: Cerrada

    private func closedBar(icon: String, label: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 15))
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.top, 10)
        .overlay(alignment: .top) { divider }
        .padding(.top, 10)
    }

    private var divider: some View {
        Rectangle().fill(palette.separator).frame(height: 0.5)
    }
}
