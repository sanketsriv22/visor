import SwiftUI

/// The selector family: model, reasoning and speed, CLI model, agent.
///
/// Four pickers had four densities, four surfaces and four ideas of what a
/// row is. This is the one list they all draw: rows at a fixed height, a
/// title with an optional second line, a leading mark, a trailing check,
/// hover and selection from the same ramp, and a height that follows the
/// content up to a ceiling and then scrolls — so a single pinned model is a
/// single row, not a mostly empty window.
struct SelectorRow: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String? = nil
    /// A small coloured dot before the title (vendor, status).
    var mark: Color? = nil
    /// An SF Symbol before the title, when a dot isn't the right mark.
    var symbol: String? = nil
    var selected = false
    /// Quiet trailing text (a shortcut, a price).
    var trailing: String? = nil
    var enabled = true
}

struct SelectorList: View {
    var rows: [SelectorRow]
    var emptyText: String = "Nothing here."
    var maxHeight: CGFloat = 340
    var onSelect: (String) -> Void
    /// Optional per-row accessory (the model picker's pin star).
    var accessory: ((SelectorRow) -> AnyView)? = nil

    private var twoLine: Bool { rows.contains { $0.subtitle != nil } }
    private var rowHeight: CGFloat { twoLine ? 42 : Design.Metric.row }

    var body: some View {
        let inset: CGFloat = Design.Space.snug
        let height = rows.isEmpty
            ? 56
            : min(CGFloat(rows.count) * (rowHeight + 1) + inset * 2, maxHeight)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if rows.isEmpty {
                    Text(emptyText)
                        .font(Design.Typography.secondary())
                        .foregroundStyle(Design.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Design.Space.roomy)
                        .padding(.vertical, Design.Space.normal)
                }
                ForEach(rows) { row in
                    SelectorRowView(row: row, height: rowHeight, accessory: accessory?(row)) {
                        onSelect(row.id)
                    }
                }
            }
            .padding(inset)
        }
        .scrollIndicators(.hidden)
        .frame(height: height)
    }
}

private struct SelectorRowView: View {
    let row: SelectorRow
    let height: CGFloat
    var accessory: AnyView?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            Button(action: action) {
                HStack(spacing: Design.Space.normal) {
                    if let mark = row.mark {
                        Circle().fill(mark).frame(width: 7, height: 7)
                    } else if let symbol = row.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: Design.Metric.iconSmall, weight: .medium))
                            .foregroundStyle(Design.Ink.secondary)
                            .frame(width: 14)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 12.5, weight: row.selected ? .semibold : .medium))
                            .foregroundStyle(row.enabled ? Design.Ink.primary : Design.Ink.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle = row.subtitle {
                            Text(subtitle)
                                .font(Design.Typography.caption())
                                .foregroundStyle(Design.Ink.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Design.Space.snug)
                    if let trailing = row.trailing {
                        Text(trailing)
                            .font(Design.Typography.caption())
                            .foregroundStyle(Design.Ink.faint)
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Design.Retro.accent)
                        .opacity(row.selected ? 1 : 0)
                        .frame(width: 12)
                }
                .padding(.horizontal, Design.Space.normal)
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.visorBare)
            .disabled(!row.enabled)

            if let accessory { accessory }
        }
        .padding(.trailing, accessory == nil ? 0 : Design.Space.tight)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(row.selected ? Design.Retro.accent.opacity(0.14)
                  : (hovering ? Design.Surface.hover : Color.clear)))
        .onHover { hovering = $0 }
        .animation(Design.Motion.quick, value: hovering)
    }
}

/// A search field at the top of a selector: borderless, an icon, Return
/// picks the first result.
struct SelectorSearch: View {
    let placeholder: String
    @Binding var query: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: Design.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Design.Metric.iconSmall, weight: .medium))
                .foregroundStyle(Design.Ink.tertiary)
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(Design.Typography.body())
                .foregroundStyle(Design.Ink.primary)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", size: Design.Metric.small,
                           tint: Design.Ink.tertiary) { query = "" }
            }
        }
        .padding(.horizontal, Design.Space.roomy)
        .frame(height: 38)
    }
}

/// A heading inside a selector ("Pinned", a vendor name).
struct SelectorHeading: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            SectionLabel(title)
            Spacer()
            if let trailing {
                Text(trailing).font(Design.Typography.caption()).foregroundStyle(Design.Ink.faint)
            }
        }
        .padding(.horizontal, Design.Space.roomy)
        .padding(.top, Design.Space.normal)
        .padding(.bottom, Design.Space.tight)
    }
}

/// The surface every selector popover wears: opaque near-black so the
/// desktop never bleeds into a list, one hairline, one radius. Applied to
/// the popover's content — the popover window supplies the arrow.
struct SelectorSurface: ViewModifier {
    var width: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .background(Design.Retro.bg)
            .tint(Design.Retro.accent)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func selectorSurface(width: CGFloat = 280) -> some View {
        modifier(SelectorSurface(width: width))
    }
}

/// A segmented choice inside a selector (reasoning effort).
struct SelectorSegments: View {
    let options: [(id: String?, label: String)]
    let selected: String?
    let onSelect: (String?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = option.id == selected
                Button { onSelect(option.id) } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Design.Ink.primary : Design.Ink.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Design.Metric.regular - 4)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control - 2, style: .continuous)
                            .fill(on ? Design.Surface.selected : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.visorBare)
                .focusable(false)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(Design.Surface.raised))
        .animation(Design.Motion.quick, value: selected)
    }
}

/// A row with a label on the left and a control on the right (speed toggle).
struct SelectorField<Control: View>: View {
    let label: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: Design.Space.roomy) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Design.Typography.secondaryMedium()).foregroundStyle(Design.Ink.primary)
                if let detail {
                    Text(detail).font(Design.Typography.caption()).foregroundStyle(Design.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Design.Space.normal)
            control()
        }
        .padding(.horizontal, Design.Space.roomy)
        .padding(.vertical, Design.Space.normal)
    }
}

/// A small chip that inserts an example request into the composer.
struct ExampleChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(Design.Typography.secondary())
                .foregroundStyle(Design.Ink.secondary)
                .padding(.horizontal, Design.Space.roomy)
                .frame(height: Design.Metric.regular)
                .raised(Design.Radius.chip)
                .contentShape(Rectangle())
        }
        .buttonStyle(.visorBare)
        .focusable(false)
    }
}

/// A text button at the regular control size: approvals, finale actions.
struct ActionChip: View {
    let title: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Design.Retro.onAccent
                                 : (destructive ? Design.Ink.destructive : Design.Ink.primary))
                .padding(.horizontal, Design.Space.roomy)
                .frame(height: Design.Metric.regular)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(prominent ? Design.Retro.accent : Design.Surface.raised))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : Design.Stroke.edge, lineWidth: Design.Stroke.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.visorBare)
        .focusable(false)
    }
}
