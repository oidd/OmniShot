import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OmniShotCore

/// Renders one line of text at `size` points on a flat background at 2x, and returns the buffer together
/// with the line box an OCR would report for it — both in the buffer's pixels. `extra` draws whatever else
/// the fixture needs, in points.
func renderedText(_ text: String, size: CGFloat, font: String = "Helvetica", color: CGColor = .black,
                  on background: CGColor = .white, extra: (CGContext) -> Void = { _ in }) -> (buffer: PixelBuffer, lines: [OCRLine]) {
    let width: CGFloat = 600, height: CGFloat = 100, scale: CGFloat = 2
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1) // top-left origin in points, like PixelBuffer
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let ctFont = CTFontCreateWithName(font as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let baseline: CGFloat = 60
    ctx.textMatrix = .identity
    ctx.translateBy(x: 20, y: baseline)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    extra(ctx)

    let ascent = CTFontGetAscent(ctFont), descent = CTFontGetDescent(ctFont)
    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let box = CGRect(x: 20 * scale, y: (baseline - ascent) * scale, width: lineWidth * scale, height: (ascent + descent) * scale)
    return (PixelBuffer(image: ctx.makeImage()!)!, [OCRLine(text: text, rect: box)])
}

/// A paragraph of `texts`, one line each, `pitch` points apart — the shape of most real screenshots.
func renderedParagraph(_ texts: [String], size: CGFloat, pitch: CGFloat = 22, font: String = "Helvetica",
                       color: CGColor = .black) -> (buffer: PixelBuffer, lines: [OCRLine]) {
    let width: CGFloat = 900, height: CGFloat = 60 + pitch * CGFloat(texts.count), scale: CGFloat = 2
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let ctFont = CTFontCreateWithName(font as CFString, size, nil)
    let ascent = CTFontGetAscent(ctFont), descent = CTFontGetDescent(ctFont)
    var lines: [OCRLine] = []
    for (index, text) in texts.enumerated() {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let baseline = 40 + CGFloat(index) * pitch
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 40, y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        lines.append(OCRLine(text: text, rect: CGRect(x: 40 * scale, y: (baseline - ascent) * scale,
                                                      width: lineWidth * scale, height: (ascent + descent) * scale)))
    }
    return (PixelBuffer(image: ctx.makeImage()!)!, lines)
}

@Suite struct GeometryTests {
    @Test func visionBoxFlipsToTopLeftOrigin() {
        // A box in the top-left quarter of the image in Vision space (origin bottom-left).
        let box = CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        let selection = CGRect(x: 100, y: 200, width: 400, height: 200)
        #expect(VisionGeometry.rect(fromNormalized: box, in: selection) == CGRect(x: 100, y: 200, width: 200, height: 100))
    }

    @Test func visionBoxAtBottom() {
        let box = CGRect(x: 0.25, y: 0, width: 0.5, height: 0.1)
        let r = VisionGeometry.rect(fromNormalized: box, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(abs(r.minY - 90) < 0.0001)
        #expect(abs(r.minX - 25) < 0.0001)
    }
}

@Suite struct BlockTests {
    func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 200, h: CGFloat = 14) -> OCRLine {
        OCRLine(text: text, rect: CGRect(x: x, y: y, width: w, height: h))
    }

    @Test func mergesWrappedParagraph() {
        let blocks = TextBlockBuilder.group([
            line("Settings", x: 10, y: 10, w: 60, h: 18),
            line("Automatically check for updates", x: 10, y: 50),
            line("and download them in the background.", x: 10, y: 68),
            line("Save to: ~/Pictures/OmniShot", x: 10, y: 120),
        ])
        #expect(blocks.count == 3)
        #expect(blocks[1].text == "Automatically check for updates and download them in the background.")
        #expect(blocks[1].rect == CGRect(x: 10, y: 50, width: 200, height: 32))
    }

    @Test func keepsSideBySideColumnsApart() {
        let blocks = TextBlockBuilder.group([
            line("Name", x: 10, y: 10, w: 40),
            line("Value", x: 300, y: 10, w: 40),
            line("Other", x: 10, y: 28, w: 40),
        ])
        #expect(blocks.count == 2)
        #expect(blocks.map(\.text).contains("Name Other"))
        #expect(blocks.map(\.text).contains("Value"))
    }

    @Test func doesNotMergeHeadingIntoBody() {
        let blocks = TextBlockBuilder.group([
            line("Big Title", x: 10, y: 10, h: 30),
            line("body text", x: 10, y: 44, h: 14),
        ])
        #expect(blocks.count == 2)
    }

    @Test func joinsHyphenatedWords() {
        let block = TextBlock(id: 0, lines: [line("inter-", x: 0, y: 0), line("national trade", x: 0, y: 16)])
        #expect(block.text == "international trade")
    }

    /// 驼峰和数字连字符也要拼上（docling 那两条）：`Table-Former` 是一个词，`545-` + `561` 是一个数。
    @Test func joinsCamelCaseAndNumberHyphens() {
        #expect(TextBlock(id: 0, lines: [line("Table-", x: 0, y: 0), line("Former models", x: 0, y: 16)]).text
                == "TableFormer models")
        #expect(TextBlock(id: 0, lines: [line("545-", x: 0, y: 0), line("561 号", x: 0, y: 16)]).text == "545561 号")
    }

    /// 中文两行之间不插空格：以前一律插，把「自动检查更新」「保存到下载」拼成中间带空格的。
    @Test func chineseLinesJoinWithoutSpaces() {
        let block = TextBlock(id: 0, lines: [line("自动检查更新", x: 0, y: 0), line("和下载", x: 0, y: 16)])
        #expect(block.text == "自动检查更新和下载")
        // 中英之间照旧留一个空格。
        let mixed = TextBlock(id: 0, lines: [line("打开", x: 0, y: 0), line("OmniShot 的设置", x: 0, y: 16)])
        #expect(mixed.text == "打开 OmniShot 的设置")
    }

    /// 列表的续行是缩进的：左边缘不齐也要并（用户报过 "endpoint" 被单独拆成一段）。
    @Test func keepsListContinuationsWithTheirItem() {
        let blocks = TextBlockBuilder.group([
            line("1. Identify endpoint references: Locate all instances of gemini-omni-", x: 10, y: 10, w: 380),
            line("flash-preview within your codebase and configuration files", x: 24, y: 28, w: 340),
            line("2. Update API endpoints: Update your API requests to point to", x: 10, y: 52, w: 380),
            line("gemini-1.1-flash-preview", x: 24, y: 70, w: 160),
        ])
        #expect(blocks.count == 2)
        #expect(blocks[0].text == "1. Identify endpoint references: Locate all instances of gemini-omniflash-preview within your codebase and configuration files")
        #expect(blocks[1].text == "2. Update API endpoints: Update your API requests to point to gemini-1.1-flash-preview")
    }

    /// 缩进的续行 + 句子没说完 → 并（第 5 条规则，不靠"顶到版心"）。
    @Test func mergesAnIndentedContinuationOfAnUnfinishedSentence() {
        let blocks = TextBlockBuilder.group([
            line("3. Validate integrations: Test and verify application performance on the new", x: 10, y: 10, w: 380),
            line("endpoint", x: 24, y: 28, w: 60),
        ])
        #expect(blocks.count == 1)
        #expect(blocks[0].text.hasSuffix("the new endpoint"))
    }

    /// 上一行顶到版心（下一行的首词放不下）→ 被截断，缩进多少都是续行（Tesseract 的 FirstWordWouldHaveFit）。
    @Test func aLineThatRanToTheMarginIsContinued() {
        var continuation = line("endpoint", x: 90, y: 28, w: 70)
        continuation.firstWordWidth = 70
        let blocks = TextBlockBuilder.group([
            line("3. Validate integrations: Test and verify application on the new", x: 10, y: 10, w: 380),
            continuation,
        ])
        #expect(blocks.count == 1)
    }

    /// 反过来：上一行明显没写满，首词放得下 → 那是主动换行，不是被挤下来的。
    @Test func aShortLineEndsTheParagraph() {
        var next = line("far away", x: 90, y: 28, w: 70)
        next.firstWordWidth = 30
        let blocks = TextBlockBuilder.group([
            line("Kind of short", x: 10, y: 10, w: 100),
            next,
        ])
        #expect(blocks.count == 2)
    }

    /// 相邻的两条编号项不能并成一段——今天会错并（行高一样、左边缘齐平、行距又紧）。
    @Test func keepsNumberedItemsApart() {
        let blocks = TextBlockBuilder.group([
            line("3. 将光标悬停在看板名称上，以显示右侧的垂直点。", x: 10, y: 10, w: 300),
            line("4. 点击这三个点，选择下载为 PNG。", x: 10, y: 28, w: 300),
            line("• 圆点第一条", x: 10, y: 46, w: 200),
            line("• 圆点第二条", x: 10, y: 64, w: 200),
        ])
        #expect(blocks.count == 4)
    }

    /// 真正的首行缩进（缩进一大截）+ 上一行已经句末 → 新段落。
    @Test func doesNotMergeAnIndentedNewParagraph() {
        let blocks = TextBlockBuilder.group([
            line("The setting is on by default.", x: 10, y: 10, w: 200),
            line("Indented far enough to be a new paragraph.", x: 48, y: 28, w: 200),
        ])
        #expect(blocks.count == 2)
    }

    /// 小数不是列表标记：`1.5 GHz` 打头的行不能因此切断上一段。
    @Test func aDecimalIsNotAListMarker() {
        #expect(!TextBlockBuilder.startsListItem("1.5 GHz is the base clock"))
        #expect(TextBlockBuilder.startsListItem("1. Open the settings"))
        #expect(TextBlockBuilder.startsListItem("(2) 点击这里"))
        #expect(TextBlockBuilder.startsListItem("• 支持长截图"))
        #expect(TextBlockBuilder.startsListItem("第 3 条 说明"))
        #expect(!TextBlockBuilder.startsListItem("2024 年的更新"))
    }

    /// 冒号/分号不算句子结束（列表项常在冒号后断行）；句末的引号、括号要看得穿。
    @Test func sentenceEndings() {
        #expect(!TextBlockBuilder.endsSentence("1. Identify endpoint references:"))
        #expect(!TextBlockBuilder.endsSentence("这是一句没说完的话，"))
        #expect(TextBlockBuilder.endsSentence("选择 “Download as PNG”。"))
        #expect(TextBlockBuilder.endsSentence("Done."))
    }

    // MARK: - 第二版：把估算换成实测

    /// 容差的单位是**量出来的**词间距：同一个 5pt 缩进，这一页词距宽时算齐头，词距窄时不算。
    @Test func theFlushToleranceFollowsTheMeasuredSpace() {
        func grouped(space: CGFloat) -> Int {
            func measured(_ l: OCRLine) -> OCRLine {
                var copy = l
                copy.wordGap = space
                return copy
            }
            return TextBlockBuilder.group([
                measured(line("The setting is on by default.", x: 10, y: 10, w: 200)),
                measured(line("Indented by five points.", x: 15, y: 28, w: 200)),
            ]).count
        }
        #expect(grouped(space: 12) == 1, "词距 12 → 容差 9.6pt，5pt 的缩进算齐头")
        #expect(grouped(space: 4) == 2, "词距 4 → 容差 3.2pt，就不算了（上一行已句末，不走缩进那几条）")
    }

    /// 行距是拿**这一页自己的**行距比的，不是死板的 0.8 倍行高：1.8 倍行距的正文也要能并成一段。
    @Test func airyLeadingStillFormsOneParagraph() {
        let airy = TextBlockBuilder.group([
            line("Airy paragraph first line", x: 10, y: 10, w: 300),
            line("Airy paragraph second line", x: 10, y: 38, w: 300),
            line("Airy paragraph third line", x: 10, y: 66, w: 300),
        ])
        #expect(airy.count == 1, "行高 14、墨迹间隙 14——旧的 0.8 倍行高会切成三段")
        // 段落之间的间距比这更大，仍然要断开。
        let broken = TextBlockBuilder.group([
            line("Airy paragraph first line", x: 10, y: 10, w: 300),
            line("Airy paragraph second line", x: 10, y: 38, w: 300),
            line("A new paragraph after a much bigger gap.", x: 10, y: 90, w: 300),
        ])
        #expect(broken.count == 2)
    }

    /// 列右边界取上四分位，不是最大值：一条特别宽的行不该把整列的边界抬高。
    @Test func theColumnRightEdgeIgnoresOneOutlier() {
        let lines = [line("a", x: 0, y: 0, w: 100), line("b", x: 0, y: 20, w: 100),
                     line("c", x: 0, y: 40, w: 100), line("d", x: 0, y: 60, w: 100),
                     line("a very wide line", x: 0, y: 80, w: 400)]
        let metrics = TextBlockBuilder.PageMetrics(lines)
        #expect(metrics.columnRight(of: 0) == 100, "普通行按其余行的上四分位算（\(metrics.columnRight(of: 0))）")
        #expect(metrics.columnRight(of: 4) == 400, "宽行自己还是以自己为准")
    }

    /// 英文里「上一行没句号 + 下一行小写开头」是续行的强证据，缩进大一点也认；大写开头就不认了。
    @Test func aLowercaseContinuationIsBelieved() {
        var lower = line("the rest of the sentence carries on", x: 43, y: 28, w: 200)
        lower.wordGap = 4
        var upper = line("First part of the sentence and", x: 10, y: 10, w: 300)
        upper.wordGap = 4
        #expect(TextBlockBuilder.group([upper, lower]).count == 1, "33pt 缩进，但句子没说完、下一行小写")
        var capital = line("The rest of the sentence carries on", x: 43, y: 28, w: 200)
        capital.wordGap = 4
        #expect(TextBlockBuilder.group([upper, capital]).count == 2, "大写开头 + 大缩进 = 新段落")
    }

    /// 列表项的续行按**量出来的标记宽度**对齐，不是固定 1.6 em 的估。
    @Test func aListItemsContinuationIsMeasuredFromItsMarker() {
        var first = line("10. Install the app and open it once so the menu", x: 10, y: 10, w: 380)
        first.firstWordWidth = 30
        let continuation = line("Icon appears in the menu bar bar", x: 44, y: 28, w: 200) // 大写开头，34pt 缩进
        #expect(TextBlockBuilder.group([first, continuation]).count == 1, "缩进正好是标记宽 + 一个空格")
        var unmeasured = first
        unmeasured.firstWordWidth = nil
        #expect(TextBlockBuilder.group([unmeasured, continuation]).count == 2, "量不到标记宽度时不敢这么并")
    }

    /// 学到的正文缩进按 2 个实测空格判：差得太多就不再往这一段里塞。
    @Test func aLearnedBodyIndentIsMatchedWithinTwoSpaces() {
        func grouped(space: CGFloat) -> Int {
            func measured(_ l: OCRLine) -> OCRLine {
                var copy = l
                copy.wordGap = space
                return copy
            }
            return TextBlockBuilder.group([
                measured(line("A paragraph whose first line runs to the", x: 10, y: 10, w: 300)),
                measured(line("edge and goes on a little", x: 30, y: 28, w: 300)),
                measured(line("And then further in than that.", x: 40, y: 46, w: 300)),
            ]).count
        }
        #expect(grouped(space: 8) == 1, "词距 8 → 容差 16pt，40 和学到的 30 差 10 还能跟")
        #expect(grouped(space: 3) == 2, "词距 3 → 容差 6pt，差 10 就不跟了")
    }

    @Test func translationFilter() {
        #expect(TextBlockBuilder.shouldTranslate("Check for updates"))
        #expect(TextBlockBuilder.shouldTranslate("Version 2.6.8"))
        #expect(!TextBlockBuilder.shouldTranslate("2.6.8"))
        #expect(!TextBlockBuilder.shouldTranslate("https://api.deepseek.com/v1"))
        #expect(!TextBlockBuilder.shouldTranslate("~/Pictures/OmniShot"))
        #expect(!TextBlockBuilder.shouldTranslate("自动检查更新 OK"))
        #expect(!TextBlockBuilder.shouldTranslate("42"))
        #expect(!TextBlockBuilder.shouldTranslate("dev@example.com"))
    }

    @Test func translationFilterTurnsAroundForChinese() {
        // Normally the foreign text is what gets sent...
        #expect(TextBlockBuilder.shouldTranslate("Check for updates", from: .english))
        #expect(!TextBlockBuilder.shouldTranslate("自动检查更新", from: .english))
        // ...and on a Chinese screen it is the Chinese text.
        #expect(TextBlockBuilder.shouldTranslate("自动检查更新", from: .chinese))
        #expect(!TextBlockBuilder.shouldTranslate("Check for updates", from: .chinese))
        // A Chinese line keeps its product name; a URL or a bare number is skipped either way.
        #expect(TextBlockBuilder.shouldTranslate("打开 OmniShot 的设置", from: .chinese))
        #expect(!TextBlockBuilder.shouldTranslate("https://omnishot.example/app", from: .chinese))
        #expect(!TextBlockBuilder.shouldTranslate("12345", from: .chinese))
    }

    /// 日文和韩文屏幕：`ScreenLanguage.detect` 认得出这两种语言，方向条也写着「日文 → 简体中文」，所以
    /// 送出去的筛子必须跟着认——早先它们落进拉丁那条分支，一屏假名一个块都过不去，截图翻译在日文屏幕上
    /// 永远说「没有找到需要翻译的外文」。
    @Test func translationFilterKnowsJapaneseAndKorean() {
        #expect(TextBlockBuilder.shouldTranslate("設定を開く", from: .japanese))
        #expect(TextBlockBuilder.shouldTranslate("アップデートを確認します", from: .japanese))
        #expect(TextBlockBuilder.shouldTranslate("설정 열기", from: .korean))
        #expect(TextBlockBuilder.shouldTranslate("업데이트 확인", from: .korean))
        // 日文屏幕上的英文行、纯数字、网址，一样不该送出去。
        #expect(!TextBlockBuilder.shouldTranslate("Check for updates", from: .japanese))
        #expect(!TextBlockBuilder.shouldTranslate("12345", from: .japanese))
        #expect(!TextBlockBuilder.shouldTranslate("https://omnishot.example/app", from: .korean))
    }
}

@Suite struct ScreenLanguageTests {
    @Test func readsTheDominantLanguage() {
        #expect(ScreenLanguage.detect(in: ["Automatically check for updates", "Save to Downloads"]) == .english)
        #expect(ScreenLanguage.detect(in: ["自动检查更新", "保存到下载文件夹"]) == .chinese)
        #expect(ScreenLanguage.detect(in: ["設定を開く", "アップデートを確認します"]) == .japanese)
        #expect(ScreenLanguage.detect(in: ["설정 열기", "업데이트 확인"]) == .korean)
    }

    @Test func onlyLettersVote() {
        // Digits and punctuation are shared by every language, so a column of numbers must not outvote the
        // words beside it.
        #expect(ScreenLanguage.detect(in: ["2026 1 2 3 4 5 6 7 8 9 0", "Settings"]) == .english)
        // And a product name in Latin does not make a Chinese screen English.
        #expect(ScreenLanguage.detect(in: ["自动检查更新 OmniShot 的设置项", "打开菜单栏图标"]) == .chinese)
    }

    @Test func kanaTellsJapaneseFromChinese() {
        // Kanji on its own reads as Chinese — the kana is what settles it.
        #expect(ScreenLanguage.detect(in: ["設定"]) == .chinese)
        #expect(ScreenLanguage.detect(in: ["設定する"]) == .japanese)
    }

    /// 一屏英文里混进一个被认错的假名，整页就被判成日文——用户 2026-10 报的就是这个。假名和谚文必须是
    /// 页面上**有份量**的一类字，不是「出现过」。
    @Test func oneStrayKanaDoesNotMakeAPageJapanese() {
        #expect(ScreenLanguage.detect(in: ["Advanced", "Automatically update Dia", "の"]) == .english)
        #expect(ScreenLanguage.detect(in: ["Advanced", "Automatically update Dia", "ののの"]) == .english)
        #expect(ScreenLanguage.detect(in: ["Advanced", "Automatically update Dia", "Warn before quitting", "설정"]) == .english)
        // 反过来，真正以假名为主的页面照样认得出。
        #expect(ScreenLanguage.detect(in: ["Advanced", "設定を開く", "アップデートを確認します"]) == .japanese)
    }

    @Test func anEvenSplitAndNoTextStayWithTheUsersLanguage() {
        #expect(ScreenLanguage.detect(in: []) == .other)
        #expect(ScreenLanguage.detect(in: ["中文", "ab"]) == .other)
        #expect(!ScreenLanguage.other.translatesIntoEnglish)
        #expect(!ScreenLanguage.english.translatesIntoEnglish)
        #expect(ScreenLanguage.chinese.translatesIntoEnglish)
    }
}

@Suite struct TranslationDirectionTests {
    @Test func followsTheGuessUntilItIsOverruled() {
        // 英文屏幕：译成设置里那门语言。
        let english = TranslationDirection(detected: .english)
        #expect(!english.translatesIntoEnglish)
        #expect(english.source == .english)
        #expect(english.sourceName == "英文")
        #expect(english.targetName(settingsTarget: "简体中文") == "简体中文")

        // 中文屏幕：反过来，译成英文。
        let chinese = TranslationDirection(detected: .chinese)
        #expect(chinese.translatesIntoEnglish)
        #expect(chinese.source == .chinese)
        #expect(chinese.sourceName == "中文")
        #expect(chinese.targetName(settingsTarget: "简体中文") == "English")
    }

    @Test func theFlipTakesTheOtherWay() {
        // 中文屏幕被判错了：当作外文，译成设置里那门语言，名字也要跟着反过来。
        let overruled = TranslationDirection(detected: .chinese, flipped: true)
        #expect(!overruled.translatesIntoEnglish)
        #expect(overruled.source == .english)
        #expect(overruled.sourceName == "英文")
        #expect(overruled.targetName(settingsTarget: "简体中文") == "简体中文")

        // 反过来也一样：英文屏幕被推翻，就是当作中文处理。
        let other = TranslationDirection(detected: .english, flipped: true)
        #expect(other.translatesIntoEnglish)
        #expect(other.source == .chinese)
        #expect(other.sourceName == "中文")
        #expect(other.targetName(settingsTarget: "简体中文") == "English")
    }

    @Test func everyOtherLanguageGoesToTheUsersOwn() {
        for language in [ScreenLanguage.japanese, .korean, .other] {
            let direction = TranslationDirection(detected: language)
            #expect(!direction.translatesIntoEnglish)
            #expect(direction.sourceName == language.name)
            #expect(direction.targetName(settingsTarget: "简体中文") == "简体中文")
        }
    }
}

@Suite struct ColorTests {
    /// 20×10 white image with a black 10×4 bar in the middle standing in for text.
    func sampleBuffer() -> PixelBuffer {
        let w = 20, h = 10
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 3..<7 {
            for x in 5..<15 {
                let i = (y * w + x) * 4
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
            }
        }
        return PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data)
    }

    @Test func picksBackgroundAndInk() {
        let metrics = InkReader.measure(sampleBuffer(), lines: [OCRLine(text: "Hamburgefonstiv", rect: CGRect(x: 4, y: 2, width: 12, height: 6))])
        #expect(metrics.background == .white)
        #expect(metrics.foreground == .black)
        #expect(metrics.backgroundIsSolid)
    }

    /// 40×10 white image with a blue "button" from x=10 to x=30 and white text inside it.
    func buttonBuffer(textFrom: Int, to: Int) -> PixelBuffer {
        let w = 40, h = 10
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 10..<30 {
                let i = (y * w + x) * 4
                let isText = x >= textFrom && x < to && y >= 3 && y < 7 && x % 2 == 0
                data[i] = isText ? 255 : 40; data[i + 1] = isText ? 255 : 120; data[i + 2] = isText ? 255 : 240
            }
        }
        return PixelBuffer(width: w, height: h, bytesPerRow: w * 4, data: data)
    }

    @Test func detectsTextCenteredInContainer() {
        let metrics = InkReader.measure(buttonBuffer(textFrom: 16, to: 24), lines: [OCRLine(text: "OK", rect: CGRect(x: 16, y: 3, width: 8, height: 4))])
        #expect(metrics.leftMargin == 6)
        #expect(metrics.rightMargin == 6)
        #expect(metrics.isCentered)
    }

    @Test func leftAlignedTextIsNotCentered() {
        let metrics = InkReader.measure(buttonBuffer(textFrom: 11, to: 17), lines: [OCRLine(text: "OK", rect: CGRect(x: 11, y: 3, width: 6, height: 4))])
        #expect(!metrics.isCentered)
    }

    @Test func backgroundRunningToImageEdgeHasNoMargin() {
        let metrics = InkReader.measure(sampleBuffer(), lines: [OCRLine(text: "Hamburgefonstiv", rect: CGRect(x: 4, y: 2, width: 12, height: 6))])
        #expect(metrics.leftMargin == nil)
        #expect(metrics.rightMargin == nil)
        #expect(!metrics.isCentered)
    }

    @Test func rendersCGImageIntoBuffer() throws {
        let ctx = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 1, width: 4, height: 1)) // top row in CG's bottom-left space
        let image = try #require(ctx.makeImage())
        let buffer = try #require(PixelBuffer(image: image))
        #expect(buffer.pixel(x: 0, y: 0).r == 255)
        #expect(buffer.pixel(x: 0, y: 1).r == 0)
    }
}

/// The measurements that make a translation look like it belongs in the original.
@Suite struct InkMetricsTests {
    /// 16 pt at 2x is 32 px of ink: the whole point of measuring ink instead of the line box.
    @Test func measuresFontSizeFromTheInk() throws {
        let image = renderedText("Hamburgefonstiv 123", size: 16)
        let metrics = InkReader.measure(image.buffer, lines: image.lines)
        let size = try #require(metrics.fontSize)
        #expect(abs(size / 32 - 1) < 0.1, "measured \(size) px")
    }

    /// A line without ascenders is only x-height tall: reading it as cap height would make the font too small.
    @Test func xHeightOnlyTextUsesTheXHeightRatio() throws {
        let image = renderedText("acenorsuvw", size: 16)
        let metrics = InkReader.measure(image.buffer, lines: image.lines)
        let size = try #require(metrics.fontSize)
        #expect(abs(size / 32 - 1) < 0.12, "measured \(size) px")
    }

    @Test func cjkMeasuresItsGlyphBody() throws {
        let image = renderedText("截图翻译工具", size: 16, font: "PingFangSC-Regular")
        let metrics = InkReader.measure(image.buffer, lines: image.lines)
        let size = try #require(metrics.fontSize)
        #expect(abs(size / 32 - 1) < 0.15, "measured \(size) px")
    }

    /// Calibrates the bold rule against the table it was measured from: regular faces land below the
    /// threshold, semibold and bold ones above it. This is what keeps a translation in the weight of the
    /// text it replaces — comparing against the line box instead, every weight looks the same.
    @Test func boldStemsAreToldApartFromRegular() {
        let cases: [(font: String, size: CGFloat, text: String, bold: Bool)] = [
            ("Helvetica", 16, "Hamburgefonstiv", false), ("Helvetica", 24, "Hamburgefonstiv", false),
            ("Georgia", 16, "Hamburgefonstiv", false),
            ("Helvetica-Bold", 16, "Hamburgefonstiv", true), ("Helvetica-Bold", 24, "Hamburgefonstiv", true),
            ("Georgia-Bold", 16, "Hamburgefonstiv", true),
            // Documented limitation: a CJK semibold only measures a hair above a CJK regular, so it stays
            // regular rather than risk making plain Chinese body text bold.
            ("PingFangSC-Regular", 16, "截图翻译工具", false), ("PingFangSC-Semibold", 16, "截图翻译工具", false),
        ]
        for testCase in cases {
            let image = renderedText(testCase.text, size: testCase.size, font: testCase.font)
            let metrics = InkReader.measure(image.buffer, lines: image.lines)
            let ratio = (metrics.strokeWidth - 0.1) / (testCase.size * 2)
            #expect(metrics.isBold == testCase.bold,
                    "\(testCase.font) \(testCase.size) pt: stroke \(metrics.strokeWidth) px, ratio \(ratio)")
        }
    }

    /// The regression that made a real email screenshot come out three times too big: measuring a paragraph
    /// as one block bridges the gaps between its lines and reads the whole thing as a single huge line.
    @Test func paragraphsAreMeasuredLineByLine() throws {
        let paragraph = renderedParagraph(["Kilo is a community supporter of All Day AI, a free online event",
                                           "on October 22 that will span 15 hours and 122 speakers across the",
                                           "top AI companies."], size: 16)
        let metrics = InkReader.measure(paragraph.buffer, lines: paragraph.lines)
        let size = try #require(metrics.fontSize)
        #expect(abs(size / 32 - 1) < 0.1, "measured \(size) px for a 3-line paragraph at 16 pt")
    }

    @Test func scriptOfText() {
        #expect(TextScript.of("Settings") == .latin)
        #expect(TextScript.of("截图翻译") == .cjk)
        #expect(TextScript.of("設定を開く") == .cjk)
        #expect(TextScript.of("スクリーンショット") == .kana)
    }

    /// The median of the strongest pixels is the text's own color; averaging the top slice would drag it
    /// toward the background through the anti-aliased edges and make the translation look washed out.
    @Test func inkColorComesFromTheStrongestPixels() throws {
        let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let image = renderedText("Hamburgefonstiv", size: 16, color: gray)
        let metrics = InkReader.measure(image.buffer, lines: image.lines)
        #expect(abs(Int(metrics.foreground.r) - 128) < 12, "foreground \(metrics.foreground)")
        #expect(abs(Int(metrics.foreground.g) - 128) < 12)
    }

    /// A table border right beside the text is not ink: without the rule filter the black column would be
    /// the strongest pixel on the line and set the translation's color.
    @Test func verticalRulesAreNotInk() throws {
        let gray = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let image = renderedText("Name", size: 16, color: gray) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 58, y: 30, width: 5, height: 70)) // in points, just right of "Name"
        }
        let metrics = InkReader.measure(image.buffer, lines: [OCRLine(text: "Name", rect: CGRect(x: 40, y: 80, width: 100, height: 60))])
        #expect(abs(Int(metrics.foreground.r) - 128) < 25, "the border set the ink color: \(metrics.foreground)")
    }

    @Test func backgroundUnderAPhotoIsNotSolid() {
        var data = [UInt8](repeating: 255, count: 200 * 40 * 4)
        for y in 0..<40 {
            for x in 0..<200 {
                let i = (y * 200 + x) * 4
                data[i] = UInt8(x * 255 / 200); data[i + 1] = UInt8(y * 255 / 40); data[i + 2] = 90
            }
        }
        let buffer = PixelBuffer(width: 200, height: 40, bytesPerRow: 200 * 4, data: data)
        let metrics = InkReader.measure(buffer, lines: [OCRLine(text: "Hamburgefonstiv", rect: CGRect(x: 20, y: 10, width: 120, height: 20))])
        #expect(!metrics.backgroundIsSolid)
    }

    @Test func blankSpaceIsToldApartFromInk() {
        let image = renderedText("Hamburgefonstiv", size: 16)
        #expect(InkReader.isBlank(image.buffer, rect: CGRect(x: 40, y: 160, width: 400, height: 30), background: .white))
        #expect(!InkReader.isBlank(image.buffer, rect: CGRect(x: 40, y: 90, width: 400, height: 30), background: .white))
    }
}

@Suite struct ContrastTests {
    /// White text on a green button must stay white: a plain "pick black or white" rule turns it black.
    @Test func keepsTheLightDarkDirection() {
        let green = RGBA(r: 40, g: 160, b: 90)
        let adjusted = RGBA.white.ensuringContrast(3, against: green)
        #expect(adjusted.r > 200 && adjusted.g > 200 && adjusted.b > 200, "turned into \(adjusted)")
        #expect(adjusted.contrastRatio(with: green) >= 3)
    }

    /// Low-contrast gray text is darkened toward black, never flipped toward white.
    @Test func darkensInsteadOfFlipping() {
        let gray = RGBA(r: 150, g: 150, b: 150)
        let adjusted = gray.ensuringContrast(4.5, against: .white)
        #expect(adjusted.r < 150, "became \(adjusted)")
        #expect(adjusted.contrastRatio(with: .white) >= 4.5)
    }

    @Test func leavesReadableColorsAlone() {
        #expect(RGBA.black.ensuringContrast(3, against: .white) == .black)
        #expect(RGBA.white.ensuringContrast(3, against: RGBA(r: 20, g: 20, b: 20)) == .white)
    }

    /// When even black cannot reach the target on a pale background, black is still the best answer.
    @Test func fallsBackToTheNearestEndpoint() {
        let veryPale = RGBA(r: 250, g: 250, b: 250)
        #expect(RGBA(r: 200, g: 200, b: 200).ensuringContrast(21, against: veryPale) == .black)
    }
}


@Suite struct TranslatorTests {
    let config = TranslationConfig(baseURL: "https://api.deepseek.com/", model: "deepseek-flash",
                                   apiKey: "sk-test", targetLanguage: "简体中文")

    @Test func buildsChatCompletionRequest() throws {
        let request = try ChatTranslator.makeRequest(items: [.init(id: 0, text: "Settings")], config: config)
        #expect(request.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-flash")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[1]["content"] == #"{"items":[{"id":0,"text":"Settings"}]}"#)
    }

    @Test func rejectsMissingKey() {
        var c = config
        c.apiKey = " "
        #expect(throws: TranslationError.missingAPIKey) {
            try ChatTranslator.makeRequest(items: [.init(id: 0, text: "x")], config: c)
        }
    }

    @Test func parsesResponseWithFenceAndStringIDs() throws {
        let content = "```json\n{\"items\":[{\"id\":\"0\",\"t\":\"设置\"},{\"id\":1,\"zh\":\"保存\"}]}\n```"
        let response: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        let result = try ChatTranslator.parseResponse(try JSONSerialization.data(withJSONObject: response))
        #expect(result == [0: "设置", 1: "保存"])
    }

    @Test func badContentThrows() {
        let response: [String: Any] = ["choices": [["message": ["content": "not json"]]]]
        #expect(throws: TranslationError.self) {
            try ChatTranslator.parseResponse(try JSONSerialization.data(withJSONObject: response))
        }
    }

    @Test func cacheSendsOnlyMissingTexts() async throws {
        let cache = TranslationCache()
        cache.set("设置", for: "Settings", config: config)
        var sent: [String] = []
        let result = try await cache.translate([.init(id: 0, text: "Settings"), .init(id: 1, text: "Save")], config: config) { items in
            sent = items.map(\.text)
            return [1: "保存"]
        }
        #expect(sent == ["Save"])
        #expect(result == [0: "设置", 1: "保存"])
        #expect(cache.get("Save", config: config) == "保存")
    }

    /// 「重新翻译」忘掉那一条，同样的文字就得再发一次请求。不这样的话，按下去拿回来的是屏幕上已经有的
    /// 那一版 —— 什么都看不出来，用户只会觉得按钮坏了。
    @Test func forgettingAnEntrySendsItAgain() async throws {
        let cache = TranslationCache()
        var sent = 0
        @Sendable func send(_ items: [ChatTranslator.Item]) async throws -> [Int: String] {
            sent += 1
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "第 \(sent) 版") })
        }
        _ = try await cache.translate([.init(id: 0, text: "Settings")], config: config, send: send)
        _ = try await cache.translate([.init(id: 0, text: "Settings")], config: config, send: send)
        #expect(sent == 1)
        cache.forget("Settings", config: config)
        let again = try await cache.translate([.init(id: 0, text: "Settings")], config: config, send: send)
        #expect(sent == 2)
        #expect(again == [0: "第 2 版"])
        #expect(cache.get("Settings", config: config) == "第 2 版")
    }

    /// 忘掉的是「这一份配置 + 这一段文字」那一条，别人的译文不能跟着被清掉。
    @Test func forgettingLeavesOtherEntriesAlone() {
        let cache = TranslationCache()
        var other = config
        other.targetLanguage = "English"
        cache.set("设置", for: "Settings", config: config)
        cache.set("Settings", for: "Settings", config: other)
        cache.forget("Settings", config: config)
        #expect(cache.get("Settings", config: config) == nil)
        #expect(cache.get("Settings", config: other) == "Settings")
    }

    /// Two saved services can name the same model — the cache has to tell them apart by the entry, not by the
    /// model name, or one service's translation shows up while the other one is answering.
    @Test func cacheKeepsTwoServicesApart() {
        let cache = TranslationCache()
        let first = TranslationConfig(baseURL: "https://a.example.com", model: "deepseek-flash",
                                      apiKey: "sk-a", targetLanguage: "简体中文", configID: "a")
        var second = first
        second.baseURL = "https://b.example.com"
        second.apiKey = "sk-b"
        second.configID = "b"

        cache.set("甲家的译文", for: "Settings", config: first)
        #expect(cache.get("Settings", config: second) == nil)
        #expect(cache.get("Settings", config: first) == "甲家的译文")
    }

    /// Without an id (a config built by hand, the `--translate-image` path) the model name still separates.
    @Test func cacheFallsBackToTheModelName() {
        let cache = TranslationCache()
        var one = config
        one.model = "model-one"
        var two = config
        two.model = "model-two"
        cache.set("甲的译文", for: "Settings", config: one)
        #expect(cache.get("Settings", config: two) == nil)
    }
}

@Suite struct LLMConfigTests {
    @Test func unnamedEntriesShareTheDefaultName() {
        let configs = [LLMConfig(id: "a"), LLMConfig(id: "b", name: "  "), LLMConfig(id: "c", name: "DeepSeek")]
        #expect(LLMConfig.labels(for: configs) == ["自定义大模型", "自定义大模型 2", "DeepSeek"])
    }

    @Test func repeatedNamesAreNumbered() {
        let configs = [LLMConfig(id: "a", name: "DeepSeek"), LLMConfig(id: "b", name: "DeepSeek")]
        #expect(LLMConfig.labels(for: configs) == ["DeepSeek", "DeepSeek 2"])
    }

    @Test func emptyFieldsFallBackToTheDefaults() {
        let blank = LLMConfig(id: "a")
        #expect(blank.effectiveBaseURL == TranslationConfig.defaultBaseURL)
        #expect(blank.effectiveModel == TranslationConfig.defaultModel)
        #expect(blank.effectiveSystemPrompt == TranslationConfig.defaultSystemPrompt)

        var typed = LLMConfig(id: "b", baseURL: "https://api.example.com/v1", model: "m", systemPrompt: "只输出 JSON")
        #expect(typed.effectiveBaseURL == "https://api.example.com/v1")
        #expect(typed.effectiveModel == "m")
        #expect(typed.effectiveSystemPrompt == "只输出 JSON")

        // Writing the built-in prompt back is the same as clearing it: the entry keeps following the default.
        typed.setPrompt(TranslationConfig.defaultSystemPrompt)
        #expect(typed.systemPrompt.isEmpty)
        #expect(typed.effectiveSystemPrompt == TranslationConfig.defaultSystemPrompt)
        typed.setPrompt("   ")
        #expect(typed.systemPrompt.isEmpty)
    }

    /// An empty box means that provider's default, not DeepSeek's: a Claude entry with no base URL has to reach
    /// api.anthropic.com, not api.deepseek.com with a Claude model name.
    @Test func theDefaultsFollowTheProvider() {
        #expect(LLMConfig(id: "a", provider: .anthropic).effectiveBaseURL == "https://api.anthropic.com")
        #expect(LLMConfig(id: "a", provider: .anthropic).effectiveModel == LLMProvider.anthropic.defaultModel)
        #expect(LLMConfig(id: "a", provider: .gemini).effectiveBaseURL == "https://generativelanguage.googleapis.com")
    }

    @Test func survivesARoundTripThroughJSON() throws {
        let configs = [LLMConfig(id: "a", name: "DeepSeek", baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
                       LLMConfig(id: "b", provider: .anthropic, model: "claude-sonnet-5-5")]
        let data = try JSONEncoder().encode(configs)
        #expect(try JSONDecoder().decode([LLMConfig].self, from: data) == configs)
    }

    /// Entries saved before 接口类型 existed must still decode — anything else and `Settings.llmConfigs`, which
    /// reads a failure as "nothing saved yet", would quietly swap everyone's list for the carried-over entry.
    @Test func entriesFromBeforeProvidersStillDecode() throws {
        let old = #"[{"id":"default","name":"","baseURL":"https://api.deepseek.com","model":"deepseek-flash","systemPrompt":""}]"#
        let configs = try JSONDecoder().decode([LLMConfig].self, from: Data(old.utf8))
        #expect(configs.count == 1)
        #expect(configs[0].provider == .openai)
        #expect(configs[0].model == "deepseek-flash")
    }
}

/// A `URLProtocol` that answers from a queue and records what it was asked, so the request shapes, the parsing
/// and the JSON-mode retry can be driven end to end without a network.
final class StubProtocol: URLProtocol {
    static var queue: [(status: Int, body: Data)] = []
    static var sent: [(url: URL?, body: [String: Any]?)] = []

    static func reset() {
        queue = []
        sent = []
    }

    static func json(_ object: [String: Any], status: Int = 200) {
        queue.append((status, try! JSONSerialization.data(withJSONObject: object)))
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // A URLProtocol never sees `httpBody`; the machinery turns it into a stream before handing it over.
        var body: Data?
        if let direct = request.httpBody {
            body = direct
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.sent.append((request.url, body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }))
        let (status, payload) = Self.queue.isEmpty ? (200, Data("{}".utf8)) : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Serialized: the stub's queue is process-wide, and Swift Testing runs tests in parallel by default.
@Suite(.serialized) struct ProviderTests {
    let items = [ChatTranslator.Item(id: 0, text: "Settings")]

    func config(_ provider: LLMProvider, baseURL: String, model: String) -> TranslationConfig {
        TranslationConfig(baseURL: baseURL, model: model, apiKey: "sk-test", targetLanguage: "简体中文", provider: provider)
    }

    func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anthropicRequestShape() throws {
        let request = try ChatTranslator.makeRequest(items: items, config: config(.anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5"))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == TranslationConfig.anthropicVersion)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let fields = try body(request)
        #expect(fields["model"] as? String == "claude-sonnet-5-5")
        #expect(fields["max_tokens"] as? Int == ChatTranslator.maximumTokens)
        // `system` is a field of its own here, and the only message is the user's.
        #expect((fields["system"] as? String)?.contains("{target}") == false)
        let messages = try #require(fields["messages"] as? [[String: String]])
        #expect(messages.count == 1 && messages[0]["role"] == "user")
        #expect(messages[0]["content"] == #"{"items":[{"id":0,"text":"Settings"}]}"#)
        #expect(fields["response_format"] == nil)
    }

    @Test func geminiRequestShape() throws {
        let request = try ChatTranslator.makeRequest(items: items, config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com", model: "gemini-2.5-flash"))
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "sk-test")

        let fields = try body(request)
        let contents = try #require(fields["contents"] as? [[String: Any]])
        let parts = try #require(contents[0]["parts"] as? [[String: String]])
        #expect(contents[0]["role"] as? String == "user")
        #expect(parts[0]["text"] == #"{"items":[{"id":0,"text":"Settings"}]}"#)
        #expect((fields["systemInstruction"] as? [String: Any])?["parts"] != nil)
        let generation = try #require(fields["generationConfig"] as? [String: Any])
        #expect(generation["responseMimeType"] as? String == "application/json")
    }

    @Test func geminiModelIsNotDoubledWhenWrittenTheDocsWay() throws {
        let request = try ChatTranslator.makeRequest(items: items, config: config(.gemini, baseURL: "https://generativelanguage.googleapis.com", model: "models/gemini-2.5-flash"))
        #expect(request.url?.absoluteString.hasSuffix("/v1beta/models/gemini-2.5-flash:generateContent") == true)
    }

    /// The endpoint from the docs pasted into a box that wants the base URL. Left alone it doubles the path and
    /// the service answers 404, which tells the user nothing about the real mistake.
    @Test func pastedEndpointsAreTrimmed() throws {
        let cases: [(LLMProvider, String, String)] = [
            (.openai, "https://api.groq.com/openai/v1/chat/completions", "https://api.groq.com/openai/v1/chat/completions"),
            (.openai, "https://api.deepseek.com/v1/chat/completions/", "https://api.deepseek.com/v1/chat/completions"),
            (.openai, "https://api.deepseek.com/", "https://api.deepseek.com/chat/completions"),
            (.anthropic, "https://api.anthropic.com/v1/messages", "https://api.anthropic.com/v1/messages"),
            (.anthropic, "https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
             "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"),
            (.gemini, "https://generativelanguage.googleapis.com/v1beta", "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"),
        ]
        for (provider, pasted, expected) in cases {
            let model = provider == .gemini ? "gemini-2.5-flash" : (provider == .anthropic ? "claude-sonnet-5-5" : "deepseek-flash")
            let request = try ChatTranslator.makeRequest(items: items, config: config(provider, baseURL: pasted, model: model))
            #expect(request.url?.absoluteString == expected, "\(provider.rawValue)：\(pasted)")
        }
    }

    @Test func responsesAreUnwrappedPerProvider() throws {
        let anthropic = #"{"content":[{"type":"text","text":"{\"items\":[{\"id\":0,\"t\":\"设置\"}]}"}],"stop_reason":"end_turn"}"#
        #expect(try ChatTranslator.parseResponse(Data(anthropic.utf8), provider: .anthropic) == [0: "设置"])

        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"{\"items\":[{\"id\":0,\"t\":\"设置\"}]}"}],"role":"model"},"finishReason":"STOP"}]}"#
        #expect(try ChatTranslator.parseResponse(Data(gemini.utf8), provider: .gemini) == [0: "设置"])
    }

    /// A cut-off answer is half a JSON document; saying「无法解析」would send the user looking at their prompt.
    @Test func truncatedAnswersSaySo() throws {
        let anthropic = #"{"content":[{"type":"text","text":"{\"items\":[{\"id\":0,\"t\":\"设"}],"stop_reason":"max_tokens"}"#
        #expect(throws: TranslationError.truncated) {
            try ChatTranslator.parseResponse(Data(anthropic.utf8), provider: .anthropic)
        }
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"{"}]},"finishReason":"MAX_TOKENS"}]}"#
        #expect(throws: TranslationError.truncated) {
            try ChatTranslator.parseResponse(Data(gemini.utf8), provider: .gemini)
        }
    }

    @Test func aBlockedGeminiPromptSaysWhy() throws {
        let blocked = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        #expect(throws: TranslationError.self) {
            try ChatTranslator.parseResponse(Data(blocked.utf8), provider: .gemini)
        }
    }

    /// Finding out that a service dislikes `response_format` should cost one retry, not a trip to the settings:
    /// the prompt already asks for JSON and the parser copes with a fenced reply.
    @Test func jsonModeIsDroppedAndRetried() async throws {
        StubProtocol.reset()
        StubProtocol.json(["error": ["message": "response_format is not supported for this model"]], status: 400)
        StubProtocol.json(["choices": [["message": ["role": "assistant", "content": #"{"items":[{"id":0,"t":"设置"}]}"#]]]])
        defer { StubProtocol.reset() }

        let translations = try await ChatTranslator.translate(items, config: config(.openai, baseURL: "https://api.example.com/v1", model: "some-model"),
                                                              session: StubProtocol.session())
        #expect(translations == [0: "设置"])
        #expect(StubProtocol.sent.count == 2)
        #expect(StubProtocol.sent[0].body?["response_format"] != nil)
        #expect(StubProtocol.sent[1].body?["response_format"] == nil)
    }

    @Test func otherErrorsAreNotRetried() async throws {
        StubProtocol.reset()
        StubProtocol.json(["error": ["message": "Invalid API key"]], status: 401)
        defer { StubProtocol.reset() }

        await #expect(throws: TranslationError.http(status: 401, message: "Invalid API key")) {
            try await ChatTranslator.translate(items, config: config(.openai, baseURL: "https://api.example.com/v1", model: "some-model"),
                                               session: StubProtocol.session())
        }
        #expect(StubProtocol.sent.count == 1)
    }

    @Test func anthropicAnswerIsParsedEndToEnd() async throws {
        StubProtocol.reset()
        StubProtocol.json(["content": [["type": "text", "text": #"{"items":[{"id":0,"t":"设置"}]}"#]], "stop_reason": "end_turn"])
        defer { StubProtocol.reset() }

        let translations = try await ChatTranslator.translate(items, config: config(.anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5"),
                                                              session: StubProtocol.session())
        #expect(translations == [0: "设置"])
        #expect(StubProtocol.sent.count == 1)
        #expect(StubProtocol.sent[0].body?["max_tokens"] != nil)
    }
}

@Suite struct StitcherTests {
    static let width = 96

    /// A distinct pattern per content row, so every row hashes differently.
    static func contentRow(_ n: Int) -> [UInt8] {
        var row = [UInt8]()
        for x in 0..<width {
            let v = UInt8((n * 37 + x * 11 + (n * x) % 23) % 200 + 40) & 0xF8
            row += [v, UInt8((n * 13 + x) % 250) & 0xF8, UInt8((n + x * 7) % 250) & 0xF8, 255]
        }
        return row
    }

    static func solidRow(_ v: UInt8) -> [UInt8] {
        [UInt8](repeating: v, count: width * 4)
    }

    /// A 100-row window over tall content scrolled by `scroll`, with a 10-row header and 8-row footer that never move.
    /// `jitter` adds ±1 noise to every color value, like successive real screen captures.
    static func frame(scroll: Int, header: Bool = true, jitter: Bool = false) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            if header, y < 10 { data += solidRow(y % 2 == 0 ? 16 : 32); continue }
            if header, y >= 92 { data += solidRow(y % 2 == 0 ? 200 : 224); continue }
            data += contentRow(scroll + y)
        }
        if jitter {
            var rng = SystemRandomNumberGenerator()
            for i in data.indices where i % 4 != 3 {
                let v = Int(data[i]) + Int.random(in: -1...1, using: &rng)
                data[i] = UInt8(min(max(v, 0), 255))
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func stitchesWithStickyHeaderAndFooter() {
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(Self.frame(scroll: 0)) == .started)
        #expect(stitcher.add(Self.frame(scroll: 30)) == .appended(30))
        #expect(stitcher.add(Self.frame(scroll: 30)) == .unchanged)
        #expect(stitcher.add(Self.frame(scroll: 70)) == .appended(40))
        // Header once, content rows 10..<162, footer once.
        #expect(stitcher.height == 10 + 152 + 8)
        #expect(Array(stitcher.row(0)) == Self.solidRow(16))
        #expect(Array(stitcher.row(10)) == Self.contentRow(10))
        #expect(Array(stitcher.row(161)) == Self.contentRow(161))
        #expect(Array(stitcher.row(162)) == Self.solidRow(200)) // footer row 92
        #expect(stitcher.makeImage()?.height == 170)
        #expect(stitcher.makePreview(targetWidth: 48)?.height == 85)
    }

    @Test func toleratesCaptureJitter() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0, jitter: true))
        #expect(stitcher.add(Self.frame(scroll: 0, jitter: true)) == .unchanged)
        #expect(stitcher.add(Self.frame(scroll: 25, jitter: true)) == .appended(25))
        #expect(stitcher.add(Self.frame(scroll: 60, jitter: true)) == .appended(35))
        #expect(stitcher.height == 10 + (60 + 92 - 10) + 8)
    }

    @Test func roundedBottomCornersStayOutOfTheMiddle() {
        // The last 4 rows have "desktop" pixels in their outer columns, like a window's rounded corners,
        // while the content between them keeps scrolling.
        func cornered(_ frame: PixelBuffer) -> PixelBuffer {
            var data = frame.data
            for y in 96..<100 {
                for x in [0, 1, 2, Self.width - 3, Self.width - 2, Self.width - 1] {
                    data.replaceSubrange((y * Self.width + x) * 4 ..< (y * Self.width + x) * 4 + 3, with: [255, 0, 255])
                }
            }
            return PixelBuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data)
        }
        let stitcher = ScrollStitcher()
        for scroll in stride(from: 0, through: 120, by: 20) {
            _ = stitcher.add(cornered(Self.frame(scroll: scroll, header: false)))
        }
        #expect(stitcher.height == 220)
        for y in 0..<(stitcher.height - 4) {
            #expect(stitcher.row(y) == Self.contentRow(y), "row \(y) should be plain content")
        }
    }

    @Test func ignoresBackwardScrollAndResumes() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        _ = stitcher.add(Self.frame(scroll: 40))
        #expect(stitcher.add(Self.frame(scroll: 20)) == .scrolledBack)
        #expect(stitcher.add(Self.frame(scroll: 60)) == .appended(20))
        #expect(stitcher.height == 10 + (60 + 92 - 10) + 8)
    }

    @Test func reportsJumpWithoutOverlap() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 500)) == .noOverlap)
        #expect(stitcher.height == 100)
    }

    @Test func resumesAfterLosingTrack() {
        // A fling jumps past the visible band; frames only match again once the user scrolls back
        // to where the last stitched frame overlaps, and stitching then carries on seamlessly.
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 150)) == .noOverlap)
        #expect(stitcher.add(Self.frame(scroll: 170)) == .noOverlap)
        #expect(stitcher.add(Self.frame(scroll: 60)) == .appended(60))
        #expect(stitcher.add(Self.frame(scroll: 100)) == .appended(40))
        #expect(stitcher.height == 10 + (100 + 92 - 10) + 8)
        for y in 10..<(100 + 92) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    @Test func scrollHintPicksOffsetInRepeatingContent() {
        // Content that repeats every 20 rows matches at several offsets; the scroll hint picks the real one.
        func periodic(_ scroll: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 { data += y < 10 ? Self.solidRow(16) : Self.contentRow((scroll + y) % 20) }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let hinted = ScrollStitcher()
        _ = hinted.add(periodic(0))
        #expect(hinted.add(periodic(30), expectedOffset: 28) == .appended(30))

        let unhinted = ScrollStitcher()
        _ = unhinted.add(periodic(0))
        #expect(unhinted.add(periodic(30)) != .appended(30))
    }

    @Test func stopsAtHeightLimit() {
        let stitcher = ScrollStitcher(maxHeight: 120)
        _ = stitcher.add(Self.frame(scroll: 0))
        #expect(stitcher.add(Self.frame(scroll: 30)) == .limitReached)
    }

    @Test func ignoresChangingScrollBarColumns() {
        // Same content, but 8 columns at both edges differ between frames like overlay scroll bar knobs.
        func withKnobs(_ frame: PixelBuffer, _ v: UInt8) -> PixelBuffer {
            var data = frame.data
            for y in 0..<frame.height {
                for x in Array(0..<8) + Array((Self.width - 8)..<Self.width) {
                    data[(y * Self.width + x) * 4 ..< (y * Self.width + x) * 4 + 3] = [v, v, v]
                }
            }
            return PixelBuffer(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data)
        }
        let stitcher = ScrollStitcher(ignoredSideColumns: 8)
        _ = stitcher.add(withKnobs(Self.frame(scroll: 0, header: false), 0))
        #expect(stitcher.add(withKnobs(Self.frame(scroll: 30, header: false), 255)) == .appended(30))
    }

    /// A frame with a `footer`-row toolbar at the bottom that never moves.
    static func footered(scroll: Int, footer: Int, caret: Bool = false) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            if y >= 100 - footer {
                var row = solidRow(y % 3 == 0 ? 90 : 180)
                // A caret a few pixels wide in the input box, blinking between frames.
                if caret, y >= 100 - footer + 4, y < 100 - footer + 16 {
                    for x in 40..<42 { row.replaceSubrange(x * 4 ..< x * 4 + 3, with: scroll % 2 == 0 ? [0, 0, 0] : [255, 255, 255]) }
                }
                data += row
            } else {
                data += contentRow(scroll + y)
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func tallFooterAppearsOnlyAtTheBottom() {
        let stitcher = ScrollStitcher()
        for scroll in [0, 12, 30, 51, 70, 90] { _ = stitcher.add(Self.footered(scroll: scroll, footer: 30)) }
        #expect(stitcher.height == 90 + 100)
        for y in 0..<(90 + 70) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
        #expect(stitcher.row(stitcher.height - 1) == Self.footered(scroll: 90, footer: 30).data.suffix(Self.width * 4).map { $0 })
    }

    @Test func blinkingCaretInFooterIsNotContent() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.footered(scroll: 0, footer: 30, caret: true))
        #expect(stitcher.add(Self.footered(scroll: 1, footer: 30, caret: true)) == .appended(1))
        #expect(stitcher.add(Self.footered(scroll: 1, footer: 30, caret: false)) == .unchanged)
        #expect(stitcher.add(Self.footered(scroll: 25, footer: 30, caret: true)) == .appended(24))
        for y in 0..<(25 + 70) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    /// Content made of soft horizontal stripes sampled at fractional scroll positions, like a browser
    /// scrolling by half pixels and re-rendering: no two frames share exact rows.
    static func smooth(scroll: Double) -> PixelBuffer {
        var data = [UInt8]()
        for y in 0..<100 {
            let v = scroll + Double(y)
            for x in 0..<width {
                let a = 128 + 60 * sin(v * 0.21 + Double(x) * 0.13) + 50 * sin(v * 0.037 * Double(x % 7 + 1))
                data += [UInt8(max(0, min(255, a))), UInt8(max(0, min(255, 255 - a))), 128, 255]
            }
        }
        return PixelBuffer(width: width, height: 100, bytesPerRow: width * 4, data: data)
    }

    @Test func followsFractionalScrolling() {
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.smooth(scroll: 0))
        var total = 0
        for scroll in [7.5, 19.25, 33.5, 50.0] {
            guard case .appended(let d) = stitcher.add(Self.smooth(scroll: scroll)) else {
                Issue.record("frame at \(scroll) did not stitch")
                return
            }
            total += d
            #expect(abs(Double(total) - scroll) <= 1)
        }
    }

    @Test func lowTextureContentStillStitches() {
        // Mostly blank rows with a line of detail every 15 rows.
        func sparse(_ scroll: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 { data += (scroll + y) % 15 == 0 ? Self.contentRow(scroll + y) : Self.solidRow(250) }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let stitcher = ScrollStitcher()
        _ = stitcher.add(sparse(0))
        #expect(stitcher.add(sparse(20)) == .appended(20))
        #expect(stitcher.add(sparse(47)) == .appended(27))
    }

    @Test func rubberBandAtTheEndLeavesNoGap() {
        // At the end of the page the content overshoots, showing blank rows above the footer, then bounces back.
        func overscrolled(_ by: Int) -> PixelBuffer {
            var data = [UInt8]()
            for y in 0..<100 {
                if y < 10 { data += Self.solidRow(y % 2 == 0 ? 16 : 32) } else if y >= 92 { data += Self.solidRow(y % 2 == 0 ? 200 : 224) }
                else { data += y >= 92 - by ? Self.solidRow(255) : Self.contentRow(60 + y + by) }
            }
            return PixelBuffer(width: Self.width, height: 100, bytesPerRow: Self.width * 4, data: data)
        }
        let stitcher = ScrollStitcher()
        _ = stitcher.add(Self.frame(scroll: 0))
        _ = stitcher.add(Self.frame(scroll: 30))
        _ = stitcher.add(Self.frame(scroll: 60))
        #expect(stitcher.add(overscrolled(6)) == .appended(6))
        #expect(stitcher.add(Self.frame(scroll: 60)) == .scrolledBack)
        #expect(stitcher.height == 10 + (60 + 82) + 8)
        for y in 10..<(60 + 92) { #expect(stitcher.row(y) == Self.contentRow(y), "row \(y)") }
    }

    @Test func previewShowsTheNewestRows() {
        let stitcher = ScrollStitcher()
        for scroll in stride(from: 0, through: 300, by: 30) { _ = stitcher.add(Self.frame(scroll: scroll)) }
        let preview = stitcher.makePreview(targetWidth: 96, maxHeight: 50)
        #expect(preview?.height == 50)
        #expect(preview?.width == 96)
    }
}

@Suite struct TextSelectionTests {
    /// A line whose characters are each 10pt wide, starting at `x`.
    func line(_ text: String, x: CGFloat = 0, y: CGFloat) -> GlyphLine {
        let boxes = text.indices.enumerated().map { n, _ in CGRect(x: x + CGFloat(n) * 10, y: y, width: 10, height: 14) } as [CGRect?]
        return GlyphLine(text: text, rect: CGRect(x: x, y: y, width: CGFloat(text.count) * 10, height: 14), boxes: boxes)
    }

    @Test func sharesAWordBoxAcrossItsCharacters() {
        let word = CGRect(x: 0, y: 0, width: 40, height: 14)
        let space = CGRect?.none
        let l = GlyphLine(text: "abcd ef", rect: CGRect(x: 0, y: 0, width: 70, height: 14),
                          boxes: [word, word, word, word, space, CGRect(x: 50, y: 0, width: 20, height: 14), CGRect(x: 50, y: 0, width: 20, height: 14)])
        #expect(l.boxes.map(\.minX) == [0, 10, 20, 30, 40, 50, 60])
        #expect(l.boxes[4].width == 10)
    }

    @Test func ignoresTheEmptyBoxesVisionGivesSpaces() {
        let l = GlyphLine(text: "ab c", rect: CGRect(x: 100, y: 0, width: 40, height: 14),
                          boxes: [CGRect(x: 100, y: 0, width: 10, height: 14), CGRect(x: 110, y: 0, width: 10, height: 14), .zero,
                                  CGRect(x: 130, y: 0, width: 10, height: 14)])
        #expect(l.boxes.map(\.minX) == [100, 110, 120, 130])
    }

    @Test func draggingPastALineEndStaysOnThatLine() {
        let layout = TextLayout([line("a much longer line", y: 0), line("short", y: 20)])
        #expect(layout.nearestPosition(to: CGPoint(x: 120, y: 27)) == TextPosition(line: 1, offset: 5))
        #expect(layout.nearestPosition(to: CGPoint(x: 20, y: 60)) == TextPosition(line: 1, offset: 2))
    }

    @Test func missingBoxesFallBackToTheLine() {
        let l = GlyphLine(text: "abcd", rect: CGRect(x: 100, y: 5, width: 40, height: 14), boxes: [])
        #expect(l.boxes.map(\.minX) == [100, 110, 120, 130])
        #expect(l.boxes.allSatisfy { $0.minY == 5 && $0.height == 14 })
    }

    /// The recognition service sends finished boxes over a pipe; rebuilding the line must not re-measure them
    /// (a zero-width box at a line end would be re-shared and come back different).
    @Test func finalBoxesAreKeptAsTheyAre() {
        let final = [CGRect(x: 0, y: 0, width: 10, height: 14), CGRect(x: 10, y: 0, width: 0, height: 14),
                     CGRect(x: 10, y: 0, width: 15, height: 14)]
        let l = GlyphLine(text: "a b", rect: CGRect(x: 0, y: 0, width: 25, height: 14), finalBoxes: final)
        #expect(l.boxes == final)
    }

    @Test func hitTestFindsTheCaret() {
        let layout = TextLayout([line("hello", y: 0), line("world", y: 20)])
        #expect(layout.hitTest(CGPoint(x: 14, y: 7)) == TextPosition(line: 0, offset: 1))
        #expect(layout.hitTest(CGPoint(x: 16, y: 7)) == TextPosition(line: 0, offset: 2))
        #expect(layout.hitTest(CGPoint(x: 49, y: 27)) == TextPosition(line: 1, offset: 5))
        #expect(layout.hitTest(CGPoint(x: 90, y: 7)) == nil)
        #expect(layout.nearestPosition(to: CGPoint(x: 90, y: 7)) == TextPosition(line: 0, offset: 5))
    }

    @Test func selectsAcrossLinesInReadingOrder() {
        // Given out of order; the layout sorts them top to bottom.
        let layout = TextLayout([line("world", y: 20), line("hello", y: 0)])
        let range = TextSpan(anchor: TextPosition(line: 1, offset: 2), focus: TextPosition(line: 0, offset: 3))
        #expect(layout.text(for: range) == "lo\nwo")
        #expect(layout.rects(for: range) == [CGRect(x: 30, y: 0, width: 20, height: 14), CGRect(x: 0, y: 20, width: 20, height: 14)])
        #expect(layout.text(for: TextSpan(anchor: range.anchor, focus: range.anchor)) == "")
    }

    @Test func doubleClickSelectsAWord() {
        let layout = TextLayout([line("copy the text", y: 0), line("直接选择文字", y: 20)])
        let word = layout.word(at: CGPoint(x: 65, y: 7))!
        #expect(layout.text(for: word) == "the")
        let cjk = layout.word(at: CGPoint(x: 25, y: 27))!
        #expect(!cjk.isEmpty && layout.text(for: cjk).count < 6)
        let whole = layout.line(at: CGPoint(x: 25, y: 27))!
        #expect(layout.text(for: whole) == "直接选择文字")
    }
}

@Suite struct FreeTranslatorTests {
    func item(_ id: Int, _ n: Int) -> ChatTranslator.Item { .init(id: id, text: String(repeating: "a", count: n)) }

    @Test func batchesStayUnderLimitAndKeepOrder() {
        let items = (0..<5).map { item($0, 1500) }
        let batches = FreeTranslator.batches(items)
        #expect(batches.map { $0.map(\.id) } == [[0, 1], [2, 3], [4]])
    }

    @Test func batchAtExactLimitStaysTogether() {
        #expect(FreeTranslator.batches([item(0, 2000), item(1, 2000)]).count == 1)
        #expect(FreeTranslator.batches([item(0, 2000), item(1, 2001)]).count == 2)
    }

    @Test func overlongItemIsSplitWithoutLosingText() {
        let batches = FreeTranslator.batches([item(0, 10), item(1, 9000), item(2, 10)])
        #expect(batches.map { $0.map(\.id) } == [[0], [1], [1], [1, 2]])
        #expect(batches.allSatisfy { $0.reduce(0) { $0 + $1.text.utf16.count } <= 4000 })
        #expect(batches.flatMap { $0 }.filter { $0.id == 1 }.map(\.text).joined() == item(1, 9000).text)
    }

    @Test func unicodeChunksStayWithinServiceLimit() {
        let text = String(repeating: "中😀e\u{301}", count: 2000)
        let chunks = FreeTranslator.batches([.init(id: 42, text: text)]).flatMap { $0 }
        #expect(chunks.allSatisfy { $0.text.utf16.count <= 4000 && $0.id == 42 })
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test func translatesAndReassemblesLongParagraphs() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [FreeTranslationProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let config = TranslationConfig(baseURL: "", model: "", apiKey: "", targetLanguage: "English", engine: .free)
        let long = String(repeating: "a", count: 4000) + String(repeating: "b", count: 4000) + String(repeating: "c", count: 1000)
        let result = try await Translator.translate([
            .init(id: 7, text: "before"), .init(id: 42, text: long), .init(id: 9, text: "after"),
        ], config: config, session: session)
        #expect(result == [7: "BEFORE", 42: long.uppercased(), 9: "AFTER"])
    }

    @Test func buildsRequest() throws {
        let config = TranslationConfig(baseURL: "", model: "", apiKey: "", targetLanguage: "日本語", engine: .free, clientKey: "k1")
        let request = try FreeTranslator.makeRequest(texts: ["Settings", "Open"], config: config)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.httpMethod == "POST")
        #expect((body["header"] as? [String: Any])?["client_key"] as? String == "k1")
        #expect((body["target"] as? [String: Any])?["lang"] as? String == "ja")
        let source = try #require(body["source"] as? [String: Any])
        #expect(source["lang"] as? String == "auto")
        #expect(source["text_list"] as? [String] == ["Settings", "Open"])
    }

    @Test func mapsEveryLanguage() {
        #expect(["简体中文", "繁體中文", "English", "日本語", "한국어"].map(FreeTranslator.languageCode) == ["zh", "zh-TW", "en", "ja", "ko"])
    }

    @Test func parsesResponse() throws {
        let ok = #"{"header":{"ret_code":"succ"},"auto_translation":["设置","打开"]}"#
        #expect(try FreeTranslator.parseResponse(Data(ok.utf8), expected: 2) == ["设置", "打开"])
        #expect(throws: TranslationError.badResponse("译文数量与原文不一致")) {
            try FreeTranslator.parseResponse(Data(ok.utf8), expected: 3)
        }
        let limit = #"{"header":{"ret_code":"outOfLimit"}}"#
        #expect(throws: TranslationError.service("outOfLimit")) {
            try FreeTranslator.parseResponse(Data(limit.utf8), expected: 1)
        }
    }

    @Test func cacheKeyIgnoresModelForFreeEngine() {
        var a = TranslationConfig(baseURL: "", model: "m1", apiKey: "", targetLanguage: "English", engine: .free)
        var b = a
        b.model = "m2"
        #expect(TranslationCache.key("x", a) == TranslationCache.key("x", b))
        a.engine = .llm
        #expect(TranslationCache.key("x", a) != TranslationCache.key("x", b))
    }
}

private final class FreeTranslationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let source = try #require(body["source"] as? [String: Any])
            let texts = try #require(source["text_list"] as? [String])
            let withinLimit = texts.reduce(0) { $0 + $1.utf16.count } <= 4000
            let responseBody: [String: Any] = [
                "header": ["ret_code": withinLimit ? "succ" : "outOfLimit"],
                "auto_translation": texts.map { $0.uppercased() },
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: responseBody))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
