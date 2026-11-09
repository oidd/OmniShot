import Foundation

/// Which service translates: the built-in free one needs no setup, the LLM one needs the user's own API key.
public enum TranslationEngine: String, CaseIterable, Sendable {
    case free
    case llm
}

public struct TranslationConfig: Equatable, Sendable {
    public var engine: TranslationEngine
    /// Random per-install id the free service expects in its request header.
    public var clientKey: String
    public var baseURL: String
    public var model: String
    public var apiKey: String
    /// Which saved 大模型 entry this came from. Two entries can name the same model (both `deepseek-flash`,
    /// say) while pointing at different services, so the cache tells them apart by this rather than by the
    /// model name.
    public var configID: String
    /// Which shape the service's API has. Everything except Claude and Gemini is the OpenAI one.
    public var provider: LLMProvider
    public var targetLanguage: String
    /// What the text is, when the user has said. `autoSource` lets the service work it out, which is the
    /// default everywhere and the only thing the capture flow ever uses.
    public var sourceLanguage: String
    /// The instruction sent to the model, with `{target}` and `{source}` left for the languages. Editable in
    /// Settings; empty means `defaultSystemPrompt`.
    public var systemPrompt: String
    public var timeout: TimeInterval

    public init(baseURL: String, model: String, apiKey: String, targetLanguage: String, sourceLanguage: String = autoSource,
                systemPrompt: String = "", timeout: TimeInterval = 20,
                engine: TranslationEngine = .llm, clientKey: String = "", configID: String = "",
                provider: LLMProvider = .openai) {
        self.engine = engine
        self.clientKey = clientKey
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.configID = configID
        self.provider = provider
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.systemPrompt = systemPrompt
        self.timeout = timeout
    }

    /// The source-language choice that means "work it out from the text".
    public static let autoSource = "自动检测"
    /// What the model is told, unless the user has written their own. `{target}` and `{source}` are the only
    /// parts that change from one translation to the next.
    public static let defaultSystemPrompt = """
    你是软件界面与文档翻译器。把输入中每一项的 text 翻译成{target}，译文简洁自然，符合界面用语习惯。
    代码、文件路径、网址、数字、快捷键和产品名保持原样。
    只输出 JSON，格式为 {"items":[{"id":0,"t":"译文"}]}，id 与输入一一对应，不要遗漏或增加条目。
    """
    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"
    public static let defaultTargetLanguage = "简体中文"
    /// Anthropic's API requires the version as a header; this is the one the `/v1/messages` shape has had since
    /// it was introduced.
    public static let anthropicVersion = "2023-06-01"
}

public enum TranslationError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidBaseURL(String)
    case http(status: Int, message: String)
    case badResponse(String)
    case service(String)
    /// The model ran into its own output ceiling, so what came back is half a JSON document.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "还没有填写 API Key。请在菜单栏 OmniShot → 设置 中填写。"
        case .invalidBaseURL(let url):
            return "Base URL 无效：\(url)"
        case .http(let status, let message):
            switch status {
            case 401: return "API Key 无效（401）。请在设置中检查 Key。"
            case 402: return "账户余额不足（402）。"
            case 404: return "服务返回 404：地址不对。Base URL 填到域名（或 /v1）为止，不要带 /chat/completions。（\(message)）"
            case 429: return "请求太频繁（429），请稍后再试。"
            default: return "翻译服务返回错误 \(status)：\(message)"
            }
        case .badResponse(let detail):
            return "翻译结果无法解析：\(detail)"
        case .service(let detail):
            return "免费翻译暂时不可用（\(detail)）。可以在设置 → 翻译 中改用大模型。"
        case .truncated:
            return "译文被模型的最大输出长度截断了。换个大输出上限的模型，或缩小选区再翻。"
        }
    }

    /// Whether this is the service refusing the JSON flag rather than a real problem with the request.
    ///
    /// There is no standard error code for it: services word it as `response_format is not supported`,
    /// `json mode is not supported for this model`, `Unknown field response_format` and so on, all under a
    /// 400 or 422. The message is the only thing to go on, so it is a text match.
    var isUnsupportedJSONMode: Bool {
        guard case let .http(status, message) = self, status == 400 || status == 422 else { return false }
        let text = message.lowercased()
        return text.contains("response_format") || text.contains("json_object") || text.contains("json mode")
    }
}

/// Client for OpenAI-compatible chat completion APIs (DeepSeek by default).
/// Sends all blocks of one screenshot in a single request so the model sees the whole context.
public enum ChatTranslator {
    public struct Item: Equatable, Sendable {
        public var id: Int
        public var text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Fills in a system-prompt template: `{target}` and `{source}` become the languages this translation is
    /// using, and `{source}` reads 自动识别 when the source is being worked out rather than given.
    static func systemPrompt(template: String, targetLanguage: String, sourceLanguage: String) -> String {
        let source = sourceLanguage == TranslationConfig.autoSource ? "自动识别" : sourceLanguage
        let text = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TranslationConfig.defaultSystemPrompt : template
        return text.replacingOccurrences(of: "{target}", with: targetLanguage)
            .replacingOccurrences(of: "{source}", with: source)
    }

    /// Claude has no default output ceiling and the API insists on one. A whole screen of text, translated
    /// into something longer, needs room; `TranslationError.truncated` says so when it still runs out.
    static let maximumTokens = 8192

    /// What goes in front of the path we are about to append.
    ///
    /// People paste the endpoint straight out of the docs at least as often as the bare base URL — Groq hands
    /// out `…/openai/v1/chat/completions` — and the doubled path that produces is a 404 that says nothing
    /// about the real problem. So drop a trailing copy of the path about to be added, the version segment in
    /// front of it (`…/v1`), and whatever `/models/<model>` came along for Gemini.
    static func baseURL(_ raw: String, appending path: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        func drop(_ suffix: String) {
            guard suffix.count > 1 else { return }
            while base.hasSuffix("/") { base.removeLast() }
            guard base.lowercased().hasSuffix(suffix.lowercased()) else { return }
            base.removeLast(suffix.count)
            while base.hasSuffix("/") { base.removeLast() }
        }

        drop(path)
        if let models = base.range(of: "/models/") { base = String(base[..<models.lowerBound]) }
        if let version = path.split(separator: "/").first { drop("/" + version) }
        return base
    }

    /// Where this service's translation call lives. Gemini puts the model in the path rather than the body.
    static func endpoint(config: TranslationConfig) throws -> URL {
        var model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Gemini docs write it both ways; `models/models/…` is what comes out of not noticing.
        if model.hasPrefix("models/") { model.removeFirst("models/".count) }
        let path: String
        switch config.provider {
        case .openai: path = "/chat/completions"
        case .anthropic: path = "/v1/messages"
        case .gemini: path = "/v1beta/models/\(model):generateContent"
        }
        let url = URL(string: baseURL(config.baseURL, appending: path) + path)
        guard let url, url.scheme?.hasPrefix("http") == true, url.host != nil else {
            throw TranslationError.invalidBaseURL(config.baseURL)
        }
        return url
    }

    public static func makeRequest(items: [Item], config: TranslationConfig, jsonMode: Bool = true) throws -> URLRequest {
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        let url = try endpoint(config: config)

        let input: [String: Any] = ["items": items.map { ["id": $0.id, "text": $0.text] }]
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        let system = systemPrompt(template: config.systemPrompt, targetLanguage: config.targetLanguage,
                                  sourceLanguage: config.sourceLanguage)

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch config.provider {
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var fields: [String: Any] = [
                "model": config.model,
                "temperature": 0.3,
                "stream": false,
                "messages": [["role": "system", "content": system], ["role": "user", "content": inputJSON]],
            ]
            if jsonMode { fields["response_format"] = ["type": "json_object"] }
            body = fields

        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(TranslationConfig.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            // `system` is a field of its own here, not a message, and `messages` may only hold user/assistant.
            body = [
                "model": config.model,
                "max_tokens": maximumTokens,
                "temperature": 0.3,
                "system": system,
                "messages": [["role": "user", "content": inputJSON]],
            ]

        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var generation: [String: Any] = ["temperature": 0.3]
            if jsonMode { generation["responseMimeType"] = "application/json" }
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": inputJSON]]]],
                "generationConfig": generation,
            ]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Parses a response into `id → translation`. Each provider wraps the same JSON document differently; what
    /// the model was asked to write is the same for all of them.
    /// Items the model dropped are simply absent; callers keep the original text for them.
    public static func parseResponse(_ data: Data, provider: LLMProvider = .openai) throws -> [Int: String] {
        switch provider {
        case .openai:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else { throw TranslationError.badResponse("缺少 choices[0].message.content") }
            return try parseContent(content)

        case .anthropic:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = root["content"] as? [[String: Any]]
            else { throw TranslationError.badResponse("缺少 content") }
            // Checked before parsing: a cut-off answer is half a JSON document, and "无法解析" would send the
            // user looking for a problem with the prompt instead of with the length.
            guard root["stop_reason"] as? String != "max_tokens" else { throw TranslationError.truncated }
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw TranslationError.badResponse("content 里没有文字") }
            return try parseContent(text)

        case .gemini:
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TranslationError.badResponse("返回内容不是预期的 JSON")
            }
            // A blocked prompt comes back with no candidates at all and the reason in `promptFeedback`.
            if let feedback = root["promptFeedback"] as? [String: Any],
               let reason = feedback["blockReason"] as? String {
                throw TranslationError.badResponse("Gemini 拦下了这次请求（\(reason)）")
            }
            guard let candidates = root["candidates"] as? [[String: Any]], let first = candidates.first else {
                throw TranslationError.badResponse("缺少 candidates")
            }
            guard first["finishReason"] as? String != "MAX_TOKENS" else { throw TranslationError.truncated }
            let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw TranslationError.badResponse("candidates 里没有文字") }
            return try parseContent(text)
        }
    }

    static func parseContent(_ content: String) throws -> [Int: String] {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some models wrap JSON in a Markdown code fence despite json_object mode.
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let items = object["items"] as? [[String: Any]]
        else { throw TranslationError.badResponse("返回内容不是预期的 JSON") }

        var result: [Int: String] = [:]
        for item in items {
            let id: Int?
            switch item["id"] {
            case let n as Int: id = n
            case let s as String: id = Int(s)
            default: id = nil
            }
            let translation = (item["t"] ?? item["zh"] ?? item["translation"]) as? String
            if let id, let translation, !translation.isEmpty { result[id] = translation }
        }
        return result
    }

    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self)
    }

    public static func translate(_ items: [Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        do {
            return try await send(items, config: config, jsonMode: true, session: session)
        } catch let error as TranslationError where error.isUnsupportedJSONMode {
            // Some services — and some models on a service that does support it — refuse the JSON flag outright.
            // The system prompt already asks for JSON and `parseContent` copes with a fenced reply, so one retry
            // without the flag beats making everyone find and flip a setting they have no way to diagnose.
            return try await send(items, config: config, jsonMode: false, session: session)
        }
    }

    static func send(_ items: [Item], config: TranslationConfig, jsonMode: Bool,
                     session: URLSession) async throws -> [Int: String] {
        let request = try makeRequest(items: items, config: config, jsonMode: jsonMode)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslationError.http(status: http.statusCode, message: errorMessage(from: data))
        }
        return try parseResponse(data, provider: config.provider)
    }
}

/// Client for Tencent TranSmart's public web endpoint (no key; unofficial, so failures point users at the LLM engine).
/// It takes a whole list of texts per request but rejects a request over roughly 5000 characters, hence the batching.
public enum FreeTranslator {
    static let endpoint = URL(string: "https://transmart.qq.com/api/imt")!
    static let batchLimit = 4000

    /// Language names shown in Settings → codes the service accepts.
    static func languageCode(_ language: String) -> String {
        switch language {
        case "繁體中文": return "zh-TW"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh"
        }
    }

    /// The source language in the service's terms. `autoSource` is the one that means "work it out".
    static func sourceCode(_ language: String) -> String {
        language == TranslationConfig.autoSource ? "auto" : languageCode(language)
    }

    /// Splits long items too, retaining their IDs so translations can be reassembled in order.
    static func batches(_ items: [ChatTranslator.Item], limit: Int = batchLimit) -> [[ChatTranslator.Item]] {
        precondition(limit >= 2)
        var result: [[ChatTranslator.Item]] = []
        var current: [ChatTranslator.Item] = []
        var count = 0
        for item in items {
            var chunks: [String] = []
            var chunk = ""
            var length = 0
            // Count UTF-16 units conservatively without splitting surrogate pairs.
            for scalar in item.text.unicodeScalars {
                let size = scalar.utf16.count
                if length + size > limit {
                    chunks.append(chunk)
                    chunk = ""
                    length = 0
                }
                chunk.unicodeScalars.append(scalar)
                length += size
            }
            if !chunk.isEmpty || chunks.isEmpty { chunks.append(chunk) }
            for text in chunks {
                let size = text.utf16.count
                if !current.isEmpty, count + size > limit {
                    result.append(current)
                    current = []
                    count = 0
                }
                current.append(.init(id: item.id, text: text))
                count += size
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func makeRequest(texts: [String], config: TranslationConfig) throws -> URLRequest {
        let clientKey = config.clientKey.isEmpty ? "browser-chrome-110.0.0-Mac OS-omnishot" : config.clientKey
        let body: [String: Any] = [
            "header": ["fn": "auto_translation", "client_key": clientKey],
            "type": "plain",
            "model_category": "normal",
            "source": ["lang": sourceCode(config.sourceLanguage), "text_list": texts],
            "target": ["lang": languageCode(config.targetLanguage)],
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Returns the translations in request order. A count mismatch would shift every later paragraph, so it is an error.
    static func parseResponse(_ data: Data, expected: Int) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any]
        else { throw TranslationError.badResponse("返回内容不是预期的 JSON") }
        let code = header["ret_code"] as? String ?? "unknown"
        guard code == "succ" else { throw TranslationError.service(code) }
        guard let texts = root["auto_translation"] as? [String], texts.count == expected else {
            throw TranslationError.badResponse("译文数量与原文不一致")
        }
        return texts
    }

    static func send(_ batch: [ChatTranslator.Item], config: TranslationConfig, session: URLSession) async throws -> [String] {
        let request = try makeRequest(texts: batch.map(\.text), config: config)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.service(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslationError.service("HTTP \(http.statusCode)")
        }
        return try parseResponse(data, expected: batch.count)
    }

    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        let requests = batches(items)
        return try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (index, batch) in requests.enumerated() {
                group.addTask { (index, try await send(batch, config: config, session: session)) }
            }
            var responses = Array(repeating: [String](), count: requests.count)
            for try await (index, texts) in group { responses[index] = texts }
            var merged: [Int: String] = [:]
            for (batch, texts) in zip(requests, responses) {
                for (item, text) in zip(batch, texts) {
                    // An empty fragment must not discard that part of the original paragraph.
                    merged[item.id, default: ""] += text.isEmpty ? item.text : text
                }
            }
            return merged
        }
    }
}

/// The one entry point callers use: picks the service from the settings.
public enum Translator {
    public static func translate(_ items: [ChatTranslator.Item], config: TranslationConfig, session: URLSession = .shared) async throws -> [Int: String] {
        switch config.engine {
        case .free: return try await FreeTranslator.translate(items, config: config, session: session)
        case .llm: return try await ChatTranslator.translate(items, config: config, session: session)
        }
    }
}

/// In-memory cache so toggling or re-translating the same text costs nothing.
public final class TranslationCache: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    static func key(_ text: String, _ config: TranslationConfig) -> String {
        // Keyed by the saved entry, not by the model: two entries may well use the same model name.
        let service = config.engine == .free ? "free" : (config.configID.isEmpty ? config.model : config.configID)
        return [service, config.sourceLanguage, config.targetLanguage, text].joined(separator: "\u{1F}")
    }

    public func get(_ text: String, config: TranslationConfig) -> String? {
        lock.withLock { storage[Self.key(text, config)] }
    }

    public func set(_ translation: String, for text: String, config: TranslationConfig) {
        lock.withLock { storage[Self.key(text, config)] = translation }
    }

    /// Drops one entry, so the next ask for it goes to the service instead. This is what 「重新翻译」 means:
    /// an answer that comes back out of the cache is the answer that is already on screen, and the user is
    /// pressing the button to get one that isn't — or, after a timeout, to get any answer at all.
    public func forget(_ text: String, config: TranslationConfig) {
        lock.withLock { storage[Self.key(text, config)] = nil }
    }

    /// Translates `items`, sending only the texts that are not cached yet.
    public func translate(_ items: [ChatTranslator.Item], config: TranslationConfig,
                          send: ([ChatTranslator.Item]) async throws -> [Int: String]) async throws -> [Int: String] {
        var result: [Int: String] = [:]
        var missing: [ChatTranslator.Item] = []
        for item in items {
            if let cached = get(item.text, config: config) { result[item.id] = cached } else { missing.append(item) }
        }
        if !missing.isEmpty {
            let fresh = try await send(missing)
            for item in missing {
                if let t = fresh[item.id] {
                    result[item.id] = t
                    set(t, for: item.text, config: config)
                }
            }
        }
        return result
    }
}
