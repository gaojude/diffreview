import SwiftUI

struct PromptFixListView: View {
    @ObservedObject var accumulator: PromptAccumulatorController
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if accumulator.items.isEmpty {
                emptyState
            } else {
                fixList
                Divider()
                preview
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("prompt-fixes-pane")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Fixes")
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: max(fontSize - 2, 10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                accumulator.copySelectedToPasteboard()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("c", modifiers: .command)
            .disabled(accumulator.selectedItemIDs.isEmpty)
            .help("Copy selected prompts")

            Button {
                accumulator.removeSelected()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(accumulator.selectedItemIDs.isEmpty)
            .help("Delete selected fixes")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var fixList: some View {
        List(selection: $accumulator.selectedItemIDs) {
            ForEach(accumulator.items) { item in
                PromptFixRow(item: item, fontSize: fontSize)
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 150)
        .onDeleteCommand {
            accumulator.removeSelected()
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(previewTitle)
                    .font(.system(size: max(fontSize - 1, 11), weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                Text(previewText)
                    .font(.system(size: max(fontSize - 3, 10), design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(minHeight: 150, idealHeight: 220, maxHeight: 280)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No fixes yet")
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
            Text("Ready for handoff prompts.")
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        let count = accumulator.items.count
        let selected = accumulator.selectedItemIDs.count
        if count == 0 { return "Nothing captured" }
        if selected == 0 {
            return count == 1 ? "1 prompt captured" : "\(count) prompts captured"
        }
        return selected == 1 ? "1 selected" : "\(selected) selected"
    }

    private var previewTitle: String {
        let selected = accumulator.selectedItemIDs.count
        if selected == 0 { return "Prompt Preview" }
        return selected == 1 ? "Selected Prompt" : "\(selected) Selected Prompts"
    }

    private var previewText: String {
        accumulator.selectedPromptText ?? "Select a fix to preview its prompt."
    }
}

private struct PromptFixRow: View {
    let item: PromptFixItem
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: max(fontSize - 4, 9)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(item.location)
                .font(.system(size: max(fontSize - 3, 10), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.requestedChange)
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}
