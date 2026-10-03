import Foundation
import SwiftData
import UIKit

// MARK: - Ayudas para la bitácora de la lectura

extension GmailSyncService {

    /// «2026-09-22 21:43» o «—».
    static func logDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f.string(from: date)
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// El cuerpo de una respuesta, recortado y en una línea. Nunca lleva
    /// tokens: son respuestas de Gmail, no de la autenticación.
    static func bodyExcerpt(_ data: Data?, limit: Int = 600) -> String {
        guard let data, !data.isEmpty else { return "(sin cuerpo)" }
        let text = String(data: data, encoding: .utf8) ?? "(\(data.count) bytes no UTF-8)"
        return excerpt(text, limit)
    }

    static func excerpt(_ text: String, _ limit: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Un error de la API de Gmail con un mensaje que se puede enseñar tal
    /// cual en Gmail y bancos.
    static let missingScopeKey = "missingGmailScope"

    /// El 403 de `apiError` por falta de `gmail.readonly`: renovar el token
    /// no lo arregla, así que no vale la pena reintentar.
    static func isMissingScope(_ error: Error) -> Bool {
        (error as NSError).userInfo[missingScopeKey] as? Bool == true
    }

    static func apiError(status: Int, data: Data?) -> NSError {
        var message = ""
        var reason = ""
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            message = error["message"] as? String ?? ""
            reason = ((error["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? ""
        }
        let lower = (message + " " + reason).lowercased()
        let text: String
        switch status {
        case 403 where lower.contains("insufficient") || lower.contains("scope"):
            return NSError(domain: "GmailAPI", code: status,
                           userInfo: [NSLocalizedDescriptionKey: GmailAuthService.missingScopeMessage,
                                      missingScopeKey: true])
        case 403 where lower.contains("has not been used") || lower.contains("disabled") || lower.contains("accessnotconfigured"):
            text = "La API de Gmail no está habilitada para esta app (error del proyecto en Google)."
        case 429:
            text = "Gmail limitó las consultas por un rato. Espera unos minutos y vuelve a intentarlo."
        case 500...599:
            text = "Gmail tuvo un problema (HTTP \(status)). Vuelve a intentarlo en un momento."
        default:
            text = "Gmail respondió con un error (HTTP \(status))" + (message.isEmpty ? "." : ": \(message)")
        }
        return NSError(domain: "GmailAPI", code: status, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func header(_ name: String, in json: [String: Any]) -> String? {
        let headers = (json["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        return headers.first { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame }?["value"] as? String
    }

    /// «multipart/alternative[text/plain 1234, text/html 56789]».
    static func mimeSummary(_ json: [String: Any]) -> String {
        func describe(_ part: [String: Any]) -> String {
            let type = part["mimeType"] as? String ?? "?"
            if let parts = part["parts"] as? [[String: Any]], !parts.isEmpty {
                return type + "[" + parts.map(describe).joined(separator: ", ") + "]"
            }
            let size = (part["body"] as? [String: Any])?["size"] as? Int ?? 0
            return "\(type) \(size)"
        }
        guard let payload = json["payload"] as? [String: Any] else { return "sin payload" }
        return describe(payload)
    }
}

// MARK: - Informe

/// Un informe de texto con todo lo que hace falta para entender por qué la
/// lectura de Gmail no funciona en un teléfono al que no se tiene acceso:
/// estado guardado, pruebas en vivo contra Google y Gmail, cómo lee la app
/// los últimos correos de bancos y la bitácora de las últimas aperturas.
///
/// **Nunca incluye tokens.** Sí incluye remitentes, asuntos y un extracto de
/// los correos que ningún lector reconoció (montos y comercios): es lo que
/// permite arreglar un lector sin tener el correo delante.
@MainActor
enum GmailDiagnosticReport {

    static func build(context: ModelContext) async -> URL {
        var out: [String] = []
        func line(_ text: String = "") { out.append(text) }
        func section(_ title: String) { line(); line("=== \(title) ===") }

        let sync = GmailSyncService.shared
        let auth = GmailAuthService.shared
        let defaults = UserDefaults.standard

        line("INFORME DE LECTURA DE GMAIL")
        line("Generado: \(GmailSyncService.logDate(Date()))")

        // 1. Teléfono y app
        section("App y teléfono")
        let info = Bundle.main.infoDictionary
        line("Versión: \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        line("iOS: \(UIDevice.current.systemVersion) · modelo: \(deviceModel())")
        line("Zona horaria: \(TimeZone.current.identifier) · idioma: \(Locale.current.identifier)")
        line("Actualización en segundo plano: \(describe(UIApplication.shared.backgroundRefreshStatus)) · ahorro de energía: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "sí" : "no")")

        // 2. Cuenta
        section("Cuenta de Google")
        line("Conectada (isAuthenticated): \(auth.isAuthenticated ? "sí" : "no")")
        line("Permiso retirado por Google (accessRevoked): \(auth.accessRevoked ? "SÍ" : "no")")
        line("Token de acceso guardado: \(auth.getAccessToken() != nil ? "sí" : "NO") · refresh token guardado: \(auth.hasRefreshToken ? "sí" : "NO")")
        line("Identidad (id_token alguna vez): \(auth.hasIdentityToken ? "sí" : "no") · cuenta: \(mask(auth.accountEmail))")
        line("Permisos concedidos (guardados): \(GmailAuthService.grantedScope ?? "desconocido (se conectó antes de guardarlos)")")

        // 3. Estado de la lectura
        section("Estado de la lectura")
        let processed = defaults.stringArray(forKey: "processedEmailIDs") ?? []
        let recovery = defaults.stringArray(forKey: "pendingRecoveryIDs") ?? []
        line("Última lectura (lastSyncDate): \(GmailSyncService.logDate(sync.lastSyncDate))")
        line("Lectura en curso (isRunning): \(sync.isRunning ? "SÍ, desde \(GmailSyncService.logDate(sync.runStartedAt))" : "no") · isSyncing: \(sync.isSyncing)")
        line("Último error: \(sync.lastSyncError ?? "ninguno")")
        line("Último resumen: \(sync.lastRunSummary ?? "ninguno")")
        line("Correos ya procesados: \(processed.count) · borrados a propósito (no se releen): \(recovery.count)")
        line("Periodo elegido en Correo y bancos: \(defaults.integer(forKey: "readPeriodMonths")) meses · onboarding visto: \(defaults.bool(forKey: "hasSeenOnboarding"))")
        line("Bancos marcados: " + BankSource.all.map { "\($0.name) \($0.isEnabled ? "✓" : "✗")" }.joined(separator: ", "))
        line("Lectores: " + sync.parsers.map { "\($0.bankName) (\($0.senderEmails.joined(separator: ", ")))" }.joined(separator: " · "))

        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let incomes = (try? context.fetch(FetchDescriptor<Income>())) ?? []
        let fromEmail = expenses.filter { $0.emailID != nil }
        let incomeFromEmail = incomes.filter { $0.emailID != nil }
        line("Gastos: \(expenses.count) (\(fromEmail.count) desde correo) · ingresos: \(incomes.count) (\(incomeFromEmail.count) desde correo)")
        line("Último gasto desde correo: \(GmailSyncService.logDate(fromEmail.map(\.date).max()))")
        let byBank = Dictionary(grouping: fromEmail, by: { $0.sourceBank ?? "?" }).mapValues(\.count)
        line("Por banco: " + (byBank.isEmpty ? "—" : byBank.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        let knownIDs = Set(fromEmail.compactMap(\.emailID) + fromEmail.compactMap(\.relatedEmailID) + incomeFromEmail.compactMap(\.emailID))

        // 4. Pruebas en vivo
        section("Prueba: permiso actual")
        var token = auth.getAccessToken()
        var tokenOK = false
        if let current = token {
            let check = await tokenInfo(current)
            line("Token guardado → \(check.summary)")
            tokenOK = check.valid
        } else {
            line("Token guardado → no hay")
        }

        section("Prueba: renovar el permiso")
        if auth.hasRefreshToken {
            let renewed: String? = await withCheckedContinuation { continuation in
                auth.refreshAccessToken { continuation.resume(returning: $0) }
            }
            if let renewed {
                token = renewed
                let check = await tokenInfo(renewed)
                line("Renovación → ok · token nuevo → \(check.summary)")
                tokenOK = check.valid
            } else {
                line("Renovación → ✗ FALLÓ (el motivo exacto está en la bitácora de abajo, «Gmail auth: renovación…»)")
                line("Permiso retirado tras la prueba: \(auth.accessRevoked ? "SÍ (invalid_grant)" : "no")")
            }
        } else {
            line("Sin refresh token: no se puede renovar. Hay que desvincular y volver a conectar.")
        }

        if let token {
            section("Prueba: Gmail")
            let profile = await get("\(sync.baseURL)/profile", token: token)
            if profile.status == 200 {
                line("Perfil → HTTP 200 · cuenta \(mask(profile.json?["emailAddress"] as? String)) · \(profile.json?["messagesTotal"] ?? "?") correos en total")
            } else {
                line("Perfil → ✗ HTTP \(profile.status): \(GmailSyncService.bodyExcerpt(profile.data))")
            }
            if !tokenOK { line("(el token no pasó la verificación; lo de abajo puede fallar por eso)") }

            let now = Date()
            let monthAgo = Int(now.addingTimeInterval(-30 * 86400).timeIntervalSince1970)
            line()
            line("Correos por remitente (últimos 30 días / estimado total):")
            for sender in sync.parsers.flatMap(\.senderEmails) {
                let recent = await list("from:\(sender) after:\(monthAgo)", token: token, max: 500)
                let total = await list("from:\(sender)", token: token, max: 1)
                let recentText = recent.status == 200 ? "\(recent.ids.count)" : "✗ HTTP \(recent.status) \(GmailSyncService.bodyExcerpt(recent.data, limit: 200))"
                let totalText = total.status == 200 ? "\(total.estimate ?? 0)" : "✗ HTTP \(total.status)"
                line("  \(sender): \(recentText) / \(totalText)")
            }

            // La misma búsqueda que la lectura automática, tal cual.
            let senders = sync.parsers.flatMap(\.senderEmails).map { "from:\($0)" }.joined(separator: " OR ")
            if let last = sync.lastSyncDate {
                let after = Int(last.timeIntervalSince1970) - 3600
                let auto = await list("(\(senders)) AND after:\(after)", token: token, max: 500)
                line()
                line("Búsqueda de la lectura automática (desde la última lectura − 1 h): HTTP \(auto.status) · \(auto.ids.count) correos · \(auto.ids.filter { !processed.contains($0) }.count) sin procesar")
            } else {
                line()
                line("⚠️ Nunca se eligió desde cuándo leer: la lectura automática no hace nada hasta leer un periodo en Correo y bancos.")
            }

            // 5. Cómo lee la app los últimos correos
            section("Últimos correos de bancos (30 días) y cómo los lee la app")
            let sample = await list("(\(senders)) AND after:\(monthAgo)", token: token, max: 12)
            if sample.status != 200 {
                line("✗ HTTP \(sample.status): \(GmailSyncService.bodyExcerpt(sample.data))")
            } else if sample.ids.isEmpty {
                line("Ninguno. Gmail no tiene correos de los bancos compatibles en los últimos 30 días en esta cuenta.")
            }
            for id in sample.ids {
                let message = await get("\(sync.baseURL)/messages/\(id)?format=full", token: token)
                line()
                guard message.status == 200, let json = message.json else {
                    line("• \(id): ✗ HTTP \(message.status) \(GmailSyncService.bodyExcerpt(message.data, limit: 200))")
                    continue
                }
                let text = sync.extractFullText(from: json)
                let received = (json["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                line("• \(id) · \(GmailSyncService.logDate(received))")
                line("  De: \(GmailSyncService.header("From", in: json) ?? "?") · Asunto: \(GmailSyncService.header("Subject", in: json) ?? "?")")
                line("  Estructura: \(GmailSyncService.mimeSummary(json)) · texto extraído: \(text.count) caracteres")
                line("  Procesado antes: \(processed.contains(id) ? "sí" : "no") · en la base: \(knownIDs.contains(id) ? "sí" : "no")")
                if let parsed = sync.parseEmailBody(text, receivedAt: received) {
                    if let e = parsed.expense {
                        line("  → \(parsed.bankName): gasto\(e.isReversal ? " (anulación)" : "") \(e.currency) \(e.amount) · «\(e.merchant)» · \(GmailSyncService.logDate(e.date)) · tarjeta \(e.cardLastDigits ?? "—")")
                    } else if let i = parsed.income {
                        line("  → \(parsed.bankName): ingreso \(i.currency) \(i.amount) · «\(i.title ?? i.source)» · \(GmailSyncService.logDate(i.date))")
                    }
                } else {
                    line("  → ✗ NINGÚN LECTOR LO RECONOCE. Texto: «\(GmailSyncService.excerpt(text, 700))»")
                }
            }
        }

        // 6. Bitácora
        section("Bitácora (Gmail, cuelgues y aperturas; últimas 8 aperturas)")
        let sessions = Diagnostics.shared.files(prefix: "session-").reversed()
        var logLines: [String] = []
        for url in sessions {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            logLines.append("--- \(url.lastPathComponent) ---")
            // Las pilas del vigilante van en las líneas sangradas que siguen a
            // «pila de main»: sin ellas un cuelgue dice cuándo, no dónde.
            var inStack = false
            for line in text.split(separator: "\n").map(String.init) {
                if line.contains("pila de main") {
                    inStack = true
                } else if inStack, line.hasPrefix("    ") {
                    // Sigue la pila.
                } else {
                    inStack = false
                    guard line.contains("Gmail") || line.contains("CUELGUE") || line.contains("Apertura")
                            || line.contains("volvió tras") else { continue }
                }
                logLines.append(line)
            }
        }
        out += logLines.suffix(1500)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Diagnostics.shared.directory
            .appendingPathComponent("gmail-informe-\(stamp.string(from: Date())).txt")
        try? out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        Diagnostics.shared.log("Gmail: informe de diagnóstico generado (\(out.count) líneas)")
        return url
    }

    // MARK: - Red

    private struct Response {
        let status: Int
        let data: Data?
        var json: [String: Any]? {
            data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static func get(_ urlString: String, token: String?) async -> Response {
        guard let url = URL(string: urlString) else { return Response(status: -2, data: nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return Response(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
        } catch {
            return Response(status: -1, data: GmailSyncService.describe(error).data(using: .utf8))
        }
    }

    private static func list(_ query: String, token: String, max: Int) async -> (status: Int, ids: [String], estimate: Int?, data: Data?) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let response = await get("\(GmailSyncService.shared.baseURL)/messages?q=\(encoded)&maxResults=\(max)", token: token)
        let ids = (response.json?["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return (response.status, ids, response.json?["resultSizeEstimate"] as? Int, response.data)
    }

    /// Lo que Google dice del token: si vale, cuánto le queda y qué permisos
    /// lleva. El token va al endpoint oficial de Google, no al informe.
    private static func tokenInfo(_ token: String) async -> (valid: Bool, summary: String) {
        // Por POST: el token no viaja en la URL.
        var response = Response(status: -2, data: nil)
        if let url = URL(string: "https://oauth2.googleapis.com/tokeninfo") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encoded = token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token
            request.httpBody = "access_token=\(encoded)".data(using: .utf8)
            if let (data, http) = try? await URLSession.shared.data(for: request) {
                response = Response(status: (http as? HTTPURLResponse)?.statusCode ?? -1, data: data)
            } else {
                response = Response(status: -1, data: nil)
            }
        }
        guard response.status == 200, let json = response.json else {
            return (false, "✗ HTTP \(response.status): \(GmailSyncService.bodyExcerpt(response.data, limit: 200))")
        }
        let scope = json["scope"] as? String ?? "?"
        let hasGmail = scope.contains("gmail.readonly")
        let expires = json["expires_in"] as? String ?? "\(json["expires_in"] ?? "?")"
        return (hasGmail, "válido · vence en \(expires) s · permisos: \(scope)\(hasGmail ? "" : "  ⚠️ FALTA gmail.readonly")")
    }

    // MARK: - Utilidades

    private static func mask(_ email: String?) -> String {
        guard let email, let at = email.firstIndex(of: "@") else { return email ?? "—" }
        let name = email[..<at]
        return String(name.prefix(3)) + "***" + email[at...]
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func describe(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "disponible"
        case .denied: return "desactivada"
        case .restricted: return "restringida"
        @unknown default: return "?"
        }
    }
}
