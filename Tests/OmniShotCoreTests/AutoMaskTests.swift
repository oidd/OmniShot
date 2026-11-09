import CoreGraphics
import Foundation
import Testing
@testable import OmniShotCore

/// A synthetic recognized line: one box per character at a fixed advance, in the same top-left space the
/// detector works in. The real recogniser measures each character separately; a fixed advance is enough to
/// exercise where a word starts and ends.
private func autoLine(_ text: String, x: CGFloat = 20, y: CGFloat = 20,
                      charWidth: CGFloat = 8, height: CGFloat = 14) -> OCRLine {
    var glyphs: [OCRGlyph] = []
    var offset: CGFloat = 0
    for character in text {
        let width = character == " " ? charWidth * 0.5 : charWidth
        glyphs.append(OCRGlyph(text: String(character),
                               rect: CGRect(x: x + offset, y: y, width: width, height: height)))
        offset += width
    }
    return OCRLine(text: text, rect: CGRect(x: x, y: y, width: offset, height: height), glyphs: glyphs)
}

@Suite struct AutoMaskTests {
    private let page = CGRect(x: 0, y: 0, width: 900, height: 600)

    private func targets(_ lines: [OCRLine]) -> [AutoMaskTarget] {
        AutoMaskDetector.targets(from: lines, in: page)
    }

    @Test func findsAPhoneNumberAfterAChineseLabel() {
        let found = targets([autoLine("手机号：13800138000")])
        let phone = found.first { $0.text == "13800138000" }
        #expect(phone != nil)
        #expect(phone?.category == .phone)
        // The label is a target too: everything recognized can be hovered and clicked, even on its own.
        #expect(found.contains { $0.text == "手机号" })
    }

    @Test func groupsTheSameTextEverywhere() {
        let found = targets([
            autoLine("alice.brown927@qq.com", y: 20),
            autoLine("alice.brown927@qq.com", y: 50),
        ])
        let emails = found.filter { $0.category == .email }
        #expect(emails.count == 2)
        #expect(emails.allSatisfy { $0.groupCount == 2 })
        #expect(Set(emails.map(\.groupKey)).count == 1)
    }

    @Test func countsTheWholeCategoryForTheShiftClick() {
        let found = targets([
            autoLine("+86 13800138001", y: 20),
            autoLine("+86 13800138002", y: 50),
            autoLine("+86 13800138003", y: 80),
        ])
        let phones = found.filter { $0.category == .phone }
        #expect(phones.count == 3)
        #expect(phones.allSatisfy { $0.categoryCount == 3 })
        // Different numbers are different groups, so a plain click masks one number only.
        #expect(Set(phones.map(\.groupKey)).count == 3)
        #expect(phones.allSatisfy { $0.groupCount == 1 })
    }

    @Test func joinsAPhoneNumberThatWasSplitBySpaces() {
        let found = targets([autoLine("+86 138 0013 8000")])
        let phones = found.filter { $0.category == .phone }
        #expect(phones.count == 1)
        #expect(phones.first?.text == "+86 138 0013 8000")
    }

    @Test func tellsDatesTimesAndIDsApart() {
        let found = targets([
            autoLine("2026-10-20", y: 20),
            autoLine("10:30", y: 50),
            autoLine("11010519491231002X", y: 80),
        ])
        #expect(found.first { $0.text == "2026-10-20" }?.category == .date)
        #expect(found.first { $0.text == "10:30" }?.category == .time)
        #expect(found.first { $0.text == "11010519491231002X" }?.category == .idNumber)
    }

    @Test func aRepeatedLineIsOneTarget() {
        let found = targets([
            autoLine("Internal use only", y: 20),
            autoLine("Internal use only", y: 50),
        ])
        let lines = found.filter(\.isLine)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.groupCount == 2 })
        #expect(lines.first?.text == "Internal use only")
    }

    @Test func aRepeatedLineIsStillATargetWhenItHoldsAnEmail() {
        let found = targets([
            autoLine("alice.brown927@qq.com", y: 20),
            autoLine("alice.brown927@qq.com", y: 50),
        ])
        // Both the email (a typed value) and the whole line are targets: the pointer prefers the email.
        #expect(found.contains { $0.category == .email })
        #expect(found.contains { $0.groupKey.hasPrefix("line:") && $0.groupCount == 2 })
    }

    @Test func repeatedPhraseInsideDifferentLines() {
        let found = targets([
            autoLine("Row A: Approved by admin", y: 20),
            autoLine("Row B: Approved by admin", y: 50),
        ])
        let phrases = found.filter { $0.groupKey.hasPrefix("phrase:") && $0.text == "Approved by admin" }
        #expect(phrases.count == 2)
        #expect(phrases.allSatisfy { $0.groupCount == 2 })
    }

    @Test func repeatedSentenceAcrossParagraphs() {
        let first = [autoLine("Notice: your session", y: 20), autoLine("will expire soon", y: 45)]
        let second = [autoLine("Notice: your session", y: 200), autoLine("will expire soon", y: 225)]
        let blocks = [TextBlock(id: 0, lines: first), TextBlock(id: 1, lines: second)]
        let found = AutoMaskDetector.targets(from: first + second, blocks: blocks, in: page)
        let paragraphs = found.filter { $0.groupKey.hasPrefix("block:") }
        #expect(paragraphs.count == 2)
        #expect(paragraphs.allSatisfy { $0.groupCount == 2 && $0.isLine })
    }

    @Test func aRepeatedWordIsATargetWithoutBeingAFrame() {
        let found = targets([
            autoLine("OK", y: 20),
            autoLine("OK", y: 50),
        ])
        #expect(found.contains { $0.text == "OK" && $0.groupCount == 2 })
    }

    @Test func everyRecognizedWordIsATarget() {
        let found = targets([autoLine("Save", y: 20), autoLine("Cancel", y: 50)])
        #expect(found.contains { $0.text == "Save" })
        #expect(found.contains { $0.text == "Cancel" })
    }

    @Test func masksExpandBeyondTheTightRecognitionBox() {
        let line = autoLine("alice.brown927@qq.com")
        guard let target = targets([line]).first(where: { $0.category == .email }) else {
            Issue.record("no email target")
            return
        }
        #expect(target.rect.width > line.rect.width)
        #expect(page.contains(target.rect))
    }
}
