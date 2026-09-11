import AppKit
import Foundation
import SwiftUI

/// Whether the keys actually work, and what's left on them. "Set" was the
/// only thing Settings could say before, which is no help when OpenRouter
/// answers a chat with "out of credits". Each check is one small request:
/// OpenRouter reports the key's own usage, limit and the account's credit
/// balance; OpenAI only says whether the key is accepted.
@MainActor
final class KeyHealth: ObservableObject {
    static let shared = KeyHealth()

    enum Status: Equatable {
        case unknown, noKey, checking
        case active(String)
        case rejected(String)
        case outOfCredits(String)
        case failed(String)

        var isProblem: Bool {
            switch self {
            case .rejected, .outOfCredits, .failed: return true
            default: return false
            }
        }
    }

    @Published private(set) var openRouter: Status = .unknown
    @Published private(set) var openAI: Status = .unknown
    @Published private(set) var checkedAt: Date?
    private var checking = false

    /// Balance as OpenRouter last reported it, for the chat's own error.
    private(set) var openRouterRemaining: Double?

    func checkAll(force: Bool = false) {
        if !force, let at = checkedAt, Date().timeIntervalSince(at) < 60, !checking { return }
        guard !checking else { return }
        checking = true
        Task {
            await checkOpenRouter()
            await checkOpenAI()
            checkedAt = Date()
            checking = false
        }
    }

    func checkOpenRouter() async {
        guard let key = Keychain.get(OpenRouterClient.sharedKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { openRouter = .noKey; return }
        openRouter = .checking
        do {
            let (creditsData, creditsResponse) = try await get("https://openrouter.ai/api/v1/credits", key: key)
            if creditsResponse.statusCode == 401 || creditsResponse.statusCode == 403 {
                openRouter = .rejected("OpenRouter rejected this key (\(creditsResponse.statusCode)). Paste a current one from openrouter.ai/keys.")
                return
            }
            let credits = (try? JSONSerialization.jsonObject(with: creditsData) as? [String: Any])?["data"] as? [String: Any]
            let total = credits?["total_credits"] as? Double
            let used = credits?["total_usage"] as? Double
            let remaining = total.flatMap { t in used.map { t - $0 } }
            openRouterRemaining = remaining

            let (keyData, keyResponse) = try await get("https://openrouter.ai/api/v1/auth/key", key: key)
            let info = (try? JSONSerialization.jsonObject(with: keyData) as? [String: Any])?["data"] as? [String: Any]
            if keyResponse.statusCode == 401 || keyResponse.statusCode == 403 {
                openRouter = .rejected("OpenRouter rejected this key (\(keyResponse.statusCode)).")
                return
            }
            let keyUsage = info?["usage"] as? Double
            let keyLimit = info?["limit"] as? Double
            let free = info?["is_free_tier"] as? Bool ?? false

            var parts: [String] = []
            if let remaining {
                parts.append(String(format: "$%.2f left", max(0, remaining)))
                if let total { parts.append(String(format: "of $%.2f bought", total)) }
            }
            if let keyUsage { parts.append(String(format: "this key has used $%.2f", keyUsage)) }
            if let keyLimit { parts.append(String(format: "key limit $%.2f", keyLimit)) }
            if free { parts.append("free tier") }
            let summary = parts.isEmpty ? "Key accepted." : parts.joined(separator: " · ")

            if let remaining, remaining <= 0.005 {
                openRouter = .outOfCredits("Out of credits: \(summary). Add credits at openrouter.ai/credits.")
            } else if let keyLimit, let keyUsage, keyUsage >= keyLimit {
                openRouter = .outOfCredits("This key has hit its own limit: \(summary). Raise it at openrouter.ai/keys.")
            } else {
                openRouter = .active(summary)
            }
        } catch {
            openRouter = .failed("Couldn't reach OpenRouter: \(error.localizedDescription)")
        }
    }

    func checkOpenAI() async {
        guard let key = Keychain.get(VoiceInput.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { openAI = .noKey; return }
        openAI = .checking
        do {
            let (data, response) = try await get("https://api.openai.com/v1/models", key: key)
            switch response.statusCode {
            case 200:
                openAI = .active("Key accepted. OpenAI doesn't report balances; usage is at platform.openai.com/usage.")
            case 401, 403:
                openAI = .rejected("OpenAI rejected this key (\(response.statusCode)).")
            case 429:
                let body = String(data: data, encoding: .utf8) ?? ""
                openAI = body.contains("insufficient_quota")
                    ? .outOfCredits("OpenAI says the quota is used up. Add credit at platform.openai.com/billing.")
                    : .failed("OpenAI is rate-limiting this key right now.")
            default:
                openAI = .failed("OpenAI answered \(response.statusCode).")
            }
        } catch {
            openAI = .failed("Couldn't reach OpenAI: \(error.localizedDescription)")
        }
    }

    private func get(_ url: String, key: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse ?? HTTPURLResponse())
    }
}

/// One line under a key: a dot, what's known, and a way to check again.
struct KeyStatusRow: View {
    enum Kind { case openRouter, openAI }
    let kind: Kind
    @ObservedObject private var health = KeyHealth.shared

    private var status: KeyHealth.Status { kind == .openRouter ? health.openRouter : health.openAI }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
                .offset(y: -1)
            Text(text)
                .font(Design.Text.caption)
                .foregroundStyle(status.isProblem ? Design.Ink.warning : Design.Retro.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let link {
                Button(link.title) { NSWorkspace.shared.open(link.url) }
                    .buttonStyle(.borderless).font(Design.Text.caption)
            }
            Button(status == .checking ? "Checking…" : "Check") {
                Task {
                    if kind == .openRouter { await health.checkOpenRouter() } else { await health.checkOpenAI() }
                }
            }
            .buttonStyle(.borderless).font(Design.Text.caption)
            .disabled(status == .checking || status == .noKey)
        }
        .onAppear { health.checkAll() }
        .accessibilityIdentifier(kind == .openRouter ? "visor.keys.openrouter" : "visor.keys.openai")
    }

    private var color: Color {
        switch status {
        case .active: return Color(red: 0.36, green: 0.85, blue: 0.5)
        case .checking, .unknown: return Design.Retro.dim
        case .noKey: return Design.Ink.faint
        case .rejected, .outOfCredits, .failed: return Design.Ink.warning
        }
    }

    private var text: String {
        switch status {
        case .unknown: return "Not checked yet."
        case .noKey: return "No key saved."
        case .checking: return "Checking with \(kind == .openRouter ? "OpenRouter" : "OpenAI")…"
        case .active(let s), .rejected(let s), .outOfCredits(let s), .failed(let s): return s
        }
    }

    private var link: (title: String, url: URL)? {
        switch (kind, status) {
        case (.openRouter, .outOfCredits): return ("Add credits", URL(string: "https://openrouter.ai/credits")!)
        case (.openRouter, .active): return ("Usage", URL(string: "https://openrouter.ai/activity")!)
        case (.openAI, .active), (.openAI, .outOfCredits): return ("Billing", URL(string: "https://platform.openai.com/settings/organization/billing")!)
        default: return nil
        }
    }
}
