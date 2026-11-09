import Foundation

/// How a saved service's HTTP API is shaped.
///
/// Deliberately a short list of **protocols**, not of brands: DeepSeek, Groq, Kimi、智谱、OpenRouter、Ollama 的
/// `/v1` 口，以及所有 One-API / New API 网关都讲同一种 OpenAI 方言，把它们列进来只会变成一份要一直维护的
/// 清单——它们之间真正不同的只是 base URL，而那个由用户自己填。真正换了一套协议的只有 Claude 和 Gemini。
public enum LLMProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case openai
    case anthropic
    case gemini

    public var id: String { rawValue }

    /// What the settings picker calls it.
    public var title: String {
        switch self {
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }

    /// Shown as the placeholder in 设置 when the box is left empty, and what an empty box means.
    public var defaultBaseURL: String {
        switch self {
        case .openai: return TranslationConfig.defaultBaseURL
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        }
    }

    public var defaultModel: String {
        switch self {
        case .openai: return TranslationConfig.defaultModel
        case .anthropic: return "claude-sonnet-5-5"
        case .gemini: return "gemini-2.5-flash"
        }
    }
}

/// One saved 大模型 service: what the user filled into 设置 → 翻译, one entry per service they want to keep
/// around (DeepSeek, a company gateway, Claude, …).
///
/// An empty field means "use this provider's default" — the settings boxes show those as placeholder text.
/// The API key is deliberately not in here: it is a secret, and it lives in its own file per entry
/// (see `Settings.apiKey(for:)`).
public struct LLMConfig: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider: LLMProvider
    public var baseURL: String
    public var model: String
    /// The instruction sent to this service, with `{target}` / `{source}` left for the languages. Empty means
    /// `TranslationConfig.defaultSystemPrompt`, so entries the user never touched follow future improvements.
    public var systemPrompt: String

    public init(id: String = UUID().uuidString, name: String = "", provider: LLMProvider = .openai,
                baseURL: String = "", model: String = "", systemPrompt: String = "") {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.systemPrompt = systemPrompt
    }

    /// Hand-written because `provider` arrived after people had already saved entries: Swift's synthesized
    /// decoder treats a new non-optional field as required, so decoding a stored entry would throw — and
    /// `Settings.llmConfigs` reads a failure as "nothing saved yet", which would quietly replace everyone's
    /// entries with the single carried-over one. Everything except `id` is therefore optional on the way in.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        // An entry saved before providers existed is an OpenAI-compatible one — that was the only shape then.
        provider = try container.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .openai
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
    }

    /// What an entry the user never named is called, in the settings picker and in 输入翻译.
    public static let defaultName = "自定义大模型"
    /// The id of the entry carried over from the single-config version. Its key is still the old `api-key`
    /// file, so an older build — and the rename migration — keep finding it.
    public static let legacyID = "default"

    /// The names the pickers show, in the order the entries were given.
    ///
    /// Two entries the user never named would otherwise read identically in a menu, so the later ones are
    /// numbered. Naming two entries the same thing is the user's own doing; it gets the same treatment so
    /// the menu still tells them apart.
    public static func labels(for configs: [LLMConfig]) -> [String] {
        var seen: [String: Int] = [:]
        return configs.map { config in
            let typed = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = typed.isEmpty ? defaultName : typed
            let count = (seen[name] ?? 0) + 1
            seen[name] = count
            return count == 1 ? name : "\(name) \(count)"
        }
    }

    /// Stores a prompt, keeping the "empty means the built-in one" rule — writing the default back verbatim
    /// is the same thing as clearing it, and clearing it is what keeps the entry following the default.
    public mutating func setPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        systemPrompt = (trimmed.isEmpty || text == TranslationConfig.defaultSystemPrompt) ? "" : text
    }

    /// What actually goes to the service when a box was left empty.
    public var effectiveBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultBaseURL : baseURL
    }

    public var effectiveModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultModel : model
    }

    public var effectiveSystemPrompt: String {
        systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TranslationConfig.defaultSystemPrompt : systemPrompt
    }
}
