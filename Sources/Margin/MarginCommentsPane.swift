import AppKit
import MarginCore
import SwiftUI

/// The left panel: the running list of review comments on the reply. Composing happens
/// inline in the text; this list is for rereading, jumping back to the quoted passage, and
/// copying the whole review as one prompt-ready block for the agent. Adapted from
/// DiffReview's `CommentsPaneView`.
struct MarginCommentsPane: View {
    @ObservedObject var controller: MarginReviewController
    let fontSize: CGFloat
    var onJump: (ProseComment) -> Void = { _ in }
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.comments.isEmpty {
                emptyState
            } else {
                commentList
            }
        }
        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("margin-comments-pane")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Comments")
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            if !controller.comments.isEmpty {
                Text("\(controller.comments.count)")
                    .font(.system(size: max(fontSize - 3, 9), weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    .fixedSize()
            }
            Spacer(minLength: 8)

            Button {
                controller.copyAllToPasteboard()
            } label: {
                Label(
                    controller.justCopied ? "Copied" : "Copy",
                    systemImage: controller.justCopied ? "checkmark" : "doc.on.doc"
                )
                .font(.system(size: max(fontSize - 2, 10)))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.canCopy)
            .help("Copy the review — paste it into the agent to revise the reply")
            .accessibilityIdentifier("margin-copy-button")

            Button {
                showClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: max(fontSize - 3, 10)))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(controller.comments.isEmpty)
            .help("Clear all comments")
            .confirmationDialog(
                "Clear all comments?",
                isPresented: $showClearConfirmation
            ) {
                Button("Clear All", role: .destructive) {
                    controller.clearAll()
                }
            } message: {
                Text("This removes every comment in this review.")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No comments yet")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select any passage — down to a single\nword — and press ⌘K.")
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
    }

    private var commentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(controller.comments.enumerated()), id: \.element.id) { index, comment in
                        ProseCommentCard(
                            comment: comment,
                            index: index + 1,
                            fontSize: fontSize,
                            isSelected: controller.selectedCommentID == comment.id,
                            onDelete: { controller.delete(comment.id) }
                        )
                        .id(comment.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onJump(comment)
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
            .onChange(of: controller.selectedCommentID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// One comment: its number in the review, the passage it quotes, and what the reviewer
/// said. Clicking it jumps the text to those exact characters.
private struct ProseCommentCard: View {
    let comment: ProseComment
    /// 1-based position in the review — matches the numbering of the copied prompt block.
    let index: Int
    let fontSize: CGFloat
    let isSelected: Bool
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index)")
                    .font(.system(size: max(fontSize - 3, 9), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                Text(comment.lineLabel)
                    .font(.system(size: max(fontSize - 3, 9)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if isHovering || isSelected {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(comment.body, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy comment text")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete comment")
                }
            }

            quote

            // Deliberately NOT .textSelection(.enabled): selecting a long card wedges the
            // main thread in a SwiftUI transaction storm on macOS 26 (see DiffReview's
            // CommentCard for the sampled reproduction). The copy button covers it.
            Text(comment.body)
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.95 : 0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected
                        ? Color.accentColor.opacity(0.7)
                        : Color(nsColor: .separatorColor).opacity(isHovering ? 0.7 : 0.35),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .onHover { isHovering = $0 }
        .help("Jump to this passage")
    }

    /// The quoted passage, single-spaced and truncated — the card shows *what* was
    /// selected; the highlight in the text shows where.
    private var quote: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.teal.opacity(0.75))
                .frame(width: 3)
            Text(comment.quotedText.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The comment composer, floated inline directly under the selected passage. The words
/// under discussion stay visible in place — the card only asks what should change.
struct MarginInlineComposer: View {
    @ObservedObject var controller: MarginReviewController
    let fontSize: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = controller.draft {
                Text(draft.selection.lineLabel)
                    .font(.system(size: max(fontSize - 3, 9), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            editor

            HStack(spacing: 8) {
                Text("⏎ new line · ⌘⏎ comment")
                    .font(.system(size: max(fontSize - 4, 8)))
                    .foregroundStyle(.quaternary)
                Spacer(minLength: 0)
                Button("Cancel") {
                    controller.cancelDraft()
                }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)

                Button("Comment") {
                    controller.commitDraft()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(controller.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("margin-composer-submit")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .accessibilityIdentifier("margin-inline-composer")
    }

    /// Multi-line editor sized by an invisible mirror of its content: Return inserts a new
    /// line (submission is ⌘⏎ only), the card grows with the text, and past ~6 lines the
    /// editor scrolls internally.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            Text(mirrorText)
                .font(.system(size: fontSize))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(0)

            TextEditor(text: $controller.draftText)
                .font(.system(size: fontSize))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .accessibilityIdentifier("margin-composer-input")

            if controller.draftText.isEmpty {
                Text("What should change here?")
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: fontSize + 12, maxHeight: (fontSize + 5) * 6)
    }

    /// Non-empty stand-in so a trailing newline still counts as a line while sizing.
    private var mirrorText: String {
        if controller.draftText.isEmpty { return " " }
        if controller.draftText.hasSuffix("\n") { return controller.draftText + " " }
        return controller.draftText
    }
}
