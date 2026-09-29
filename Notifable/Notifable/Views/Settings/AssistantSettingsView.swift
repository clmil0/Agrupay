import SwiftUI

/// Configuración › Asistente (`4i`): qué recuerda y qué propone.
///
/// La memoria es lo que se habló con ✦: 7 días en Gratis, 30 con Pro. Vive
/// en el teléfono y sólo viaja al modelo de Apple, en el propio iPhone.
struct AssistantSettingsView: View {

    @Environment(\.colorScheme) private var scheme
    @AppStorage(ProStore.enabledKey) private var isPro = false
    @AppStorage(AssistantSettings.briefDotKey) private var briefDot = true
    @AppStorage(AssistantSettings.suggestionsKey) private var suggestions = true
    @AppStorage(AssistantSettings.unusualKey) private var unusualAlerts = true

    @State private var memory: [AssistantMessage] = []
    @State private var confirmErase = false
    @State private var paywall: ProStore.Feature?

    private var palette: Palette { Palette(scheme) }
    private static let violet = Color(hex: 0xBF5AF2)

    var body: some View {
        SettingsPage(title: "Asistente") {
            memoryCard

            SettingsGroup(title: "En el resumen") {
                SettingsToggle(title: "Resumen del día", subtitle: "Un punto en ✦ cuando hay algo nuevo",
                               isOn: $briefDot)
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Sugerencias de categoría", subtitle: "Propone reglas para comercios repetidos",
                               isOn: $suggestions)
                SettingsDivider(inset: 14)
                SettingsToggle(title: "Avisos de gastos raros", subtitle: "Montos fuera de lo habitual",
                               isOn: $unusualAlerts)
            }

            SettingsGroup(footer: "La memoria vive en tu teléfono y se usa sólo para responderte.") {
                SettingsLink(title: "Ver lo que recuerda", value: memory.isEmpty ? "Nada" : "\(memory.count)") {
                    AssistantMemoryList(memory: memory)
                }
                SettingsDivider(inset: 14)
                SettingsAction(title: "Borrar memoria", destructive: true) { confirmErase = true }
            }
        }
        .onAppear { memory = AssistantChatMemory.stored() }
        .onChange(of: isPro) { _, _ in memory = AssistantChatMemory.stored() }
        .onChange(of: briefDot) { _, on in
            if !on { AssistantDot.shared.hasNews = false }
        }
        .alert("¿Borrar la memoria?", isPresented: $confirmErase) {
            Button("Cancelar", role: .cancel) {}
            Button("Borrar", role: .destructive) {
                AssistantChatMemory.erase()
                memory = []
            }
        } message: {
            Text("El asistente olvida todo lo que han hablado. Tus gastos no se tocan.")
        }
        .proPaywall($paywall)
    }

    private var memoryCard: some View {
        let window = ProStore.assistantMemoryDays
        let used = AssistantChatMemory.daysUsed(memory)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Self.violet)
                    .frame(width: 40, height: 40)
                    .background(Self.violet.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(isPro ? "Memoria extendida" : "Memoria básica")
                        .font(.headline)
                        .foregroundStyle(palette.label)
                    Text("Recuerda tus últimos \(window) días de conversación")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryLabel)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule().fill(Self.violet)
                        .frame(width: proxy.size.width * CGFloat(used) / CGFloat(max(window, 1)))
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(used) de \(window) días usados")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryLabel)
                Spacer()
                if !isPro {
                    Button("Más memoria con Pro") { paywall = .ai }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.violet)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }
}

/// Lo que el asistente recuerda, del más nuevo al más viejo.
private struct AssistantMemoryList: View {
    let memory: [AssistantMessage]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        List {
            if memory.isEmpty {
                Text("Todavía no han hablado. Lo que le preguntes a ✦ aparecerá aquí mientras lo recuerde.")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryLabel)
            } else {
                ForEach(memory.reversed()) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == .user ? "Tú" : "Asistente")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(message.role == .user ? palette.label : AppThemeColor.current.onSurface(scheme))
                        Text(message.text)
                            .font(.subheadline)
                            .foregroundStyle(palette.label)
                        Text(message.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()
                            .locale(Locale(identifier: "es_PE"))))
                            .font(.caption2)
                            .foregroundStyle(palette.tertiaryLabel)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Lo que recuerda")
        .navigationBarTitleDisplayMode(.inline)
    }
}
