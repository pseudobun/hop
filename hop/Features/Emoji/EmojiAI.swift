import Foundation

/// Emoji for a query the index can't place, from a small OpenAI model.
nonisolated enum EmojiAI {
    static let instructions = """
        You pick emoji for the search box of a Mac launcher. The user types any language \
        (often Slovenian or English), slang, or a situation. Reply with 8 different emoji \
        that best express it, the most fitting first.
        """

    /// Strict JSON: `{"emoji": ["🔥", …]}`.
    static var schema: (name: String, schema: [String: Any]) { ("emoji_picks", [
        "type": "object", "additionalProperties": false, "required": ["emoji"],
        "properties": ["emoji": ["type": "array", "items": ["type": "string"]]],
    ]) }

    /// Asks the model; the emoji come back as typed (validate them against the index).
    static func suggest(_ query: String, model: String, reasoning: String) async -> Result<[String], OpenAI.Failure> {
        let reply = await OpenAI.chat(system: instructions, user: query, model: model, reasoning: reasoning, schema: schema)
        return reply.flatMap { parse($0).map(Result.success) ?? .failure(.invalid) }
    }

    /// The emoji in the model's JSON reply.
    static func parse(_ content: String) -> [String]? {
        (try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])?["emoji"] as? [String]
    }
}
