import AppKit
import SwiftUI
import MyIDECore

/// The left panel: the running list of review comments. Auto-shown with the first comment
/// (the toolbar button toggles it any time). Composing happens inline in the editor; this
/// list is for rereading, jumping back to code, and copying the whole review as one
/// prompt-ready block for a coding agent.
struct CommentsPaneView: View {
    @ObservedObject var controller: ReviewCommentsController
    let fontSize: CGFloat
    var onJump: (ReviewComment) -> Void = { _ in }
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
        .accessibilityIdentifier("comments-pane")
    }

    // MARK: - Header

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
            .help("Copy all comments — paste them into a coding agent to apply the changes")
            .accessibilityIdentifier("copy-comments-button")

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

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No comments yet")
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select lines in the diff and press ⌘K\nor click the ＋ bubble.")
                .font(.system(size: max(fontSize - 2, 10)))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
    }

    // MARK: - List

    private var commentList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(controller.comments.enumerated()), id: \.element.id) { index, comment in
                        CommentCard(
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

/// The comment composer, floated inline in the editor directly under the selected lines. The
/// code under discussion stays visible in place — the card only asks for the words.
struct InlineCommentComposer: View {
    @ObservedObject var controller: ReviewCommentsController
    let fontSize: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = controller.draft {
                Text("\((draft.filePath as NSString).lastPathComponent) · \(draft.lineLabel)")
                    .font(.system(size: max(fontSize - 3, 9), weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                .accessibilityIdentifier("comment-composer-submit")
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .accessibilityIdentifier("inline-comment-composer")
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
                .accessibilityIdentifier("comment-composer-input")

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

/// One comment: its number in the review, where it lives, the code it points at, and what
/// the reviewer said. Clicking it jumps the code view to those exact lines.
private struct CommentCard: View {
    let comment: ReviewComment
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
                Text(fileName)
                    .font(.system(size: max(fontSize - 1, 10), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .help(comment.filePath)

            snippet

            // Deliberately NOT .textSelection(.enabled): on macOS 26, the selection overlay
            // of a long selected card re-invalidates its font metrics every display cycle,
            // wedging the main thread in an endless SwiftUI transaction storm (100% CPU
            // freeze — reproduced and sampled from a real review). The copy button covers
            // getting the text out.
            Text(comment.body)
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)

            if !comment.replies.isEmpty {
                replies
            }
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
        .help("Jump to this code")
    }

    private var fileName: String {
        (comment.filePath as NSString).lastPathComponent
    }

    /// Replies sent from outside the app (`diffreview respond`) — the agent answering the
    /// comment. Indented under the reviewer's text with a purple accent bar so the two
    /// voices in the thread stay visually distinct. Same no-.textSelection rule as the body.
    private var replies: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(comment.replies) { reply in
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.purple.opacity(0.6))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Agent", systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: max(fontSize - 4, 8), weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(reply.body)
                            .font(.system(size: max(fontSize - 1, 10)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.purple.opacity(0.07))
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.leading, 10)
    }

    /// The commented code, dedented so deeply indented selections don't read as noise, with
    /// a teal accent bar matching the marker bars in the diff gutter.
    private var snippet: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.teal.opacity(0.75))
                .frame(width: 3)
            Text(Self.dedent(comment.codeText))
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

    /// Strips the whitespace indentation common to every non-empty line, and any blank
    /// leading/trailing lines — the snippet shows *what* the code is, not where it sat.
    static func dedent(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        let indents = lines.compactMap { line -> Int? in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }
        let common = indents.min() ?? 0
        guard common > 0 else { return lines.joined(separator: "\n") }
        return lines
            .map { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty
                    ? ""
                    : String(line.dropFirst(min(common, line.prefix(while: { $0 == " " || $0 == "\t" }).count)))
            }
            .joined(separator: "\n")
    }
}
