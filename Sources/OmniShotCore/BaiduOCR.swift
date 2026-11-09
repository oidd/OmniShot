import CoreGraphics
import Foundation
import ImageIO

/// Which service reads the text. Chosen in 设置 → 文字识别; every OCR path in the app follows it — the OCR
/// panel, the recognition hotkey, translation, a pin's text selection and 自动识别.
public enum OCREngine: String, CaseIterable, Identifiable, Sendable {
    case system, baidu

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "内置识别"
        case .baidu: return "百度 OCR"
        }
    }
}

/// 高精度 and 标准 are two different endpoints with their own quotas — 高精度 is the better reader, 标准 is the
/// fallback for when the monthly allowance runs out.
public enum BaiduOCRPrecision: String, CaseIterable, Identifiable, Sendable {
    case accurate, standard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accurate: return "高精度"
        case .standard: return "标准"
        }
    }

    /// The last path component of the endpoint. Both are the *located* variants: the app needs a box per line
    /// (the OCR panel frames them) and per character (a pin's text selection and 自动识别 cut words with them),
    /// which the `_basic` endpoints do not return at all.
    var path: String {
        switch self {
        case .accurate: return "accurate"
        case .standard: return "general"
        }
    }

    /// The chosen endpoint first, then the other one. Baidu counts the two allowances separately — 500 for
    /// 高精度 and 1000 for 标准 — so one running out is not a reason to stop reading.
    var attemptOrder: [BaiduOCRPrecision] {
        switch self {
        case .accurate: return [.accurate, .standard]
        case .standard: return [.standard, .accurate]
        }
    }
}

public enum BaiduOCRLanguage: String, CaseIterable, Identifiable, Sendable {
    case chineseEnglish = "CHN_ENG"
    case auto = "auto_detect"
    case english = "ENG"
    case japanese = "JAP"
    case korean = "KOR"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chineseEnglish: return "中文 + 英文"
        case .auto: return "自动检测"
        case .english: return "英文"
        case .japanese: return "日文"
        case .korean: return "韩文"
        }
    }
}

public struct BaiduOCRConfig: Equatable, Sendable {
    public var apiKey: String
    public var secretKey: String
    public var precision: BaiduOCRPrecision
    public var language: BaiduOCRLanguage

    public init(apiKey: String, secretKey: String, precision: BaiduOCRPrecision = .accurate,
                language: BaiduOCRLanguage = .chineseEnglish) {
        self.apiKey = apiKey
        self.secretKey = secretKey
        self.precision = precision
        self.language = language
    }

    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One character's box. Normalized 0…1 with the origin at the **top** left, the way Baidu reports it; the
/// caller maps it into the capture view's own space.
public struct BaiduOCRChar: Equatable, Sendable {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public struct BaiduOCRLine: Equatable, Sendable {
    public var words: String
    public var rect: CGRect
    public var chars: [BaiduOCRChar]

    public init(words: String, rect: CGRect, chars: [BaiduOCRChar]) {
        self.words = words
        self.rect = rect
        self.chars = chars
    }
}

public struct BaiduOCRPage: Equatable, Sendable {
    public var lines: [BaiduOCRLine]
    /// Each paragraph as the indexes of its lines, in reading order. Empty when the service grouped nothing.
    public var paragraphs: [[Int]]
    /// Which endpoint actually answered. Nil while a page is still being read.
    public var usedPrecision: BaiduOCRPrecision?
    /// True on the one call that found the configured endpoint out of allowance — the moment worth telling the
    /// user about. Later calls use the other endpoint quietly.
    public var fellBack: Bool

    public init(lines: [BaiduOCRLine], paragraphs: [[Int]] = [], usedPrecision: BaiduOCRPrecision? = nil,
                fellBack: Bool = false) {
        self.lines = lines
        self.paragraphs = paragraphs
        self.usedPrecision = usedPrecision
        self.fellBack = fellBack
    }
}

public enum BaiduOCRError: LocalizedError, Equatable {
    case notConfigured
    case token(String)
    case service(code: Int, message: String)
    case badResponse
    case imageTooLarge

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有填写百度 OCR 的 API Key / Secret Key。请在 设置 → 文字识别 里填写。"
        case let .token(message):
            return "百度 OCR 登录失败：\(message)"
        case let .service(code, message):
            return BaiduOCRError.describe(code: code, message: message)
        case .badResponse:
            return "百度 OCR 的回复看不懂，接口可能改了"
        case .imageTooLarge:
            return "这张图太大，百度 OCR 收不了"
        }
    }

    /// Baidu's own codes, in words the user can act on. Anything else keeps the code and the service's message
    /// so it can be looked up — inventing a friendly line for an unknown code would hide the real problem.
    static func describe(code: Int, message: String) -> String {
        switch code {
        case 17: return "百度 OCR 今天的免费次数用完了（错误码 17）"
        case 18: return "百度 OCR 请求太频繁了，稍等一下再试（错误码 18）"
        case 110, 111: return "百度 OCR 的登录凭证失效了，请再试一次（错误码 \(code)）"
        case 6: return "这个百度应用没有文字识别的权限（错误码 6）"
        case 216201: return "图片格式不对（错误码 216201）"
        case 216202: return "图片太大（错误码 216202）"
        case 282000: return "百度服务端出错了，稍后再试（错误码 282000）"
        default: return "百度 OCR 返回错误 \(code)：\(message)"
        }
    }
}

/// Baidu's 通用文字识别（含位置版）: one request per picture, a box per line and per character.
///
/// It is the second engine behind 设置 → 文字识别. Two things it does that Vision does not: it never guesses the
/// script per line (the language is fixed, or detected once for the whole picture), and it reads a whole table
/// in one pass — Vision dropped rows there, which is why 自动识别 had to cut pictures into strips.
public enum BaiduOCR {
    /// Injected by the self-checks so they run without a network. `URLSession.shared` otherwise.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static func recognize(image: CGImage, config: BaiduOCRConfig,
                                 transport: Transport? = nil) async throws -> BaiduOCRPage {
        guard config.isConfigured else { throw BaiduOCRError.notConfigured }
        let send: Transport = transport ?? { try await URLSession.shared.data(for: $0) }
        guard let encoded = BaiduImageEncoder.encode(upscaledForSmallText(image)) else {
            throw BaiduOCRError.imageTooLarge
        }

        // 高精度 and 标准 are two services with two separate allowances: the chosen one running out does not mean
        // the other has, and switching costs the user nothing. The one that is known to be out is skipped for the
        // rest of the session, so only the call that finds out pays for the discovery.
        var failure: BaiduOCRError?
        var discovered = false
        for precision in config.precision.attemptOrder {
            let quotaKey = key(config) + "|" + precision.rawValue
            if await BaiduQuotaStore.shared.isExhausted(quotaKey) { continue }
            do {
                var page = try await recognize(encoded, precision: precision, config: config, send: send)
                page.usedPrecision = precision
                page.fellBack = discovered && precision != config.precision
                return page
            } catch let error as BaiduOCRError {
                // 17 is "this service's allowance is gone". Anything else is a real failure and is not retried
                // against the other service — a bad key or a broken picture fails the same way there.
                guard case let .service(code, _) = error, code == 17 else { throw error }
                failure = error
                if await BaiduQuotaStore.shared.markExhausted(quotaKey), precision == config.precision {
                    discovered = true
                }
            }
        }
        throw failure ?? BaiduOCRError.service(code: 17, message: "")
    }

    /// One precision's worth of work, including the one retry a stale token is worth.
    private static func recognize(_ encoded: BaiduImageEncoder.Encoded, precision: BaiduOCRPrecision,
                                  config: BaiduOCRConfig, send: Transport) async throws -> BaiduOCRPage {
        let token = try await accessToken(config, send: send)
        do {
            return try await sendRecognition(encoded, token: token, precision: precision, config: config, send: send)
        } catch let error as BaiduOCRError {
            // A cached token can expire between two calls (or be revoked from the console). Baidu says so with
            // 110/111; drop it and ask once more with a fresh one.
            guard case let .service(code, _) = error, code == 110 || code == 111 else { throw error }
            await BaiduTokenStore.shared.clear(key(config))
            let fresh = try await accessToken(config, send: send)
            return try await sendRecognition(encoded, token: fresh, precision: precision, config: config, send: send)
        }
    }

    private static func sendRecognition(_ encoded: BaiduImageEncoder.Encoded, token: String,
                                        precision: BaiduOCRPrecision, config: BaiduOCRConfig,
                                        send: Transport) async throws -> BaiduOCRPage {
        let (data, response) = try await send(recognitionRequest(encoded, token: token, precision: precision, config: config))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BaiduOCRError.badResponse
        }
        return try parse(data, width: encoded.width, height: encoded.height)
    }

    /// Baidu's model drops rows when the glyphs are small, exactly as the built-in recognizer does: a 2000×623
    /// email came back missing four of its sixteen lines — the same four Vision lost at that size, and found
    /// again once the picture was enlarged (user, 2026-10). Growing the picture before the upload costs one
    /// resize and no extra request, so there is no quota to weigh: pictures under `targetLongSide` are scaled
    /// towards it (2× at most), bigger ones are sent as they are.
    public static let targetLongSide: CGFloat = 3000

    static func upscaledForSmallText(_ image: CGImage) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        let factor = min(2, targetLongSide / max(longest, 1))
        guard factor > 1.01 else { return image }
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Requests

    /// The token endpoint, documented as plain query parameters. It is HTTPS, and the secret has to go
    /// somewhere — this is the shape Baidu's own examples use.
    static func tokenRequest(_ config: BaiduOCRConfig) -> URLRequest {
        let url = "https://aip.baidubce.com/oauth/2.0/token"
            + "?grant_type=client_credentials"
            + "&client_id=" + percentEncode(config.apiKey)
            + "&client_secret=" + percentEncode(config.secretKey)
        return URLRequest(url: URL(string: url)!, timeoutInterval: 20)
    }

    static func recognitionRequest(_ encoded: BaiduImageEncoder.Encoded, token: String,
                                   precision: BaiduOCRPrecision, config: BaiduOCRConfig) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/\(precision.path)"
            + "?access_token=" + percentEncode(token))!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(imageData: encoded.data, config: config)
        return request
    }

    /// `small` and `paragraph` are always on: the glyph boxes serve a pin's text selection and 自动识别, the
    /// paragraph indexes serve translation — one request covers all of them, and both cost nothing extra.
    static func formBody(imageData: Data, config: BaiduOCRConfig) -> Data {
        var body = "image=" + percentEncode(imageData.base64EncodedString())
        body += "&language_type=" + percentEncode(config.language.rawValue)
        body += "&recognize_granularity=small"
        body += "&paragraph=true"
        return Data(body.utf8)
    }

    /// Escapes everything base64 can contain beyond the unreserved characters (`+`, `/`, `=`); the enum values
    /// (`CHN_ENG`) go through here too and must come out unchanged.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func key(_ config: BaiduOCRConfig) -> String {
        config.apiKey + "|" + config.secretKey
    }

    private static func accessToken(_ config: BaiduOCRConfig, send: Transport) async throws -> String {
        let cacheKey = key(config)
        if let cached = await BaiduTokenStore.shared.token(for: cacheKey) { return cached }
        let (data, response) = try await send(tokenRequest(config))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BaiduOCRError.token("网络请求失败")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(TokenResponse.self, from: data) else {
            throw BaiduOCRError.token("回复看不懂")
        }
        if let token = decoded.accessToken, !token.isEmpty {
            await BaiduTokenStore.shared.store(token, expiresIn: decoded.expiresIn ?? 3600, for: cacheKey)
            return token
        }
        let reason = decoded.errorDescription ?? decoded.error ?? "未知原因"
        // The usual one is a mistyped key, which is worth saying out loud rather than showing `unknown client id`.
        throw BaiduOCRError.token(reason == "unknown client id"
                                  ? "API Key 或 Secret Key 不对，请到设置里重新复制一份"
                                  : reason)
    }

    // MARK: - Parsing

    struct TokenResponse: Decodable {
        var accessToken: String?
        var expiresIn: Int?
        var error: String?
        var errorDescription: String?
    }

    struct Response: Decodable {
        struct Location: Decodable {
            var left: Double
            var top: Double
            var width: Double
            var height: Double
        }

        struct CharBox: Decodable {
            var char: String
            var location: Location?
        }

        struct Word: Decodable {
            var words: String
            var location: Location?
            var chars: [CharBox]?
        }

        struct Paragraph: Decodable {
            var wordsResultIdx: [Int]?
        }

        var errorCode: Int?
        var errorMsg: String?
        var wordsResult: [Word]?
        var paragraphsResult: [Paragraph]?
    }

    /// Turns the reply into boxes in 0…1, top-left origin. `width` / `height` are the pixels of the picture that
    /// was actually sent — it may have been scaled down to fit Baidu's limit, and the caller does not need to
    /// know: normalization is by whatever went over the wire.
    static func parse(_ data: Data, width: Int, height: Int) throws -> BaiduOCRPage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: data) else { throw BaiduOCRError.badResponse }
        if let code = response.errorCode, code != 0 {
            throw BaiduOCRError.service(code: code, message: response.errorMsg ?? "")
        }
        guard width > 0, height > 0 else { throw BaiduOCRError.badResponse }
        func normalized(_ location: Response.Location?) -> CGRect {
            guard let location else { return .zero }
            return CGRect(x: location.left / Double(width), y: location.top / Double(height),
                          width: location.width / Double(width), height: location.height / Double(height))
        }
        let lines = (response.wordsResult ?? []).map { word in
            BaiduOCRLine(words: word.words,
                         rect: normalized(word.location),
                         chars: (word.chars ?? []).map { BaiduOCRChar(text: $0.char, rect: normalized($0.location)) })
        }
        let paragraphs = (response.paragraphsResult ?? []).compactMap { paragraph -> [Int]? in
            guard let indices = paragraph.wordsResultIdx, !indices.isEmpty,
                  indices.allSatisfy({ $0 >= 0 && $0 < lines.count }) else { return nil }
            return indices
        }
        return BaiduOCRPage(lines: lines, paragraphs: paragraphs)
    }
}

/// Access tokens last 30 days; asking for a new one on every screenshot would add a round trip each time.
actor BaiduTokenStore {
    static let shared = BaiduTokenStore()

    private var entries: [String: (token: String, expiry: Date)] = [:]

    func token(for key: String) -> String? {
        guard let entry = entries[key], entry.expiry > Date() else { return nil }
        return entry.token
    }

    /// Drops the token an hour early: a token that expires mid-request is a failure the user cannot do
    /// anything about, and the extra request costs nothing next to that.
    func store(_ token: String, expiresIn: Int, for key: String) {
        let seconds = max(60, expiresIn - 3600)
        entries[key] = (token, Date().addingTimeInterval(TimeInterval(seconds)))
    }

    func clear(_ key: String) { entries[key] = nil }
}

/// Which endpoints this app has been told are out of allowance. In memory only: a restart asks the configured
/// one again, which is right — the allowance may have been topped up since, and a remembered flag would keep the
/// better endpoint switched off for the life of the machine.
actor BaiduQuotaStore {
    static let shared = BaiduQuotaStore()

    private var exhausted: Set<String> = []

    func isExhausted(_ key: String) -> Bool { exhausted.contains(key) }

    /// True when this call is what marked it — the moment worth telling the user about.
    @discardableResult
    func markExhausted(_ key: String) -> Bool { exhausted.insert(key).inserted }
}

/// Puts a picture into what the OCR endpoints accept: PNG or JPEG, at most 4096 px on the long side and a few
/// megabytes. A Retina selection is often both too big and too large a PNG, so the encoder steps down — and the
/// caller normalizes boxes by the size that was actually sent.
public enum BaiduImageEncoder {
    public struct Encoded: Equatable, Sendable {
        public var data: Data
        public var width: Int
        public var height: Int
    }

    static let maxSide = 4096
    /// Raw bytes, before base64 (×1.34) and percent-encoding. Baidu's ceiling is 10 MB for 高精度 and about
    /// 4 MB for 标准; 2.6 MB of pixels stays under both once encoded.
    static let maxBytes = 2_600_000

    public static func encode(_ image: CGImage) -> Encoded? {
        var source = image
        if max(image.width, image.height) > maxSide {
            guard let scaled = resized(image, longSide: maxSide) else { return nil }
            source = scaled
        }
        for attempt in 0..<3 {
            if let png = data(source, type: "public.png"), png.count <= maxBytes {
                return Encoded(data: png, width: source.width, height: source.height)
            }
            if let jpeg = data(source, type: "public.jpeg", quality: 0.9), jpeg.count <= maxBytes {
                return Encoded(data: jpeg, width: source.width, height: source.height)
            }
            guard attempt < 2,
                  let smaller = resized(source, longSide: Int(Double(max(source.width, source.height)) * 0.75))
            else { break }
            source = smaller
        }
        return nil
    }

    static func resized(_ image: CGImage, longSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longSide > 0, longest > 0 else { return nil }
        let scale = Double(longSide) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func data(_ image: CGImage, type: String, quality: Double = 1) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if type == "public.jpeg" { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
