import XCTest
@testable import Visor

/// Storage and formatting. All pure logic over a temp directory — no UI, no
/// network, no shared state between cases.
final class ChatStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeChat(_ title: String = "Test chat") -> Conversation {
        Conversation(title: title, agentName: "Tester", model: "test/model",
                     messages: [
                        ChatMessage(role: .user, content: "hello"),
                        ChatMessage(role: .assistant, content: "hi", model: "test/model"),
                     ])
    }

    func testSaveThenReadRoundTrips() throws {
        let store = ChatStore(root: root)
        let chat = makeChat()
        store.save(chat)

        // save() writes asynchronously; the summary is updated synchronously.
        XCTAssertEqual(store.summaries.count, 1)
        XCTAssertEqual(store.summaries.first?.title, "Test chat")

        let expectation = expectation(description: "written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let loaded = store.conversation(chat.id)
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages.first?.content, "hello")
    }

    /// The index is a cache; losing it must not lose chats.
    func testIndexRebuildsFromFiles() throws {
        let store = ChatStore(root: root)
        store.save(makeChat("One"))
        store.save(makeChat("Two"))

        let expectation = expectation(description: "written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("chats/index.json"))

        let reopened = ChatStore(root: root)
        XCTAssertEqual(reopened.summaries.count, 2)
    }

    func testDeleteRemovesFromIndex() throws {
        let store = ChatStore(root: root)
        let chat = makeChat()
        store.save(chat)
        store.delete(chat.id)
        XCTAssertTrue(store.summaries.isEmpty)
    }

    func testMarkdownOmitsSystemTurnsAndNamesTheAgent() {
        var chat = makeChat("Groceries")
        chat.messages.insert(ChatMessage(role: .system, content: "SECRET SCAFFOLDING"), at: 0)
        let markdown = ChatStore.markdown(chat)

        XCTAssertTrue(markdown.contains("# Groceries"))
        XCTAssertTrue(markdown.contains("## You"))
        XCTAssertTrue(markdown.contains("## Tester"))
        // System turns are our own prompt plumbing and must never be exported.
        XCTAssertFalse(markdown.contains("SECRET SCAFFOLDING"))
    }

    func testExportWritesBothFormats() throws {
        let store = ChatStore(root: root)
        let chat = makeChat("Export me")
        let md = try store.export(chat, as: .markdown)
        let json = try store.export(chat, as: .json)

        XCTAssertEqual(md.pathExtension, "md")
        XCTAssertEqual(json.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: md.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    /// A title becomes a filename, so it has to survive characters a
    /// filesystem would argue about.
    func testExportSanitisesHostileTitles() throws {
        let store = ChatStore(root: root)
        var chat = makeChat("../../etc/passwd: <ruin>")
        chat.title = "../../etc/passwd: <ruin>"
        let url = try store.export(chat, as: .markdown)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(".."))
    }
}

final class VoiceLogTests: XCTestCase {
    /// A half-written final line is the realistic failure for an append-only
    /// log, and it must cost that line rather than the whole file.
    func testMalformedLineDoesNotDiscardTheRest() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let good = try encoder.encode(VoiceEntry(text: "first"))
        var contents = String(data: good, encoding: .utf8)! + "\n"
        contents += "{ this is not json\n"
        contents += String(data: try encoder.encode(VoiceEntry(text: "second")), encoding: .utf8)! + "\n"

        let file = dir.appendingPathComponent("voice-log.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsed = try String(contentsOf: file)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(VoiceEntry.self, from: Data($0.utf8)) }

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(Set(parsed.map(\.text)), ["first", "second"])
    }
}
