import SwiftUI

/// The model picker's content: pinned models by default, the whole
/// catalogue when you type, grouped by vendor. Sized to its rows — one
/// pinned model is one row — up to a ceiling, then it scrolls.
struct ModelSelector: View {
    @ObservedObject var chat: ChatController
    @Binding var query: String
    let choose: (String) -> Void

    private var showingPinned: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var matches: [String] {
        showingPinned ? chat.favouriteModels : ModelSearch.filter(chat.modelOptions, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            SelectorSearch(placeholder: "Search \(chat.modelOptions.count) models", query: $query) {
                if let first = matches.first { choose(first) }
            }
            Divider().overlay(Design.Stroke.divider)
            if showingPinned {
                SelectorHeading(title: "Pinned", trailing: "type to search all")
                SelectorList(rows: rows(matches),
                             emptyText: "Nothing pinned yet — search, then tap the star to keep a model here.",
                             maxHeight: 300, onSelect: choose, accessory: star)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if matches.isEmpty {
                            Text("No model matches “\(query)”.")
                                .font(Design.Typography.secondary())
                                .foregroundStyle(Design.Ink.tertiary)
                                .padding(Design.Space.roomy)
                        }
                        ForEach(grouped) { group in
                            SelectorHeading(title: group.vendor)
                            SelectorList(rows: rows(group.ids), maxHeight: 2000,
                                         onSelect: choose, accessory: star)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(matches.count) * 43 + CGFloat(grouped.count) * 30 + 12, 380))
            }
        }
        .selectorSurface(width: 380)
    }

    private func rows(_ ids: [String]) -> [SelectorRow] {
        ids.map { id in
            let model = chat.catalog.model(for: id)
            return SelectorRow(id: id,
                               title: ModelMeta.shortName(of: id),
                               subtitle: ModelMeta.metaLine(id, model),
                               mark: ModelMeta.vendorColor(id),
                               selected: id == chat.conversation.model)
        }
    }

    private func star(_ row: SelectorRow) -> AnyView {
        let pinned = chat.isFavourite(row.id)
        return AnyView(
            IconButton(symbol: pinned ? "star.fill" : "star", size: Design.Metric.small,
                       tint: pinned ? Design.Retro.accent : Design.Ink.faint,
                       help: pinned ? "Unpin" : "Pin to the short list") {
                chat.toggleFavourite(row.id)
            }
        )
    }

    /// Search results grouped by vendor, first-seen order kept.
    private var grouped: [ModelGroup] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for id in matches {
            let v = ModelMeta.vendorDisplay(id)
            if map[v] == nil { order.append(v) }
            map[v, default: []].append(id)
        }
        return order.map { ModelGroup(vendor: $0, ids: map[$0]!) }
    }
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
            SelectorField(label: chat.isFast ? "Fast" : "Standard",
                          detail: chat.isFast
                              ? "Quickest provider serving this model. Costs more per token."
                              : "Cheapest provider serving this model.") {
                Toggle("", isOn: Binding(get: { chat.isFast }, set: { _ in chat.toggleFast() }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Design.Retro.accent)
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

    /// Vendor · context · price: the facts you actually choose on, in that
    /// order of importance, never competing with the name.
    static func metaLine(_ id: String, _ model: ORModel?) -> String {
        var parts = [vendorDisplay(id)]
        if let c = model?.context_length, c > 0 {
            parts.append(c >= 1_000_000 ? "\(c / 1_000_000)M context"
                         : (c >= 1_000 ? "\(c / 1_000)K context" : "\(c) context"))
        }
        if let p = model?.promptPerMillion, let c = model?.completionPerMillion {
            func f(_ v: Double) -> String {
                v == 0 ? "0" : (v < 1 ? String(format: "%.2f", v) : String(format: "%.0f", v))
            }
            parts.append("$\(f(p))/\(f(c)) per M")
        }
        return parts.joined(separator: "  ·  ")
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
                       tint: pinned ? Design.Retro.accent : Design.Ink.faint,
                       help: pinned ? "Unpin" : "Pin") { chat.toggleFavourite(row.id) }
        )
    }
}
