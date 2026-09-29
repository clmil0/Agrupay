import Foundation
import UIKit

/// Tu celular, verificado por WhatsApp (`agrupay_phone_v13_whatsapp_verify.sql`
/// + la Edge Function `whatsapp-verify`).
///
/// Verificación «al revés»: el servidor da un código, la app abre WhatsApp con
/// ese código ya escrito hacia el número de AgruPay y el usuario sólo toca
/// Enviar. Meta le dice al servidor desde qué número llegó, y ése queda
/// verificado. No se manda ningún SMS: recibir mensajes no se cobra.
@MainActor
@Observable
final class PhoneVerification {

    static let shared = PhoneVerification()

    private let auth = SupabaseAuthManager.shared
    private var baseURL: String { auth.baseURL }

    /// E.164 («+51987654321»), si ya está verificado.
    private(set) var phone: String?
    private(set) var verifiedAt: Date?
    private(set) var pending: Pending?
    private(set) var lastErrorMessage: String?
    private(set) var isStarting = false

    struct Pending: Equatable {
        let code: String
        let whatsappNumber: String
        let expiresAt: Date
        /// La verificación que había al pedir el código.
        var previousVerifiedAt: Date? = nil

        var link: URL? {
            var components = URLComponents(string: "https://wa.me/" + whatsappNumber)
            components?.queryItems = [URLQueryItem(name: "text", value: code)]
            return components?.url
        }
    }

    private var isListening = false
    private var polling: Task<Void, Never>?

    /// «+51 987 654 321».
    var formattedPhone: String? {
        guard let phone else { return nil }
        let digits = phone.filter(\.isNumber)
        guard digits.hasPrefix("51"), digits.count == 11 else { return phone }
        let local = Array(digits.dropFirst(2))
        return "+51 " + String(local[0..<3]) + " " + String(local[3..<6]) + " " + String(local[6..<9])
    }

    /// Los cuatro últimos: lo que muestran los correos de Plin y Yape.
    var lastDigits: String? { phone.map { String($0.filter(\.isNumber).suffix(4)) } }

    // MARK: - Estado

    func refresh() async {
        #if DEBUG
        if QAMode.isOn { return }
        #endif
        guard auth.isReady,
              let data = await rpc("my_verified_phone", body: [:]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let row = rows.first
        phone = row?["phone"] as? String
        verifiedAt = (row?["verified_at"] as? String).flatMap(Self.timestamp)
        // Llegó el mensaje: la fecha de verificación cambió respecto a la de
        // antes de pedir el código (el número puede ser el mismo de siempre).
        if let pending, let verifiedAt, verifiedAt != pending.previousVerifiedAt {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            stopWaiting()
        }
    }

    // MARK: - Verificar

    /// Pide un código y abre WhatsApp con él escrito.
    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastErrorMessage = nil

        #if DEBUG
        if QAMode.isOn {
            // Sin servidor: el «mensaje» llega a los tres segundos.
            pending = Pending(code: "AGRU-QA7K2P", whatsappNumber: "51900000000",
                              expiresAt: Date().addingTimeInterval(900))
            polling = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.phone = "+51987654209"
                self?.verifiedAt = Date()
                self?.pending = nil
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            return
        }
        #endif

        guard let data = await rpc("start_phone_verification", body: [:]),
              let row = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
              let code = row["code"] as? String,
              let number = row["whatsapp_number"] as? String else { return }

        pending = Pending(code: code, whatsappNumber: number.filter(\.isNumber),
                          expiresAt: (row["expires_at"] as? String).flatMap(Self.timestamp)
                              ?? Date().addingTimeInterval(900),
                          previousVerifiedAt: verifiedAt)
        openWhatsApp()
        waitForMessage()
    }

    func openWhatsApp() {
        guard let link = pending?.link else { return }
        UIApplication.shared.open(link)
    }

    func cancel() { stopWaiting() }

    func forget() async {
        stopWaiting()
        phone = nil
        verifiedAt = nil
        #if DEBUG
        if QAMode.isOn { return }
        #endif
        _ = await rpc("forget_my_phone", body: [:])
    }

    /// Realtime avisa en cuanto la Edge Function guarda el número; el sondeo
    /// cubre el caso en que el socket todavía no está conectado.
    private func waitForMessage() {
        if !isListening {
            isListening = true
            _ = SupabaseRealtimeClient.shared.subscribe(table: "verified_phones") { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled, let pending = self.pending else { return }
                if pending.expiresAt < Date() {
                    self.pending = nil
                    self.lastErrorMessage = "El código venció. Pide uno nuevo."
                    return
                }
                await self.refresh()
            }
        }
    }

    private func stopWaiting() {
        polling?.cancel()
        polling = nil
        pending = nil
    }

    // MARK: - Red

    private func rpc(_ name: String, body: [String: Any]) async -> Data? {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/\(name)"),
              var request = await auth.authorizedRequest(url: url, method: "POST") else {
            lastErrorMessage = "Sin sesión: entra con tu cuenta de Google en Amigos"
            return nil
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            lastErrorMessage = "Sin conexión"
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            struct ServerError: Decodable { let message: String? }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.message ?? raw
            lastErrorMessage = message.contains("Could not find the function")
                ? "Falta correr agrupay_phone_v13_whatsapp_verify.sql en Supabase."
                : message
            Diagnostics.shared.log("Celular: \(name) devolvió \(http.statusCode) · \(raw.prefix(300))")
            return nil
        }
        return data
    }

    private static func timestamp(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
