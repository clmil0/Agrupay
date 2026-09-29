import Foundation
import Testing
@testable import Notifable

/// El chat a la vista se borra tras unas horas sin escribir; el asistente
/// recuerda 24 horas.
struct AssistantChatMemoryTests {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ text: String, hoursAgo: Double, role: AssistantMessage.Role = .user) -> AssistantMessage {
        AssistantMessage(role: role, text: text, date: now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func seBorraTrasElPlazoSinEscribir() {
        let chat = [message("hola", hoursAgo: 4), message("¿cuánto gasté?", hoursAgo: 3.5)]
        let cleared = AssistantChatMemory.clearedAt(chat, clearedAt: nil, lifetimeHours: 3, now: now)
        #expect(cleared == now)
        #expect(AssistantChatMemory.visible(chat, clearedAt: cleared).isEmpty)
    }

    @Test func noSeBorraAMitadDeUnaConversacion() {
        // Empezó hace 5 h, pero el último mensaje es de hace un rato.
        let chat = [message("hola", hoursAgo: 5), message("¿y hoy?", hoursAgo: 0.2)]
        let cleared = AssistantChatMemory.clearedAt(chat, clearedAt: nil, lifetimeHours: 3, now: now)
        #expect(cleared == nil)
        #expect(AssistantChatMemory.visible(chat, clearedAt: cleared).count == 2)
    }

    /// Gratis recuerda 7 días (Configuración › Asistente); con Pro, 30.
    @Test func loBorradoSigueEnLaMemoriaUnaSemana() {
        let chat = [message("hace ocho días", hoursAgo: 8 * 24), message("anoche", hoursAgo: 10)]
        let memory = AssistantChatMemory.pruned(chat, now: now, window: 7 * 24 * 3600)
        #expect(memory.map(\.text) == ["anoche"])
        let pro = AssistantChatMemory.pruned(chat, now: now, window: 30 * 24 * 3600)
        #expect(pro.count == 2)

        let cleared = AssistantChatMemory.clearedAt(memory, clearedAt: nil, lifetimeHours: 3, now: now)
        #expect(AssistantChatMemory.visible(memory, clearedAt: cleared).isEmpty)
        #expect(AssistantChatMemory.context(memory, now: now).contains("anoche"))
    }

    @Test func loNuevoSeVeTrasLimpiar() {
        let old = message("viejo", hoursAgo: 6)
        let cleared = now.addingTimeInterval(-3600)
        let new = message("nuevo", hoursAgo: 0.1)
        let shown = AssistantChatMemory.visible([old, new], clearedAt: cleared)
        #expect(shown.map(\.text) == ["nuevo"])
    }

    @Test func plazoGuardadoInvalidoUsaElDePorDefecto() {
        let defaults = UserDefaults(suiteName: "AssistantChatMemoryTests")!
        defaults.removePersistentDomain(forName: "AssistantChatMemoryTests")
        #expect(AssistantChatMemory.lifetimeHours(defaults) == 3)
        defaults.set(7, forKey: AssistantChatMemory.lifetimeKey)
        #expect(AssistantChatMemory.lifetimeHours(defaults) == 3)
        defaults.set(15, forKey: AssistantChatMemory.lifetimeKey)
        #expect(AssistantChatMemory.lifetimeHours(defaults) == 15)
    }

    @Test func alModeloVaLoUltimoYRecortado() {
        let long = String(repeating: "a", count: 500)
        let chat = (0..<15).map { message("m\($0) " + long, hoursAgo: Double(15 - $0)) }
        let lines = AssistantChatMemory.context(chat, now: now).split(separator: "\n")
        #expect(lines.count == AssistantChatMemory.contextLimit)
        #expect(lines.first?.contains("m5 ") == true)
        #expect(lines.allSatisfy { $0.count < AssistantChatMemory.contextCharacters + 40 })
    }
}
