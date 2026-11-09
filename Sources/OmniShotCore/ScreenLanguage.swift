import Foundation

/// Which language the text on a screenshot is mostly written in.
///
/// In-place translation goes the *other* way: a screen full of English is translated into the user's own
/// language, a screen full of Chinese into English. This is only a starting point — the translation bar
/// lets the user flip it when the guess reads the screen wrong.
public enum ScreenLanguage: String, CaseIterable, Sendable {
    case chinese, english, japanese, korean, other

    /// The name shown on the translation bar.
    public var name: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        case .japanese: return "日文"
        case .korean: return "韩文"
        case .other: return "外文"
        }
    }

    /// Whether a screenshot in this language is translated *into* English rather than into the user's own
    /// language. Only Chinese turns the translation around; everything else goes to the target language
    /// from settings.
    public var translatesIntoEnglish: Bool { self == .chinese }

    /// Counts characters by script and takes the winner.
    ///
    /// Two things this leans on. Kana is the only reliable tell for Japanese — a Japanese screen is full of
    /// kanji, which on its own reads as Chinese — so real kana settles it. And only *letters* vote: digits,
    /// punctuation and symbols are shared by every language, so counting "not Chinese" as foreign would let a
    /// column of numbers outvote the words beside it.
    ///
    /// Kana and hangul have to be a *share* of the page, not merely present. An English screenshot with one
    /// glyph the recogniser turned into「の」— which happened, and the whole page came out as Japanese — used to
    /// flip the language on a single character; Japanese and Korean text is a quarter kana or hangul, never one
    /// stray one.
    ///
    /// A tie between Chinese and Latin comes back `.other`, which translates into the user's own language —
    /// the behaviour the app had before it could turn around, and one click to change.
    public static func detect(in texts: [String]) -> ScreenLanguage {
        var chinese = 0, latin = 0, kana = 0, hangul = 0
        for scalar in texts.joined().unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: chinese += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        let letters = chinese + latin + kana + hangul
        if kana >= 2, kana * 10 >= letters { return .japanese }
        if hangul >= 2, hangul * 10 >= letters, hangul > chinese { return .korean }
        if chinese > latin { return .chinese }
        if latin > chinese { return .english }
        return .other
    }
}

/// Which way a translation goes: what the text turned out to be, and whether the user has overruled the guess.
///
/// Both translation paths work the same way — 截图翻译 reads it off the picture, 输入翻译 reads it off what was
/// pasted — and both let the user flip the answer when it reads wrong. Keeping the rule here means the two
/// cannot drift apart, and the naming (「中文 → English」) is one thing rather than two.
public struct TranslationDirection: Equatable, Sendable {
    public let detected: ScreenLanguage
    /// The user said the guess was wrong; the direction is the other way until the text changes.
    public let flipped: Bool

    public init(detected: ScreenLanguage, flipped: Bool = false) {
        self.detected = detected
        self.flipped = flipped
    }

    /// True when the translation goes into English instead of into the user's own language.
    public var translatesIntoEnglish: Bool { detected.translatesIntoEnglish != flipped }

    /// The language being translated *from*, which is what decides which blocks are worth sending.
    public var source: ScreenLanguage {
        if translatesIntoEnglish { return .chinese }
        // Overruled on a Chinese screen: the user is saying "take it as the foreign language after all".
        return detected == .chinese ? .english : detected
    }

    /// The name for the left end of the control. When the direction contradicts what was detected, the user
    /// has just overruled the guess and this side flips to the other language — the point of pressing it.
    public var sourceName: String {
        if translatesIntoEnglish { return "中文" }
        return detected == .chinese ? "英文" : detected.name
    }

    /// The name for the right end. `settingsTarget` is the app's 「默认翻译为」, which is where everything that
    /// is not Chinese goes.
    public func targetName(settingsTarget: String) -> String {
        translatesIntoEnglish ? "English" : settingsTarget
    }
}
