import AppKit
import MarginCore
import SwiftUI

/// The review window: comments pane on the left (DiffReview's arrangement), the reply on
/// the right, and the glass composer floated directly under the selected passage.
struct MarginRootView: View {
    @ObservedObject var session: MarginSession
    @State private var composerAnchor: CGRect?

    var body: some View {
        Group {
            if session.document != nil {
                HSplitView {
                    MarginCommentsPane(
                        controller: session.review,
                        fontSize: session.fontSize,
                        onJump: { session.focus($0) }
                    )
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)

                    textPane
                        .frame(minWidth: 480, maxWidth: .infinity)
                        .layoutPriority(1)
                }
            } else {
                emptyState
            }
        }
        .navigationTitle(session.document.map { "Margin — \($0.title)" } ?? "Margin")
    }

    private var textPane: some View {
        ZStack(alignment: .topLeading) {
            ProseTextView(
                text: session.document?.text ?? "",
                fontSize: session.fontSize,
                comments: session.review.comments,
                selectedCommentID: session.review.selectedCommentID,
                focusRequest: session.focusRequest,
                onSelectionChange: { session.currentSelection = $0 },
                onSelectionRectChange: { composerAnchor = $0 },
                onClickAtOffset: { offset in
                    if let comment = session.review.comment(atOffset: offset) {
                        session.review.selectedCommentID = comment.id
                    }
                }
            )

            if session.review.draft != nil {
                GeometryReader { proxy in
                    MarginInlineComposer(controller: session.review, fontSize: session.fontSize)
                        .frame(width: min(560, max(320, proxy.size.width - 56)))
                        .offset(composerOffset(in: proxy.size))
                }
                .allowsHitTesting(true)
            }
        }
    }

    /// Under the selection when it's visible, clamped inside the pane; otherwise centered —
    /// the draft must stay reachable even if the anchor scrolled away.
    private func composerOffset(in size: CGSize) -> CGSize {
        let width = min(560, max(320, size.width - 56))
        guard let anchor = composerAnchor else {
            return CGSize(width: (size.width - width) / 2, height: size.height * 0.35)
        }
        let x = min(max(anchor.minX, 20), max(size.width - width - 20, 20))
        let y = min(max(anchor.maxY + 8, 20), max(size.height - 220, 20))
        return CGSize(width: x, height: y)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No reply open")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("margin <file.md> from Terminal, or ⌘O.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
