import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

private struct MediaTestFailure: Error, CustomStringConvertible { let description: String }

@main
private enum AssistantMediaTests {
    private static var suites = 0
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try value() == false { throw MediaTestFailure(description: message) }
    }
    private static func failure(_ operation: () throws -> Void) throws -> Error {
        do { try operation() } catch { return error }
        throw MediaTestFailure(description: "Expected media operation to fail")
    }
    private static func expectInvalid(_ image: AssistantImage) throws {
        let error = try failure { try image.validate() }
        guard case .invalidImage = error as? AssistantMediaError else {
            throw MediaTestFailure(description: "Invalid metadata must fail revalidation")
        }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        try body(); suites += 1; print("PASS \(name)")
    }
    private static func cgImage(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MediaTestFailure(description: "Cannot create generated image fixture")
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.7, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.15, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        guard let image = context.makeImage() else { throw MediaTestFailure(description: "Missing generated CGImage") }
        return image
    }
    private static func encoded(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw MediaTestFailure(description: "Cannot create fixture encoder")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaTestFailure(description: "Fixture encode failed") }
        return output as Data
    }
    private static func properties(_ data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw MediaTestFailure(description: "Cannot inspect fixture metadata")
        }
        return properties
    }
    private static func request(_ kind: AssistantWireProtocol, turns: [AssistantTurn]) throws -> [String: Any] {
        let config = BYOKConfiguration(baseURL: "https://fixtures.example.com/v1", protocolKind: kind, model: "fixture-vision", apiKey: "local-fixture-key")
        let request = try config.request(turns: turns, instructions: "Describe user-provided images", requestId: "media-fixture-request")
        return try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }

    static func main() throws {
        let smallPNG = try encoded(cgImage(width: 64, height: 32), type: .png)
        let prepared = try AssistantImagePreprocessor.prepare(smallPNG)

        try run("preprocess-format-size-and-dimensions") {
            try expect(prepared.mimeType == "image/jpeg" && prepared.width == 64 && prepared.height == 32, "Small PNG must become correctly sized JPEG")
            try prepared.validate()
            let largeJPEG = try encoded(cgImage(width: 3_200, height: 2_000), type: .jpeg)
            let resized = try AssistantImagePreprocessor.prepare(largeJPEG)
            try expect(resized.width == 1_600 && resized.height == 1_000, "Large source must preserve aspect ratio and fit the 1600 px limit")
            try expect((resized.data?.count ?? .max) <= 512_000, "Output must meet the payload cap")
            try expect(resized.base64Data.utf8.count <= 700_000, "Encoded body must remain bounded")
            try expect(resized.dataURL == "data:image/jpeg;base64," + resized.base64Data, "Data URL must match MIME and bytes")
            try resized.validate()
        }

        try run("preprocess-orientation-transform") {
            let source = try encoded(cgImage(width: 400, height: 200), type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
            try expect(try properties(source)[kCGImagePropertyOrientation] as? Int == 6, "Fixture must actually contain EXIF orientation 6")
            let rotated = try AssistantImagePreprocessor.prepare(source)
            try expect(rotated.width == 200 && rotated.height == 400, "Orientation must be baked into output pixels, not just copied as metadata")
            let outputProperties = try properties(rotated.data!)
            try expect((outputProperties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "Output must not double-rotate in downstream viewers")
            try rotated.validate()
        }

        try run("preprocess-strips-source-exif-gps") {
            let metadata: [CFString: Any] = [
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 39.9, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 116.4, kCGImagePropertyGPSLongitudeRef: "E"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "generated-private-comment", kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "GeneratedFixtureCamera", kCGImagePropertyTIFFModel: "PrivateFixtureModel"]
            ]
            let source = try encoded(cgImage(width: 400, height: 200), type: .jpeg, properties: metadata)
            let inputProperties = try properties(source)
            try expect(inputProperties[kCGImagePropertyGPSDictionary] != nil, "GPS fixture properties must actually exist before stripping")
            try expect((inputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment] != nil, "EXIF fixture must actually contain private comment")
            let sanitized = try AssistantImagePreprocessor.prepare(source)
            let outputProperties = try properties(sanitized.data!)
            try expect(outputProperties[kCGImagePropertyGPSDictionary] == nil, "GPS must not leave the device")
            let exif = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            try expect(exif?[kCGImagePropertyExifUserComment] == nil && exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "Original EXIF user comment and capture time must be stripped")
            let tiff = outputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            try expect(tiff?[kCGImagePropertyTIFFMake] == nil && tiff?[kCGImagePropertyTIFFModel] == nil, "Source camera properties must be stripped")
        }

        try run("preprocess-input-limits-and-invalid-types") {
            let largeError = try failure { _ = try AssistantImagePreprocessor.prepare(Data(count: 20 * 1024 * 1024 + 1)) }
            guard case .inputTooLarge = largeError as? AssistantMediaError else { throw MediaTestFailure(description: "Input byte cap must reject before decoding") }
            for value in [Data(), Data("not an image".utf8), smallPNG.prefix(8)] {
                let error = try failure { _ = try AssistantImagePreprocessor.prepare(Data(value)) }
                guard case .invalidImage = error as? AssistantMediaError else { throw MediaTestFailure(description: "Invalid source bytes must fail explicitly") }
            }
            let gif = try encoded(cgImage(width: 16, height: 16), type: .gif)
            let gifError = try failure { _ = try AssistantImagePreprocessor.prepare(gif) }
            guard case .unsupportedType = gifError as? AssistantMediaError else { throw MediaTestFailure(description: "GIF must not silently pass the allowed format list") }
            let widePNG = try encoded(cgImage(width: 40_001, height: 1), type: .png)
            let dimensionError = try failure { _ = try AssistantImagePreprocessor.prepare(widePNG) }
            guard case .inputTooLarge = dimensionError as? AssistantMediaError else { throw MediaTestFailure(description: "Pathological source dimensions must be rejected before thumbnail decode") }
        }

        try run("preprocess-oversized-pixel-count") {
            // A real generated bitmap avoids relying on ImageIO accepting a
            // modified PNG header with an inconsistent compressed pixel stream.
            let fixture = try encoded(cgImage(width: 6_400, height: 6_400), type: .png)
            let metadata = try properties(fixture)
            try expect(metadata[kCGImagePropertyPixelWidth] as? Int == 6_400 && metadata[kCGImagePropertyPixelHeight] as? Int == 6_400, "Fixture must actually declare more than 40 MP")
            let error = try failure { _ = try AssistantImagePreprocessor.prepare(fixture) }
            guard case .inputTooLarge = error as? AssistantMediaError else { throw MediaTestFailure(description: "40 MP source pixel cap must be enforced") }
        }

        try run("outgoing-image-revalidation") {
            let variants = [
                AssistantImage(id: "bad-mime", mimeType: "image/png", base64Data: prepared.base64Data, width: prepared.width, height: prepared.height),
                AssistantImage(id: "bad-width", mimeType: "image/jpeg", base64Data: prepared.base64Data, width: prepared.width + 1, height: prepared.height),
                AssistantImage(id: "bad-height", mimeType: "image/jpeg", base64Data: prepared.base64Data, width: prepared.width, height: prepared.height + 1),
                AssistantImage(id: "bad-zero", mimeType: "image/jpeg", base64Data: prepared.base64Data, width: 0, height: prepared.height),
                AssistantImage(id: "bad-base64", mimeType: "image/jpeg", base64Data: "not!base64", width: 64, height: 32),
                AssistantImage(id: "bad-bytes", mimeType: "image/jpeg", base64Data: Data("garbage".utf8).base64EncodedString(), width: 64, height: 32),
                AssistantImage(id: "disguised-png", mimeType: "image/jpeg", base64Data: smallPNG.base64EncodedString(), width: 64, height: 32),
                AssistantImage(id: "too-many-base64-bytes", mimeType: "image/jpeg", base64Data: String(repeating: "A", count: 700_001), width: 64, height: 32),
                AssistantImage(id: "oversize-decoded-bytes", mimeType: "image/jpeg", base64Data: Data(count: 512_001).base64EncodedString(), width: 64, height: 32)
            ]
            for image in variants { try expectInvalid(image) }
            try prepared.validate()
        }

        try run("chat-image-request-mixed-history") {
            let turns = [AssistantTurn(id: "u1", role: "user", text: "Look at this", images: [prepared]), AssistantTurn(id: "a1", role: "assistant", text: "A description"), AssistantTurn(id: "u2", role: "user", text: "Continue")]
            let body = try request(.chatCompletions, turns: turns)
            let history = body["messages"] as! [[String: Any]]
            try expect(history.count == 4 && history[0]["role"] as? String == "system", "Chat images must retain the system prompt and all turns")
            let blocks = history[1]["content"] as! [[String: Any]]
            try expect(blocks[0]["type"] as? String == "text" && blocks[0]["text"] as? String == "Look at this", "Image turns must retain accompanying user text")
            let image = blocks[1]["image_url"] as! [String: Any]
            try expect(blocks[1]["type"] as? String == "image_url" && image["url"] as? String == prepared.dataURL, "Chat image must be a JPEG data URL")
            try expect(history[2]["role"] as? String == "assistant" && history[2]["content"] as? String == "A description", "Assistant text history must remain a string")
            try expect(history[3]["content"] as? String == "Continue", "Text-only user compatibility must remain intact")
        }

        try run("responses-anthropic-image-requests") {
            let turns = [AssistantTurn(id: "u1", role: "user", text: "Look", images: [prepared]), AssistantTurn(id: "a1", role: "assistant", text: "Answer")]
            let responses = try request(.responses, turns: turns)
            let responseInput = responses["input"] as! [[String: Any]]
            let blocks = responseInput[0]["content"] as! [[String: Any]]
            try expect(blocks[0]["type"] as? String == "input_text" && blocks[1]["type"] as? String == "input_image", "Responses must use its own content block types")
            try expect(blocks[1]["image_url"] as? String == prepared.dataURL, "Responses image URL must carry exact sanitized bytes")
            try expect(responses["store"] as? Bool == false && responseInput[1]["content"] as? String == "Answer", "Responses privacy setting and assistant history must remain intact")
            let anthropic = try request(.anthropic, turns: turns)
            let anthropicHistory = anthropic["messages"] as! [[String: Any]]
            let anthropicBlocks = anthropicHistory[0]["content"] as! [[String: Any]]
            let source = anthropicBlocks[1]["source"] as! [String: Any]
            try expect(anthropicBlocks[1]["type"] as? String == "image" && source["type"] as? String == "base64", "Anthropic requires explicit base64 image source")
            try expect(source["media_type"] as? String == "image/jpeg" && source["data"] as? String == prepared.base64Data, "Anthropic MIME and base64 must match sanitized bytes")
            try expect(anthropicHistory[1]["role"] as? String == "assistant" && anthropicHistory[1]["content"] as? String == "Answer", "Anthropic must preserve assistant text history")
            for kind in AssistantWireProtocol.allCases {
                let textOnly = try request(kind, turns: [AssistantTurn(id: "text", role: "user", text: "Plain text", images: [])])
                let values = textOnly[kind == .responses ? "input" : "messages"] as! [[String: Any]]
                try expect(values.last?["content"] as? String == "Plain text", "Empty images must preserve text-only request format")
            }
        }

        try run("image-count-role-and-payload-limits") {
            for kind in AssistantWireProtocol.allCases {
                _ = try request(kind, turns: [AssistantTurn(id: "valid3", role: "user", text: "Three", images: [prepared, prepared, prepared])])
                let countError = try failure { _ = try request(kind, turns: [AssistantTurn(id: "invalid4", role: "user", text: "Four", images: [prepared, prepared, prepared, prepared])]) }
                guard case .tooManyImages = countError as? AssistantMediaError else { throw MediaTestFailure(description: "All adapters must enforce the 3-image limit") }
                let roleError = try failure { _ = try request(kind, turns: [AssistantTurn(id: "invalid-role", role: "assistant", text: "Forged attachment", images: [prepared])]) }
                guard case .invalidImage = roleError as? AssistantMediaError else { throw MediaTestFailure(description: "Assistant-history images must not be mislabeled as user content") }
            }
            let overBudget = try failure { _ = try request(.responses, turns: [AssistantTurn(id: "large", role: "user", text: String(repeating: "x", count: 6 * 1024 * 1024))]) }
            guard case .outputTooLarge = overBudget as? AssistantMediaError else { throw MediaTestFailure(description: "Serialized requests must remain bounded") }
        }

        try run("archive-image-roundtrip-and-account-isolation") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-media-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = AssistantChatArchive(directory: directory)
            try archive.prepare(userId: "A"); try archive.prepare(userId: "B")
            let message = ChatMessage(id: "with-image", role: .user, content: "A photo", timestamp: Date(timeIntervalSince1970: 1_000), images: [prepared])
            let conversation = Conversation(id: "same-id", title: "Image analysis", preview: "A photo", date: message.timestamp, messages: [message])
            try archive.upsert(conversation, userId: "A")
            let restarted = AssistantChatArchive(directory: directory); try restarted.prepare(userId: "A")
            let loaded = try restarted.load(userId: "A")
            try expect(loaded.first?.messages.first?.images == [prepared], "Sanitized bytes and all image metadata must survive archive reload")
            try loaded.first!.messages.first!.images!.first!.validate()
            try expect(try archive.load(userId: "B").isEmpty, "A's photo must not be visible to another account")
            try archive.delete(ids: ["same-id"], userId: "B")
            try expect(try archive.load(userId: "A").first?.messages.first?.images == [prepared], "Other-account deletion must not erase A's photo")
        }

        try run("legacy-message-and-turn-no-images") {
            let message = ChatMessage(id: "legacy", role: .assistant, content: "Old answer", timestamp: Date(timeIntervalSince1970: 1_000))
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as! [String: Any]
            json.removeValue(forKey: "images")
            let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
            try expect(decoded.images == nil && decoded.content == "Old answer", "Legacy archived text must decode without images")
            let turn = AssistantTurn(id: "legacy-turn", role: "user", text: "Old question")
            var turnJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as! [String: Any]
            turnJSON.removeValue(forKey: "images")
            let decodedTurn = try JSONDecoder().decode(AssistantTurn.self, from: JSONSerialization.data(withJSONObject: turnJSON))
            try expect(decodedTurn.images == nil && decodedTurn.text == "Old question", "Legacy text turns must remain source and wire compatible")
        }
        try run("image-draft-roundtrip-and-legacy") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-image-draft-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let archive = AssistantChatArchive(directory: dir)
            try archive.prepare(userId: "A"); try archive.prepare(userId: "B")
            let image = prepared
            try archive.saveDraft("draft with photo", images: [image], conversationId: "draft-conversation", userId: "A")
            let restarted = AssistantChatArchive(directory: dir); try restarted.prepare(userId: "A")
            let record = try restarted.loadDraftRecord(userId: "A")
            try expect(record.text == "draft with photo" && record.images == [image] && record.conversationId == "draft-conversation", "Draft images and conversation survive restart")
            try expect(try archive.loadDraftRecord(userId: "B").images == nil, "Another owner cannot load A's image draft")
            let legacyDirectory = dir.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            let legacyArchive = AssistantChatArchive(directory: legacyDirectory)
            let draftURL = legacyArchive.databaseURL(userId: "A").deletingPathExtension().appendingPathExtension("json").appendingPathExtension("draft")
            try JSONEncoder().encode("legacy draft").write(to: draftURL)
            try legacyArchive.prepare(userId: "A")
            let legacy = try legacyArchive.loadDraftRecord(userId: "A")
            try expect(legacy.text == "legacy draft" && legacy.images == nil, "Old string-only draft remains readable")
        }
        print("All \(suites) AssistantMedia suites passed; only generated fixtures and isolated temporary files used.")
    }
}
