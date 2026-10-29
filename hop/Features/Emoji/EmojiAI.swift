import AppKit

/// Emoji for a query the index can't place ("ko deploy faila v petek"), from a small
/// OpenAI model. Opt-in: needs an API key, stored in the login Keychain.
nonisolated enum EmojiAI {
    enum Failure: Error, Equatable { case noKey, http(Int), timeout, invalid }

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let instructions = """
        You pick emoji for the search box of a Mac launcher. The user types any language \
        (often Slovenian or English), slang, or a situation. Reply with 8 different emoji \
        that best express it, the most fitting first.
        """

    /// Asks the model; the emoji come back as typed (validate them against the index).
    static func suggest(_ query: String, key: String, model: String, session: URLSession = .shared) async -> Result<[String], Failure> {
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(query, model: model))
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(.http(status)) }
            return parse(data).map(Result.success) ?? .failure(.invalid)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.http(0))
        }
    }

    /// Chat Completions with a strict JSON schema: `{"emoji": ["🔥", …]}`.
    static func body(_ query: String, model: String) -> [String: Any] {
        [
            "model": model,
            "temperature": 0.2,
            "max_completion_tokens": 80,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": query]],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "emoji_picks", "strict": true,
                    "schema": [
                        "type": "object", "additionalProperties": false, "required": ["emoji"],
                        "properties": ["emoji": ["type": "array", "items": ["type": "string"]]],
                    ] as [String: Any],
                ] as [String: Any],
            ],
        ]
    }

    static func parse(_ data: Data) -> [String]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let picks = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let emoji = picks["emoji"] as? [String] else { return nil }
        return emoji
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
    let tint: NSColor? = Palette.emoji
    let placeholder = "Paste your OpenAI API key (sk-…) and press ↵"
    var isSecureInput: Bool { true }

    func sections(for query: String) -> [ResultSection] {
        // Typing leaves no rows, so ↵ reaches `submit`.
        guard query.isEmpty else { return [] }
        return [ResultSection(title: nil, items: [Item(
            id: "openai.key.hint", title: "Used for emoji suggestions only",
            subtitle: "Stored in your login Keychain. Queries that the emoji index can't place are sent to OpenAI.",
            icon: .symbol("key"), actions: [], tracksFrecency: false)])]
    }

    func submit(_ query: String) -> ActionResult? {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 20 else { return .warnWithHUD("That doesn't look like an OpenAI key (sk-…)") }
        return OpenAIKey.save(key) ? .dismissWithHUD("OpenAI key saved") : .failWithHUD("Could not save the key to the Keychain")
    }
}
