import SwiftUI
import AppKit

/// One segment's text, backed by `NSTextView`.
///
/// SwiftUI cannot give this row what it needs. `Text` is selectable but not
/// editable; `TextField` is editable but cannot render highlighted ranges on
/// this deployment target, and swapping between the two made a click mean
/// "edit" and stole drag-selection. `NSTextView` does all of it at once: a
/// click places a caret, a drag selects, typing edits, and search matches can
/// be highlighted while all of that is true.
///
/// It is also the groundwork for click-a-word-to-play: `NSTextView` can map a
/// point to a character index, which is what turning a click into a timestamp
/// will need. That gesture is deliberately not bound yet — there is no audio
/// to seek, and double-click already means "select word" to the system.
struct SegmentTextView: NSViewRepresentable {

    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    /// Search matches within this segment.
    let highlights: [Range<String.Index>]
    /// The one match the find bar is currently sitting on, if it is in here.
    let currentHighlight: Range<String.Index>?
    /// Called when editing finishes, so the segment can be trimmed and an
    /// emptied one removed.
    let onEditingEnded: () -> Void

    func makeNSView(context: Context) -> MeasuringTextView {
        let view = MeasuringTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        // Let the row's height follow the text rather than the other way round.
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        return view
    }

    func updateNSView(_ view: MeasuringTextView, context: Context) {
        context.coordinator.parent = self

        // Only replace the string when it really differs. Writing it back on
        // every update would reset the caret to the start mid-sentence.
        if view.string != text {
            view.string = text
        }
        apply(to: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Base attributes, then the search highlights on top.
    private func apply(to view: MeasuringTextView) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: whole)
        for range in highlights {
            guard let nsRange = Self.nsRange(of: range, in: text),
                  NSMaxRange(nsRange) <= storage.length else { continue }
            if range == currentHighlight {
                storage.addAttributes([.backgroundColor: NSColor.systemOrange,
                                       .foregroundColor: NSColor.black], range: nsRange)
            } else {
                storage.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)],
                                      range: nsRange)
            }
        }
        storage.endEditing()
        view.invalidateIntrinsicContentSize()
    }

    /// String.Index ranges are UTF-8-ish; NSTextView wants UTF-16 offsets. The
    /// transcripts are full of accented characters, so this conversion has to
    /// go through the UTF-16 view rather than character counts.
    static func nsRange(of range: Range<String.Index>, in string: String) -> NSRange? {
        guard let lower = range.lowerBound.samePosition(in: string.utf16),
              let upper = range.upperBound.samePosition(in: string.utf16) else { return nil }
        let start = string.utf16.distance(from: string.utf16.startIndex, to: lower)
        let length = string.utf16.distance(from: lower, to: upper)
        return NSRange(location: start, length: length)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SegmentTextView

        init(_ parent: SegmentTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textDidEndEditing(_ notification: Notification) {
            // Deferred: committing can delete an emptied segment, and tearing
            // the view down inside AppKit's own end-editing pass is asking for
            // trouble.
            let ended = parent.onEditingEnded
            DispatchQueue.main.async { ended() }
        }
    }
}

/// An `NSTextView` that reports the height its text actually needs, so the row
/// in the transcript can size itself. Without this the view has no intrinsic
/// height in SwiftUI and collapses.
final class MeasuringTextView: NSTextView {

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        // A blank segment still needs a line's worth of height to be clickable.
        return NSSize(width: NSView.noIntrinsicMetric, height: max(used.height, font?.boundingRectForFont.height ?? 16))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// Wrapping changes with the width, so the height has to be recomputed
    /// whenever the window is resized.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateIntrinsicContentSize()
    }
}
