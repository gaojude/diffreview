import SwiftUI
import MyIDECore

/// A resolved "everywhere this symbol is used" answer, plus where on screen the question was
/// asked (the ⌘-clicked symbol's rect, in the hosting view's top-left coordinate space).
/// Rendered as a dropdown anchored next to that symbol — references never replace the view
/// being read, unlike a definition jump which opens the Explorer.
struct SymbolReferencesPresentation: Equatable {
    let symbol: String
    let references: [TSReference]
    let anchor: CGRect
}

/// The dropdown itself: a compact glass card listing each usage; clicking a row opens it.
struct ReferencesDropdownView: View {
    let symbol: String
    let references: [TSReference]
    let fontSize: CGFloat
    var onOpen: (TSReference) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                        ReferenceRow(reference: reference, fontSize: fontSize) {
                            onOpen(reference)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .onExitCommand { onDismiss() }
        .accessibilityIdentifier("references-dropdown")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text(symbol)
                .font(.system(size: max(fontSize - 1, 10), weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(references.count) place\(references.count == 1 ? "" : "s")")
                .font(.system(size: max(fontSize - 3, 9)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

/// One usage of the symbol: where it is, and the line of code, monospaced. Click to open.
struct ReferenceRow: View {
    let reference: TSReference
    let fontSize: CGFloat
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text((reference.file as NSString).lastPathComponent)
                    .font(.system(size: max(fontSize - 2, 10), weight: .medium))
                Text("line \(reference.line)")
                    .font(.system(size: max(fontSize - 3, 9)))
                    .foregroundStyle(.secondary)
                if reference.isDefinition {
                    Text("definition")
                        .font(.system(size: max(fontSize - 4, 8), weight: .semibold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }
            Text(reference.lineText.trimmingCharacters(in: .whitespaces))
                .font(.system(size: max(fontSize - 1, 10), design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.9 : 0.45))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Shared placement math for overlays anchored to a rect (dropdown, composer): below the
/// anchor when there is room, flipped above it otherwise, clamped into the container.
enum AnchoredOverlayLayout {
    static func origin(anchor: CGRect, size: CGSize, in container: CGSize) -> CGPoint {
        let below = anchor.maxY + 6
        let y = below + size.height > container.height - 8
            ? max(anchor.minY - size.height - 6, 8)
            : below
        let x = min(max(anchor.minX, 12), max(container.width - size.width - 12, 12))
        return CGPoint(x: x, y: y)
    }
}
