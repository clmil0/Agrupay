import Foundation

/// Enlaces `agrupay://` que abren la app en un sitio concreto.
///
/// Los usan los widgets (que no pueden escribir en la base: ver
/// `WidgetSnapshot`) y cualquier atajo de la app Atajos. Un solo tipo para
/// construirlos y leerlos, así el widget y la app no pueden desalinearse.
enum AppDeepLink: Equatable {

    static let scheme = "agrupay"

    /// Abre el formulario. `source` sólo aplica a ingresos ("Yape", "Plin"…).
    case add(isIncome: Bool, source: String?)
    /// Registra un gasto rápido al momento, con la opción de deshacer.
    case quick(UUID)
    case summary
    case categories
    case pending
    case rhythm
    /// Invitación de un amigo: abre Amigos con la hoja lista para aceptar.
    case friendInvite(code: String)
    /// Amigos, sin invitación: lo que abre un recordatorio de cobro.
    case friends

    /// Anotar un gasto o ingreso: lo único que se abre sin desbloquear la app
    /// (Face ID se pide al cerrar el formulario).
    var isQuickEntry: Bool {
        switch self {
        case .add, .quick: return true
        default: return false
        }
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case let .add(isIncome, source):
            c.host = "add"
            var items = [URLQueryItem(name: "type", value: isIncome ? "ingreso" : "gasto")]
            if let source { items.append(URLQueryItem(name: "source", value: source)) }
            c.queryItems = items
        case .quick(let id):
            c.host = "quick"
            c.queryItems = [URLQueryItem(name: "id", value: id.uuidString)]
        case .summary:    c.host = "summary"
        case .categories: c.host = "categories"
        case .pending:    c.host = "pending"
        case .rhythm:     c.host = "rhythm"
        case .friends:    c.host = "amigos"
        case .friendInvite(let code):
            c.host = "amigo"
            c.queryItems = [URLQueryItem(name: "codigo", value: code)]
        }
        return c.url ?? URL(string: "\(Self.scheme)://summary")!
    }

    init?(url: URL) {
        // Enlace universal: https://<dominio>/amigo/<código>. Es el que se
        // comparte por WhatsApp, que no vuelve tocables los `agrupay://`.
        if url.scheme?.lowercased() == "https" {
            guard let host = url.host?.lowercased(), InviteLinks.webHosts.contains(host) else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, parts[0].lowercased() == "amigo",
                  let code = InviteLinks.normalizedCode(parts[1]) else { return nil }
            self = .friendInvite(code: code)
            return
        }

        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                               uniquingKeysWith: { first, _ in first })

        switch url.host?.lowercased() {
        case "add":
            let source = query["source"].flatMap { $0.isEmpty ? nil : $0 }
            self = .add(isIncome: query["type"] == "ingreso", source: source)
        case "quick":
            guard let id = query["id"].flatMap(UUID.init(uuidString:)) else { return nil }
            self = .quick(id)
        case "summary":    self = .summary
        case "categories": self = .categories
        case "pending":    self = .pending
        case "rhythm":     self = .rhythm
        case "amigos":     self = .friends
        case "amigo":
            guard let code = query["codigo"].flatMap(InviteLinks.normalizedCode) else { return nil }
            self = .friendInvite(code: code)
        default: return nil
        }
    }
}

/// El enlace que se comparte al invitar a un amigo.
///
/// **Por qué https y no `agrupay://`:** WhatsApp sólo vuelve tocables los
/// enlaces web. Un enlace universal (`https://<dominio>/amigo/<código>`) abre
/// la app directamente si está instalada, y si no, la página del dominio
/// (carpeta `web/` del repo).
///
/// El dominio se configura **una sola vez**, en el ajuste de compilación
/// `INVITE_LINK_DOMAIN` del target de la app: de ahí salen el entitlement
/// *Associated Domains* y la clave `AgruPayInviteDomain` del Info.plist que
/// se lee aquí.
enum InviteLinks {

    static let infoKey = "AgruPayInviteDomain"

    /// Dominios que se aceptan como invitación. El primero es el que se comparte.
    static var webHosts: [String] {
        let raw = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Sin expandir (`$(INVITE_LINK_DOMAIN)`) o vacío: no hay dominio.
        guard !raw.isEmpty, !raw.contains("$") else { return [] }
        return [raw]
    }

    static func webURL(code: String) -> URL? {
        guard let host = webHosts.first else { return nil }
        return URL(string: "https://\(host)/amigo/\(code)")
    }

    /// - Parameter linkReady: la página del dominio ya responde (ver
    ///   `InviteLinkCheck`). Hasta entonces va sólo el código: un enlace a una
    ///   página que todavía no existe sería peor que ninguno.
    static func shareText(token: String, linkReady: Bool) -> String {
        let grouped = Self.grouped(token)
        guard linkReady, let url = webURL(code: token) else {
            return "Agrégame en AgruPay con esta invitación (sirve una vez, 72 h): \(grouped)"
        }
        return "Agrégame en AgruPay 👉 \(url.absoluteString)\nSirve una vez y caduca en 72 h. Código: \(grouped)"
    }

    /// `XXXX-XXXX-XXXX-XXXX-XXXX`, para leerlo o dictarlo.
    static func grouped(_ token: String) -> String {
        stride(from: 0, to: token.count, by: 4).map { start -> String in
            let from = token.index(token.startIndex, offsetBy: start)
            let to = token.index(from, offsetBy: min(4, token.distance(from: from, to: token.endIndex)))
            return String(token[from..<to])
        }.joined(separator: "-")
    }

    /// Longitud de un token de invitación (`create_friend_invite`).
    static let tokenLength = 20

    /// Un token de invitación: 20 caracteres Crockford base32. Acepta guiones,
    /// espacios y minúsculas, y corrige las letras que se confunden (O→0,
    /// I/L→1), igual que `normalize_invite_token` en el servidor.
    static func normalizedCode(_ raw: String) -> String? {
        let mapped = raw.uppercased().compactMap { char -> Character? in
            switch char {
            case "O": return "0"
            case "I", "L": return "1"
            default: return char.isASCII && (char.isLetter || char.isNumber) ? char : nil
            }
        }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard mapped.count == tokenLength, mapped.allSatisfy(alphabet.contains) else { return nil }
        return String(mapped)
    }
}
