import XCTest
@testable import Visor

final class KnowledgeBaseTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-kb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func conversation() -> Conversation {
        Conversation(title: "Memory", agentName: "Tester", model: "test/model")
    }

    /// Recall is best-effort by design: with no embedding model for the
    /// locale everything must degrade to "no results", never to a crash.
    func testRecallIsSafeWhenEmpty() {
        let kb = KnowledgeBase(root: root)
        XCTAssertTrue(kb.recall("anything").isEmpty)
        XCTAssertNil(kb.context(for: "anything"))
    }

    func testShortTurnsAreNotIndexed() throws {
        let kb = KnowledgeBase(root: root)
        let chat = conversation()
        kb.index(ChatMessage(role: .user, content: "ok"), in: chat)
        // Too short to be worth recalling, so nothing to recall.
        XCTAssertTrue(kb.recall("ok").isEmpty)
    }

    func testSystemTurnsAreNeverIndexed() throws {
        let kb = KnowledgeBase(root: root)
        let chat = conversation()
        let system = ChatMessage(
            role: .system,
            content: "This is internal scaffolding that is definitely long enough to index.")
        kb.index(system, in: chat)
        XCTAssertTrue(kb.recall("scaffolding").isEmpty)
    }

    /// Deleting a chat has to actually forget it — the whole promise of the
    /// delete button.
    func testForgetRemovesAConversation() throws {
        let kb = KnowledgeBase(root: root)
        guard kb.isAvailable else {
            throw XCTSkip("No sentence-embedding model on this machine")
        }
        let chat = conversation()
        let message = ChatMessage(
            role: .user,
            content: "The kitchen tap has been dripping since last Thursday and needs a new washer.")
        kb.index(message, in: chat)
        // minimumScore 0: this is testing that forget() removes an entry, not
        // how semantically close Apple's embedding thinks two phrases are.
        // Threshold-dependent assertions make the test a verdict on the OS.
        XCTAssertFalse(kb.recall("dripping tap washer", minimumScore: 0).isEmpty)

        kb.forget(conversation: chat.id)
        XCTAssertTrue(kb.recall("dripping tap washer", minimumScore: 0).isEmpty)
    }

    /// Recall excludes the conversation in progress, whose recent turns are
    /// already in the prompt verbatim.
    func testRecallExcludesTheCurrentConversation() throws {
        let kb = KnowledgeBase(root: root)
        guard kb.isAvailable else {
            throw XCTSkip("No sentence-embedding model on this machine")
        }
        let chat = conversation()
        kb.index(ChatMessage(
            role: .user,
            content: "Remember that the spare key is under the third plant pot by the door."),
                 in: chat)

        XCTAssertFalse(kb.recall("where is the spare key", minimumScore: 0).isEmpty)
        XCTAssertTrue(
            kb.recall("where is the spare key", excluding: chat.id, minimumScore: 0).isEmpty)
    }
}
