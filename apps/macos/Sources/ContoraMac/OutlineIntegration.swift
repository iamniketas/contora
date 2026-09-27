import Foundation
import Security

struct OutlineSettings: Sendable {
    var baseURL: String
    var apiToken: String
    var defaultCollectionID: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canPublish: Bool {
        isConfigured && !defaultCollectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct OutlineCollection: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let description: String?
}

struct OutlineDocumentLink: Codable, Hashable, Sendable {
    let documentID: String
    let url: String?
}

enum OutlineIntegrationError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case invalidResponse
    case api(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Outline is not configured. Add a URL, API token, and collection in Settings."
        case .invalidBaseURL:
            return "The Outline URL is invalid."
        case .invalidResponse:
            return "Outline returned an unexpected response."
        case let .api(statusCode, message):
            return "Outline returned HTTP \(statusCode): \(message)"
        }
    }
}

struct OutlineService: Sendable {
    private struct Envelope<Value: Decodable>: Decodable {
        let data: Value
    }

    private struct DocumentPayload: Decodable {
        let id: String
        let url: String?
    }

    private struct APIErrorPayload: Decodable {
        let message: String?
        let error: String?
    }

    let settings: OutlineSettings

    func collections() async throws -> [OutlineCollection] {
        try await post(endpoint: "collections.list", body: [:], response: [OutlineCollection].self)
    }

    func createDocument(title: String, markdown: String) async throws -> OutlineDocumentLink {
        guard settings.canPublish else { throw OutlineIntegrationError.notConfigured }
        let payload: [String: Any] = [
            "title": title,
            "text": markdown,
            "collectionId": settings.defaultCollectionID,
            "publish": true,
        ]
        let document = try await post(endpoint: "documents.create", body: payload, response: DocumentPayload.self)
        return documentLink(from: document)
    }

    func updateDocument(id: String, title: String, markdown: String) async throws -> OutlineDocumentLink {
        let payload: [String: Any] = [
            "id": id,
            "title": title,
            "text": markdown,
            "publish": true,
        ]
        let document = try await post(endpoint: "documents.update", body: payload, response: DocumentPayload.self)
        return documentLink(from: document)
    }

    private func post<Value: Decodable>(
        endpoint: String,
        body: [String: Any],
        response: Value.Type
    ) async throws -> Value {
        guard settings.isConfigured else {
            throw OutlineIntegrationError.notConfigured
        }

        let normalizedBaseURL = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(normalizedBaseURL)/api/\(endpoint)") else {
            throw OutlineIntegrationError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw OutlineIntegrationError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorPayload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            let message = errorPayload?.message ?? errorPayload?.error ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw OutlineIntegrationError.api(statusCode: httpResponse.statusCode, message: message)
        }

        guard let decoded = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else {
            throw OutlineIntegrationError.invalidResponse
        }
        return decoded.data
    }

    private func documentLink(from payload: DocumentPayload) -> OutlineDocumentLink {
        guard let path = payload.url, !path.isEmpty else {
            return OutlineDocumentLink(documentID: payload.id, url: nil)
        }
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return OutlineDocumentLink(documentID: payload.id, url: absoluteURL.absoluteString)
        }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return OutlineDocumentLink(documentID: payload.id, url: base + suffix)
    }
}

final class OutlineSettingsStore {
    private enum Key {
        static let baseURL = "outline.baseURL"
        static let collectionID = "outline.defaultCollectionID"
        static let documentLinks = "outline.documentLinks"
        static let tokenAccount = "outline.apiToken"
    }

    private let defaults = UserDefaults.standard
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.niketas.contora"

    func loadSettings() -> OutlineSettings {
        OutlineSettings(
            baseURL: defaults.string(forKey: Key.baseURL) ?? "",
            apiToken: loadToken(),
            defaultCollectionID: defaults.string(forKey: Key.collectionID) ?? ""
        )
    }

    func saveSettings(_ settings: OutlineSettings) throws {
        defaults.set(settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.baseURL)
        defaults.set(settings.defaultCollectionID, forKey: Key.collectionID)
        try saveToken(settings.apiToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func loadDocumentLinks() -> [String: OutlineDocumentLink] {
        guard let data = defaults.data(forKey: Key.documentLinks) else { return [:] }
        return (try? JSONDecoder().decode([String: OutlineDocumentLink].self, from: data)) ?? [:]
    }

    func saveDocumentLinks(_ links: [String: OutlineDocumentLink]) {
        guard let data = try? JSONEncoder().encode(links) else { return }
        defaults.set(data, forKey: Key.documentLinks)
    }

    private func loadToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Key.tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private func saveToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Key.tokenAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }

        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
