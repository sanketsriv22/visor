import SwiftUI

/// The model picker's content: pinned models by default, the whole
/// catalogue when you type, grouped by vendor. Sized to its rows — one
/// pinned model is one row — up to a ceiling, then it scrolls.
struct ModelSelector: View {
    @ObservedObject var chat: ChatController
    @Binding var query: String
    let choose: (String) -> Void

    @State private var page: String? = "models"
    @State private var endpoints: [OREndpoint] = []
    @State private var endpointsError: String?
    @State private var loadingEndpoints = false

    private var showingPinned: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var matches: [String] {
        showingPinned ? chat.favouriteModels : ModelSearch.filter(chat.modelOptions, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectorSegments(options: [("models", "Models"), ("providers", "Providers")],
                             selected: page) { page = $0 }
                .padding(.horizontal, Design.Space.roomy)
                .padding(.vertical, Design.Space.tight)
            Divider().overlay(Design.Stroke.divider)
            if page == "providers" {
                providers
            } else {
                search
                Divider().overlay(Design.Stroke.divider)
                if showingPinned { pinned } else { results }
            }
        }
        .selectorSurface(width: 420)
        // The catalogue is what carries prices and context windows; make
        // sure it's here by the time the list is read.
        .task { await chat.loadModels() }
    }

    private var search: some View {
        SelectorSearch(placeholder: "Search \(chat.modelOptions.count) models", query: $query) {
            if let first = matches.first { choose(first) }
        }
    }

    private var pinned: some View {
        VStack(spacing: 0) {
            SelectorHeading(title: "Pinned", trailing: "$ in · out per M tokens")
            SelectorList(rows: rows(matches),
                         emptyText: "Nothing pinned yet — search, then tap the star to keep a model here.",
                         maxHeight: 300, onSelect: choose, accessory: star)
        }
    }

    private var results: some View {
        let groups = grouped
        let height: CGFloat = min(CGFloat(matches.count) * 43 + CGFloat(groups.count) * 30 + 12, 380)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if matches.isEmpty {
                    Text("No model matches “\(query)”.")
                        .font(Design.Typography.secondary())
                        .foregroundStyle(Design.Ink.tertiary)
                        .padding(Design.Space.roomy)
                }
                ForEach(groups) { group in
                    SelectorHeading(title: group.vendor, trailing: "$ in · out per M")
                    SelectorList(rows: rows(group.ids), maxHeight: 2000,
                                 onSelect: choose, accessory: star)
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: height)
    }

    // MARK: Providers

    /// Every provider serving the current model, with its own price and
    /// limits, and the two automatic choices above them.
    private var providers: some View {
        let model = chat.conversation.model
        let fast = chat.isFast
        let pinnedTo = chat.providerPreference
        var list: [SelectorRow] = [
            SelectorRow(id: "__auto", title: "Automatic — cheapest first",
                        subtitle: "OpenRouter routes to the lowest price serving \(ModelMeta.shortName(of: model))",
                        symbol: "arrow.triangle.branch", selected: pinnedTo == nil && !fast),
            SelectorRow(id: "__fast", title: "Automatic — fastest",
                        subtitle: "Highest throughput, whatever it costs",
                        symbol: "bolt", selected: pinnedTo == nil && fast),
        ]
        list += endpoints.map { e in
            SelectorRow(id: e.providerLabel, title: e.providerLabel,
                        subtitle: ModelMeta.endpointMeta(e),
                        mark: ModelMeta.vendorColor(model),
                        selected: pinnedTo == e.providerLabel,
                        trailing: ModelMeta.priceLabel(prompt: e.promptPerMillion, completion: e.completionPerMillion))
        }
        return VStack(spacing: 0) {
            SelectorHeading(title: "Providers for \(ModelMeta.shortName(of: model))",
                            trailing: loadingEndpoints ? "loading…" : "$ in · out per M")
            if let endpointsError, endpoints.isEmpty {
                Text(endpointsError)
                    .font(Design.Typography.secondary())
                    .foregroundStyle(Design.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Design.Space.roomy)
            }
            SelectorList(rows: list, maxHeight: 380) { id in
                switch id {
                case "__auto":
                    chat.useProvider(nil)
                    if chat.isFast { chat.toggleFast() }
                case "__fast":
                    chat.useProvider(nil)
                    if !chat.isFast { chat.toggleFast() }
                default:
                    chat.useProvider(id)
                }
            }
            Divider().overlay(Design.Stroke.divider)
            Text(pinnedTo.map { "Every request goes to \($0), with no fallback." }
                 ?? "The choice is kept per agent, and shown here whenever you pick a model.")
                .font(Design.Typography.caption())
                .foregroundStyle(Design.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.roomy)
                .padding(.vertical, Design.Space.normal)
        }
        .task(id: model) { await loadEndpoints(for: model) }
    }

    private func loadEndpoints(for model: String) async {
        loadingEndpoints = true
        endpointsError = nil
        do {
            let found = try await OpenRouterClient().endpoints(for: model)
            endpoints = found.sorted { ($0.promptPerMillion ?? 0) < ($1.promptPerMillion ?? 0) }
            if endpoints.isEmpty { endpointsError = "OpenRouter lists no providers for this model." }
        } catch {
            endpointsError = (error as? ChatError)?.localizedDescription ?? error.localizedDescription
        }
        loadingEndpoints = false
    }

    private func rows(_ ids: [String]) -> [SelectorRow] {
        ids.map { id in
            let model = chat.catalog.model(for: id)
            return SelectorRow(id: id,
                               title: ModelMeta.shortName(of: id),
                               subtitle: ModelMeta.metaLine(id, model),
                               mark: ModelMeta.vendorColor(id),
                               selected: id == chat.conversation.model,
                               trailing: ModelMeta.priceLabel(prompt: model?.promptPerMillion,
                                                              completion: model?.completionPerMillion))
        }
    }

    private func star(_ row: SelectorRow) -> AnyView {
        let pinned = chat.isFavourite(row.id)
        return AnyView(
            IconButton(symbol: pinned ? "star.fill" : "star", size: Design.Metric.small,
                       tint: pinned ? Design.Retro.glassAccent : Design.Ink.faint,
                       help: pinned ? "Unpin" : "Pin to the short list") {
                chat.toggleFavourite(row.id)
            }
        )
    }

    /// Search results grouped by vendor, first-seen order kept.
    private var grouped: [VendorGroup] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for id in matches {
            let v = ModelMeta.vendorDisplay(id)
            if map[v] == nil { order.append(v) }
            map[v, default: []].append(id)
        }
        return order.map { VendorGroup(vendor: $0, ids: map[$0] ?? []) }
    }
}

struct VendorGroup: Identifiable {
    let vendor: String
    let ids: [String]
    var id: String { vendor }
}

/// Reasoning effort and provider speed: the two things you might change
/// about a message that aren't the model. Same rows and surface as every
/// other selector.
struct OptionsSelector: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 0) {
            if chat.supportsEffort {
                SelectorHeading(title: "Reasoning")
                SelectorSegments(
                    options: ChatController.effortLevels.map { ($0, Self.label(for: $0)) },
                    selected: chat.effort) { chat.useEffort($0) }
                    .padding(.horizontal, Design.Space.roomy)
                    .padding(.bottom, Design.Space.normal)
                    .help("How hard this model thinks before answering")
                Divider().overlay(Design.Stroke.divider)
            }
            SelectorField(label: chat.isFast ? "Fast" : (chat.providerPreference.map { "Via \($0)" } ?? "Standard"),
                          detail: chat.isFast
                              ? "Quickest provider serving this model. Costs more per token."
                              : (chat.providerPreference != nil
                                 ? "Pinned under the model picker's Providers tab."
                                 : "Cheapest provider serving this model.")) {
                Toggle("", isOn: Binding(get: { chat.isFast }, set: { _ in chat.toggleFast() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Design.Retro.glassAccent)
            }
        }
        .padding(.vertical, Design.Space.tight)
        .selectorSurface(width: 280)
    }

    static func label(for level: String?) -> String {
        switch level {
        case "low":    return "Low"
        case "medium": return "Medium"
        case "high":   return "High"
        default:       return "Auto"
        }
    }
}

/// Facts about a model id, shared by the picker and the chip.
enum ModelMeta {
    static func shortName(of id: String) -> String {
        id.contains("/") ? String(id.split(separator: "/").dropFirst().joined(separator: "/")) : id
    }

    static func vendorDisplay(_ id: String) -> String {
        let raw = id.split(separator: "/").first.map(String.init) ?? ""
        switch raw.lowercased() {
        case "openai":     return "OpenAI"
        case "anthropic":  return "Anthropic"
        case "google":     return "Google"
        case "meta-llama": return "Meta"
        case "mistralai":  return "Mistral"
        case "x-ai":       return "xAI"
        case "deepseek":   return "DeepSeek"
        case "qwen":       return "Qwen"
        case "":           return "Other"
        default:           return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    static func vendorColor(_ id: String) -> Color {
        let vendor = (id.split(separator: "/").first.map { $0.lowercased() }) ?? ""
        switch vendor {
        case "anthropic":  return Color(red: 0.83, green: 0.52, blue: 0.30)
        case "openai":     return Color(red: 0.40, green: 0.78, blue: 0.62)
        case "google":     return Color(red: 0.36, green: 0.60, blue: 0.98)
        case "meta-llama": return Color(red: 0.30, green: 0.50, blue: 0.95)
        case "mistralai":  return Color(red: 0.98, green: 0.55, blue: 0.20)
        case "x-ai":       return Color.white.opacity(0.7)
        case "deepseek":   return Color(red: 0.30, green: 0.45, blue: 0.95)
        default:           return Color.white.opacity(0.4)
        }
    }

    /// Vendor · context · what it takes: the price has its own column.
    static func metaLine(_ id: String, _ model: ORModel?) -> String {
        var parts = [vendorDisplay(id)]
        if let c = model?.context_length, c > 0 { parts.append(contextLabel(c)) }
        var can: [String] = []
        if model?.supportsTools == true { can.append("tools") }
        if model?.supportsVision == true { can.append("vision") }
        if model?.supportsReasoning == true { can.append("reasoning") }
        if !can.isEmpty { parts.append(can.joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    static func contextLabel(_ c: Int) -> String {
        c >= 1_000_000 ? "\(c / 1_000_000)M context" : (c >= 1_000 ? "\(c / 1_000)K context" : "\(c) context")
    }

    /// "$3 · $15" — dollars per million tokens in, then out. Nil until the
    /// catalogue has loaded; the column stays empty rather than guessing.
    static func priceLabel(prompt: Double?, completion: Double?) -> String? {
        guard let p = prompt, let c = completion else { return nil }
        func f(_ v: Double) -> String {
            v == 0 ? "free" : (v < 1 ? String(format: "$%.2f", v) : (v < 10 ? String(format: "$%.1f", v) : String(format: "$%.0f", v)))
        }
        return "\(f(p)) · \(f(c))"
    }

    /// A provider's limits, for its second line.
    static func endpointMeta(_ e: OREndpoint) -> String {
        var parts: [String] = []
        if let c = e.context_length, c > 0 { parts.append(contextLabel(c)) }
        if let m = e.max_completion_tokens, m > 0 { parts.append("\(m >= 1_000 ? "\(m / 1_000)K" : "\(m)") max out") }
        if let u = e.uptime_last_30m { parts.append(String(format: "%.0f%% up", u)) }
        return parts.isEmpty ? "No details from OpenRouter" : parts.joined(separator: "  ·  ")
    }
}

/// A local CLI agent's model list: the snapshot we ship, pinned first,
/// and always a way to use a name the list doesn't know — every CLI knows
/// models this snapshot doesn't.
struct CLISelector: View {
    @ObservedObject var chat: ChatController
    @Binding var query: String
    let dismiss: () -> Void

    private var groups: [CLICatalogue.Group] { chat.cliGroups(matching: query) }
    private var typed: String { query.trimmingCharacters(in: .whitespaces) }
    private var noMatches: Bool { groups.isEmpty && !typed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SelectorSearch(placeholder: "Search models", query: $query, onSubmit: useTyped)
            Divider().overlay(Design.Stroke.divider)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        SelectorHeading(title: group.id)
                        SelectorList(rows: rows(group.models), maxHeight: 2000, onSelect: pick, accessory: star)
                    }
                    if groups.isEmpty && query.isEmpty {
                        Text("No suggestions for this agent yet — type a model name it accepts, then pin it.")
                            .font(Design.Typography.secondary())
                            .foregroundStyle(Design.Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Design.Space.roomy)
                    }
                    if noMatches {
                        SelectorList(rows: [SelectorRow(id: "__typed", title: "Use “\(typed)”",
                                                        symbol: "return")],
                                     maxHeight: 60) { _ in useTyped() }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(groups.reduce(0) { $0 + $1.models.count }) * 43
                               + CGFloat(groups.count) * 30 + (noMatches ? 44 : 0) + 12, 340))
            Divider().overlay(Design.Stroke.divider)
            Text("Starts a new chat — the CLI fixes its model when a session begins.")
                .font(Design.Typography.caption())
                .foregroundStyle(Design.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Space.roomy)
                .padding(.vertical, Design.Space.normal)
        }
        .selectorSurface(width: 320)
    }

    private func rows(_ models: [CLICatalogue.Model]) -> [SelectorRow] {
        models.map { model in
            SelectorRow(id: model.id, title: model.title,
                        subtitle: model.note ?? model.id,
                        selected: model.id == chat.cliModelID)
        }
    }

    private func pick(_ id: String) {
        chat.useCLIModel(id)
        dismiss()
    }

    private func useTyped() {
        guard !typed.isEmpty else { return }
        chat.useCLIModel(typed)
        dismiss()
    }

    private func star(_ row: SelectorRow) -> AnyView {
        guard row.id != "__typed" else { return AnyView(EmptyView()) }
        let pinned = chat.isFavourite(row.id)
        return AnyView(
            IconButton(symbol: pinned ? "star.fill" : "star", size: Design.Metric.small,
                       tint: pinned ? Design.Retro.glassAccent : Design.Ink.faint,
                       help: pinned ? "Unpin" : "Pin") { chat.toggleFavourite(row.id) }
        )
    }
}
