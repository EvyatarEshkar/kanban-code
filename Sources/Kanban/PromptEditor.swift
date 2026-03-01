import SwiftUI
import AppKit

/// A TextEditor replacement where Enter submits and Shift+Enter inserts a newline.
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var placeholder: String = ""
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = SubmitTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit

        scrollView.documentView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmitTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.font = font

        // Update placeholder
        context.coordinator.placeholder = placeholder
        context.coordinator.updatePlaceholder(textView)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        var placeholder: String = ""

        init(_ parent: PromptEditor) {
            self.parent = parent
            self.placeholder = parent.placeholder
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder(textView)
        }

        func updatePlaceholder(_ textView: NSTextView) {
            // Use the attributedPlaceholder approach via insertion point color
            if textView.string.isEmpty && !placeholder.isEmpty {
                textView.insertionPointColor = .tertiaryLabelColor
            } else {
                textView.insertionPointColor = .labelColor
            }
        }
    }
}

/// NSTextView subclass that intercepts Return key for submit behavior.
final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 // Return key
        let hasShift = event.modifierFlags.contains(.shift)

        if isReturn && !hasShift {
            // Enter without Shift → submit
            onSubmit()
            return
        }

        if isReturn && hasShift {
            // Shift+Enter → insert newline
            insertNewline(nil)
            return
        }

        super.keyDown(with: event)
    }
}
