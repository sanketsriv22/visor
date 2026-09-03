import SwiftUI

/// What a stored key is for, so the vault reads as a place with sections rather
/// than a flat list of opaque strings.
enum SecretCategory: String, CaseIterable, Identifiable, Codable {
    case agent, voice, database, cloud, connector, other

    var id: String { rawValue }
    var name: String {
        switch self {
        case .agent:     return "Agents"
        case .voice:     return "Voice"
        case .database:  return "Databases"
        case .cloud:     return "Cloud"
        case .connector: return "Connectors"
        case .other:     return "Other"
        }
    }
    var glyph: String {
        switch self {
        case .agent:     return "▚"
        case .voice:     return "◈"
        case .database:  return "▤"
        case .cloud:     return "☁"
        case .connector: return "◇"
        case .other:     return "◆"
        }
    }
}

/// One key in the vault. The value lives in the Keychain under `account`; only
/// the label and what it's for are kept here.
struct SecretMeta: Codable, Identifiable, Equatable {
    var account: String
    var label: String
    var category: SecretCategory
    /// True for the app's own built-in keys (OpenRouter, voice) — they can be
    /// set and cleared but not deleted or renamed, since features read them by
    /// a fixed account name.
    var builtin: Bool = false

    var id: String { account }
}

/// The secrets vault: every API key the app holds, each labelled and filed by
/// use. Values stay in the Keychain (via `Keychain`); this keeps the labels and
/// categories and seeds the built-in keys so they show up alongside your own.
@MainActor
final class SecretsStore: ObservableObject {
    @Published private(set) var secrets: [SecretMeta] = []

    private static let key = "visor.secrets.meta"

    init() {
        load()
        seedBuiltins()
    }

    func isSet(_ meta: SecretMeta) -> Bool { Keychain.has(meta.account) }

    /// Store (or clear, if empty) a key's value.
    func setValue(_ value: String, for account: String) {
        Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
        objectWillChange.send()
    }

    /// Add a new user key. The account is derived from the label so it's stable
    /// and human-readable in the Keychain.
    func add(label: String, category: SecretCategory, value: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var account = "secret." + trimmed
        var n = 2
        while secrets.contains(where: { $0.account == account }) {
            account = "secret.\(trimmed) \(n)"; n += 1
        }
        secrets.append(SecretMeta(account: account, label: trimmed, category: category))
        setValue(value, for: account)
        save()
    }

    func update(_ meta: SecretMeta, label: String, category: SecretCategory) {
        guard let i = secrets.firstIndex(where: { $0.account == meta.account }) else { return }
        if !meta.builtin { secrets[i].label = label.trimmingCharacters(in: .whitespacesAndNewlines) }
        secrets[i].category = category
        save()
    }

    func remove(_ meta: SecretMeta) {
        guard !meta.builtin else { return }
        Keychain.delete(meta.account)
        secrets.removeAll { $0.account == meta.account }
        save()
    }

    func grouped() -> [SecretGroup] {
        SecretCategory.allCases.compactMap { cat in
            let items = secrets.filter { $0.category == cat }
            return items.isEmpty ? nil : SecretGroup(category: cat, items: items)
        }
    }

    // MARK: Persistence (metadata only — values are in the Keychain)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([SecretMeta].self, from: data) else { return }
        secrets = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(secrets.filter { !$0.builtin }) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// The app's own keys always appear, so the vault is the one place keys live
    /// rather than these two being hidden in Agents and Voice.
    private func seedBuiltins() {
        let builtins = [
            SecretMeta(account: OpenRouterClient.sharedKeyAccount, label: "OpenRouter", category: .agent, builtin: true),
            SecretMeta(account: VoiceInput.keyAccount, label: "OpenAI — voice", category: .voice, builtin: true),
        ]
        for b in builtins where !secrets.contains(where: { $0.account == b.account }) {
            secrets.insert(b, at: 0)
        }
    }
}

/// A category and its keys, for the vault's grouped list.
struct SecretGroup: Identifiable {
    let category: SecretCategory
    let items: [SecretMeta]
    var id: String { category.rawValue }
}

// MARK: - Settings pane

struct SecretsPane: View {
    @StateObject private var store = SecretsStore()
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsHeader(
                title: "Secrets",
                subtitle: "Every API key in one vault, labelled and filed by what it's for. Values live in your macOS Keychain — never in plain text or the settings file.")

            ForEach(store.grouped()) { group in
                SettingsCard(label: group.category.name) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { i, meta in
                        SecretRow(store: store, meta: meta)
                        if i < group.items.count - 1 {
                            Rectangle().fill(Design.Retro.line).frame(height: 1).opacity(0.6)
                        }
                    }
                }
            }

            if adding {
                AddSecretForm(store: store) { adding = false }
            } else {
                Button { adding = true } label: {
                    HStack(spacing: 6) {
                        RetroIcon(Glyph.plus, size: 12, color: Design.Retro.accent)
                        Text("Add a key").font(Design.Text.rowTitle).foregroundStyle(Design.Retro.text)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SecretRow: View {
    @ObservedObject var store: SecretsStore
    let meta: SecretMeta

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                RetroIcon(meta.category.glyph, size: 11, color: Design.Retro.dim).frame(width: 16)
                Text(meta.label).font(Design.Text.rowTitle).foregroundStyle(Design.Retro.text)
                let set = store.isSet(meta)
                Text(set ? "set" : "empty")
                    .font(Design.Text.caption2)
                    .foregroundStyle(set ? Design.Retro.accent : Design.Retro.faint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(set ? Design.Retro.accentDim : Color.white.opacity(0.05)))
                Spacer(minLength: 6)
                Button { withAnimation(.easeInOut(duration: 0.12)) { editing.toggle() } } label: {
                    RetroIcon(editing ? Glyph.chevron : "▸", size: 11, color: Design.Retro.dim)
                        .frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !meta.builtin {
                    Button { store.remove(meta) } label: {
                        RetroIcon(Glyph.close, size: 12, color: Design.Retro.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            if editing {
                HStack(spacing: 8) {
                    SecureField(store.isSet(meta) ? "•••••• — type to replace" : "paste key", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        store.setValue(draft, for: meta.account); draft = ""; editing = false
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if store.isSet(meta) {
                        Button("Clear") { store.setValue("", for: meta.account) }
                    }
                }
            }
        }
    }
}

private struct AddSecretForm: View {
    @ObservedObject var store: SecretsStore
    var done: () -> Void

    @State private var label = ""
    @State private var category: SecretCategory = .connector
    @State private var value = ""

    var body: some View {
        SettingsCard(label: "New key") {
            field("Label") { TextField("e.g. Supabase, AWS", text: $label).textFieldStyle(.roundedBorder) }
            field("For") {
                Picker("", selection: $category) {
                    ForEach(SecretCategory.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().frame(width: 170)
                Spacer(minLength: 0)
            }
            field("Key") { SecureField("paste key", text: $value).textFieldStyle(.roundedBorder) }
            HStack {
                Spacer()
                Button("Cancel", action: done)
                Button("Add") {
                    store.add(label: label, category: category, value: value); done()
                }
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func field<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Design.Text.caption).foregroundStyle(Design.Retro.dim)
                .frame(width: 52, alignment: .leading)
            control()
        }
    }
}
