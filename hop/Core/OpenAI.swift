import AppKit

/// OpenAI Chat Completions for the features that use a model (translation, emoji
/// suggestions). Opt-in: needs an API key, kept in the login Keychain.
nonisolated enum OpenAI {
    enum Failure: Error, Equatable { case noKey, http(Int, String?), timeout, invalid }

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    /// The reply's text. `schema` (name, JSON schema) asks for strict JSON instead.
    static func chat(system: String, user: String, model: String, reasoning: String, maxTokens: Int = 400,
                     schema: (name: String, schema: [String: Any])? = nil, timeout: TimeInterval = 4,
                     session: URLSession = .shared) async -> Result<String, Failure> {
        guard let key = await OpenAIKey.load() else { return .failure(.noKey) }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(system: system, user: user, model: model,
                                                                             reasoning: reasoning, maxTokens: maxTokens, schema: schema))
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(.http(status, errorMessage(data))) }
            return content(data).map(Result.success) ?? .failure(.invalid)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.http(0, error.localizedDescription))
        }
    }

    /// Reasoning models take no temperature; `reasoning` ("none", "low", …) sets
    /// reasoning_effort, "" leaves it out.
    static func body(system: String, user: String, model: String, reasoning: String, maxTokens: Int,
                     schema: (name: String, schema: [String: Any])? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if let schema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": schema.name, "strict": true, "schema": schema.schema] as [String: Any],
            ]
        }
        if !reasoning.isEmpty { body["reasoning_effort"] = reasoning }
        return body
    }

    static func content(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    /// OpenAI's `error.message`, e.g. "The model `x` has been deprecated".
    static func errorMessage(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
    }

    /// For a HUD: what went wrong, in OpenAI's words where there are some.
    static func describe(_ failure: Failure) -> String {
        switch failure {
        case .noKey: "Set an OpenAI API key first (\"Set OpenAI API Key\")"
        case .http(401, _): "OpenAI rejected the API key"
        case .http(let status, let message): "OpenAI: \(message ?? "error \(status)")"
        case .timeout: "OpenAI took too long to answer"
        case .invalid: "OpenAI sent an answer hop couldn't read"
        }
    }
}

/// "Set OpenAI API Key" (⌘↵ removes it).
enum OpenAICommands {
    static func items(_ services: Services) -> [Item] {
        [Item(id: "openai.key", title: "Set OpenAI API Key", subtitle: "For translation and emoji suggestions; kept in the Keychain",
              aliases: ["openai", "api key"], icon: .tile("key.fill", Theme.info), accessory: "Command",
              actions: [
                  Action(title: "Set Key", symbol: "key") { .push(OpenAIKeyMode()) },
                  Action(title: "Remove Key", symbol: "trash", shortcut: .ret(.command), style: .destructive) {
                      OpenAIKey.remove()
                      return .dismissWithHUD("OpenAI key removed")
                  },
              ], tracksFrecency: false, pushesMode: true)]
    }
}

/// The OpenAI API key in the login Keychain. Read once and kept in memory; Keychain
/// calls are IPC, so the first read happens off the main thread.
nonisolated enum OpenAIKey {
    static let service = "dev.hop.app.openai"
    private static let account = "api-key"
    private static let queue = DispatchQueue(label: "hop.openai-key")
    /// Only touched on `queue`.
    private final class Box: @unchecked Sendable { var key: String?; var loaded = false }
    private static let box = Box()

    static func load() async -> String? {
        await withCheckedContinuation { done in
            queue.async {
                if !box.loaded {
                    box.key = read()
                    box.loaded = true
                }
                done.resume(returning: box.key)
            }
        }
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        queue.sync {
            delete()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrLabel as String: "hop OpenAI API key",
                kSecValueData as String: Data(key.utf8),
            ]
            let ok = SecItemAdd(query as CFDictionary, nil) == errSecSuccess
            box.key = ok ? key : nil
            box.loaded = true
            return ok
        }
    }

    static func remove() {
        queue.sync {
            delete()
            box.key = nil
            box.loaded = true
        }
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// "Set OpenAI API Key": a password field; ↵ stores the key in the Keychain.
final class OpenAIKeyMode: Mode {
    let title: String? = "OpenAI Key"
    let tint: NSColor? = Theme.info
    let placeholder = "Paste your OpenAI API key (sk-…) and press ↵"
    var isSecureInput: Bool { true }

    func sections(for query: String) -> [ResultSection] {
        // Typing leaves no rows, so ↵ reaches `submit`.
        guard query.isEmpty else { return [] }
        return [ResultSection(title: nil, items: [Item(
            id: "openai.key.hint", title: "For translation and emoji suggestions",
            subtitle: "Stored in your login Keychain. Only text you translate or ask emoji for is sent to OpenAI.",
            icon: .symbol("key"), actions: [], tracksFrecency: false)])]
    }

    func submit(_ query: String) -> ActionResult? {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 20 else { return .warnWithHUD("That doesn't look like an OpenAI key (sk-…)") }
        return OpenAIKey.save(key) ? .dismissWithHUD("OpenAI key saved") : .failWithHUD("Could not save the key to the Keychain")
    }
}
