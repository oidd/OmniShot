import CoreGraphics
import Foundation
import Testing
@testable import OmniShotCore

/// The Baidu client is driven with a made-up transport everywhere here: none of these tests touch the network,
/// and each one uses its own API key so the shared token cache cannot leak between them.
private func response(_ status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://aip.baidubce.com")!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
}

private let tokenJSON = Data(#"{"access_token":"token-abc","expires_in":2592000}"#.utf8)

private let pageJSON = Data("""
{
  "log_id": 1,
  "words_result_num": 2,
  "words_result": [
    {"words": "业务员", "location": {"left": 10, "top": 20, "width": 30, "height": 10},
     "chars": [{"char": "业", "location": {"left": 10, "top": 20, "width": 10, "height": 10}},
               {"char": "务", "location": {"left": 20, "top": 20, "width": 10, "height": 10}},
               {"char": "员", "location": {"left": 30, "top": 20, "width": 10, "height": 10}}]},
    {"words": "刘伟", "location": {"left": 10, "top": 35, "width": 20, "height": 10},
     "chars": []}
  ],
  "paragraphs_result": [{"words_result_idx": [0, 1]}]
}
""".utf8)

private func tinyImage(width: Int = 8, height: Int = 8) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Suite("百度 OCR")
struct BaiduOCRTests {
    @Test("回复里的行、逐字框和段落都解出来，坐标归一化到 0…1")
    func parsesLinesAndParagraphs() throws {
        let page = try BaiduOCR.parse(pageJSON, width: 100, height: 50)
        #expect(page.lines.count == 2)
        #expect(page.lines[0].words == "业务员")
        #expect(page.lines[0].rect == CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.2))
        #expect(page.lines[0].chars.count == 3)
        #expect(page.lines[0].chars[1].text == "务")
        #expect(page.lines[0].chars[1].rect == CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.2))
        #expect(page.paragraphs == [[0, 1]])
    }

    @Test("段落里越界的行号整段丢掉，不会指到不存在的行")
    func dropsParagraphsThatPointNowhere() throws {
        let json = Data(#"{"words_result":[{"words":"甲","location":{"left":0,"top":0,"width":5,"height":5}}],"paragraphs_result":[{"words_result_idx":[0,7]}]}"#.utf8)
        let page = try BaiduOCR.parse(json, width: 10, height: 10)
        #expect(page.paragraphs.isEmpty)
    }

    @Test("表单体带上图片、语言、逐字和段落开关")
    func formBodyCarriesEverySwitch() throws {
        let body = BaiduOCR.formBody(imageData: Data([0x01, 0x02, 0xFB]), config: .init(apiKey: "k", secretKey: "s"))
        let string = String(decoding: body, as: UTF8.self)
        #expect(string.hasPrefix("image="))
        // base64 of 01 02 FB is "AQL7" — nothing in it may reach the server unescaped.
        #expect(string.contains("AQL7"))
        #expect(string.contains("language_type=CHN_ENG"))
        #expect(string.contains("recognize_granularity=small"))
        #expect(string.contains("paragraph=true"))
    }

    @Test("两个精度各走各的接口，都带 access_token")
    func picksTheEndpoint() throws {
        let encoded = BaiduImageEncoder.Encoded(data: Data([0]), width: 1, height: 1)
        let accurate = BaiduOCR.recognitionRequest(encoded, token: "t", precision: .accurate,
                                                   config: .init(apiKey: "k", secretKey: "s"))
        let standard = BaiduOCR.recognitionRequest(encoded, token: "t", precision: .standard,
                                                   config: .init(apiKey: "k", secretKey: "s"))
        #expect(accurate.url?.path == "/rest/2.0/ocr/v1/accurate")
        #expect(standard.url?.path == "/rest/2.0/ocr/v1/general")
        #expect(accurate.url?.query == "access_token=t")
        #expect(accurate.httpMethod == "POST")
        #expect(accurate.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test("百度自己的错误码说成人话")
    func mapsErrorCodes() throws {
        let json = Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8)
        do {
            _ = try BaiduOCR.parse(json, width: 10, height: 10)
            Issue.record("应该抛错")
        } catch let error as BaiduOCRError {
            #expect(error == .service(code: 17, message: "Open api daily request limit reached"))
            #expect(error.errorDescription?.contains("免费次数用完了") == true)
        }
    }

    @Test("没填 Key 不动网络，直接说明去哪儿填")
    func refusesWithoutKeys() async {
        do {
            _ = try await BaiduOCR.recognize(image: tinyImage(), config: .init(apiKey: " ", secretKey: ""))
            Issue.record("应该抛错")
        } catch let error as BaiduOCRError {
            #expect(error == .notConfigured)
            #expect(error.errorDescription?.contains("设置 → 文字识别") == true)
        } catch {
            Issue.record("抛错了类型：\(error)")
        }
    }

    @Test("token 只取一次，第二张图直接用缓存")
    func cachesTheToken() async throws {
        let counter = Counter()
        let page: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" {
                await counter.bump()
                return (tokenJSON, response())
            }
            return (pageJSON, response())
        }
        let config = BaiduOCRConfig(apiKey: "cache-key-\(UUID().uuidString)", secretKey: "s")
        _ = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: page)
        _ = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: page)
        #expect(await counter.value == 1)
    }

    @Test("token 被服务端判失效时换一个新的重试一次")
    func refreshesAnExpiredToken() async throws {
        let counter = Counter()
        let tokens = Counter()
        let transport: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" {
                let n = await tokens.bump()
                return (Data(#"{"access_token":"token-\#(n)","expires_in":2592000}"#.utf8), response())
            }
            let token = request.url?.query ?? ""
            // The first token is rejected the way Baidu rejects an expired one.
            if token.contains("token-1") {
                return (Data(#"{"error_code":111,"error_msg":"Access token expired"}"#.utf8), response())
            }
            await counter.bump()
            return (pageJSON, response())
        }
        let config = BaiduOCRConfig(apiKey: "expire-key-\(UUID().uuidString)", secretKey: "s")
        let page = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: transport)
        let tokenCount = await tokens.value
        let recognized = await counter.value
        #expect(page.lines.count == 2)
        #expect(tokenCount == 2, "token 一共取了 \(tokenCount) 次")
        #expect(recognized == 1, "识别请求成功了 \(recognized) 次")
    }

    @Test("超出边长上限的图先缩，坐标仍然按实际发出去的那张算")
    func shrinksOversizedPictures() throws {
        let encoded = try #require(BaiduImageEncoder.encode(tinyImage(width: 9000, height: 100)))
        #expect(max(encoded.width, encoded.height) == BaiduImageEncoder.maxSide)
        #expect(!encoded.data.isEmpty)
        let back = try BaiduOCR.parse(pageJSON, width: encoded.width, height: encoded.height)
        #expect(back.lines[0].rect.width > 0)
    }

    @Test("小图上传前先放大，大图原样发，最多 2 倍")
    func upscalesSmallPictures() {
        let email = tinyImage(width: 2000, height: 600)
        let grown = BaiduOCR.upscaledForSmallText(email)
        #expect(grown.width == 3000 && grown.height == 900, "2000 长的图放大到 3000（\(grown.width)×\(grown.height)）")

        let big = tinyImage(width: 4000, height: 2000)
        #expect(BaiduOCR.upscaledForSmallText(big).width == 4000, "已经够大的图不动")

        let small = tinyImage(width: 1000, height: 500)
        #expect(BaiduOCR.upscaledForSmallText(small).width == 2000, "再小也只放大 2 倍")
    }

    @Test("base64 里的 + / = 都要转义，否则表单会被截断")
    func escapesBase64() {
        #expect(BaiduOCR.percentEncode("a+b/c=") == "a%2Bb%2Fc%3D")
    }

    @Test("高精度的额度用完了自动换标准，提示只在发现的那一次出现")
    func fallsBackWhenTheQuotaIsOut() async throws {
        let quotaHits = Counter()
        let transport: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" { return (tokenJSON, response()) }
            if request.url?.path == "/rest/2.0/ocr/v1/accurate" {
                await quotaHits.bump()
                return (Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8), response())
            }
            return (pageJSON, response())
        }
        let config = BaiduOCRConfig(apiKey: "quota-\(UUID().uuidString)", secretKey: "s", precision: .accurate)

        let first = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: transport)
        #expect(first.usedPrecision == .standard, "换成了标准版")
        #expect(first.fellBack, "这一次要告诉用户")
        #expect(await quotaHits.value == 1)

        // 下一张图不再去撞已经空掉的那个接口，也就没有新的提示。
        let second = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: transport)
        #expect(second.usedPrecision == .standard)
        #expect(!second.fellBack)
        #expect(await quotaHits.value == 1, "空掉的接口只被撞了一次")
    }

    @Test("两份额度都空了才报错")
    func reportsWhenBothAreOut() async {
        let transport: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" { return (tokenJSON, response()) }
            return (Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8), response())
        }
        let config = BaiduOCRConfig(apiKey: "empty-\(UUID().uuidString)", secretKey: "s")
        do {
            _ = try await BaiduOCR.recognize(image: tinyImage(), config: config, transport: transport)
            Issue.record("应该抛错")
        } catch let error as BaiduOCRError {
            #expect(error == .service(code: 17, message: "Open api daily request limit reached"))
        } catch {
            Issue.record("抛错了类型：\(error)")
        }
    }
}

/// A counter an injected transport can bump from another task.
private actor Counter {
    private(set) var value = 0

    @discardableResult
    func bump() -> Int {
        value += 1
        return value
    }
}
