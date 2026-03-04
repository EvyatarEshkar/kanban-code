import SwiftUI
import AppKit

/// Invisible AppKit-based overlay that detects folder drags from Finder.
/// Uses NSView's `registerForDraggedTypes` so it works regardless of SwiftUI's
/// nested `.onDrop` hierarchy (which would otherwise be intercepted by column drop zones).
struct FolderDropZone: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var onDrop: (URL) -> Void

    func makeNSView(context: Context) -> FolderDropNSView {
        let view = FolderDropNSView()
        view.onTargetChanged = { targeted in
            Task { @MainActor in isTargeted = targeted }
        }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: FolderDropNSView, context: Context) {
        view.onDrop = onDrop
    }
}

final class FolderDropNSView: NSView {
    var onTargetChanged: ((Bool) -> Void)?
    var onDrop: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL(from: sender) != nil else { return [] }
        onTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL(from: sender) != nil else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChanged?(false)
        guard let url = folderURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    private func folderURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = urls.first else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }
}
