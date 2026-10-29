import SwiftUI
import UniformTypeIdentifiers

/// The entry text editor. A native text view (not SwiftUI's TextEditor) so that pasting or dropping an image
/// adds a photo instead of being ignored, and so the first line is styled as the title, as in Day One.
struct DiaryTextView {
    @Binding var text: String
    var autofocus = false
    /// Mac only: false makes the text grow with its content, to sit in a larger scroll view with photos below.
    var scrolls = true
    var onImages: ([Data]) -> Void
}

private enum Style {
    #if os(iOS)
    static var body: UIFont { UIFont.preferredFont(forTextStyle: .body).withSize(18) }
    static var title: UIFont { UIFont.systemFont(ofSize: 24, weight: .bold) }
    static var color: UIColor { .label }
    #else
    static var body: NSFont { NSFont.systemFont(ofSize: 15) }
    static var title: NSFont { NSFont.systemFont(ofSize: 22, weight: .bold) }
    static var color: NSColor { .textColor }
    #endif

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        p.paragraphSpacing = 6
        return p
    }

    static func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let title = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        storage.beginEditing()
        storage.setAttributes([.font: body, .foregroundColor: color, .paragraphStyle: paragraph], range: full)
        storage.addAttribute(.font, value: Style.title, range: title)
        storage.endEditing()
    }

    static func typingAttributes(atTitle: Bool) -> [NSAttributedString.Key: Any] {
        [.font: atTitle ? title : body, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static let placeholder = "Start writing…"

    /// Same font and paragraph style as the title line, so the caret sits exactly at the placeholder's start.
    static var placeholderAttributes: [NSAttributedString.Key: Any] {
        var attrs = typingAttributes(atTitle: true)
        #if os(iOS)
        attrs[.foregroundColor] = UIColor.placeholderText
        #else
        attrs[.foregroundColor] = NSColor.placeholderTextColor
        #endif
        return attrs
    }

    static func cursorInTitle(_ text: String, _ location: Int) -> Bool {
        let ns = text as NSString
        let first = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        let end = ns.substring(with: first).hasSuffix("\n") ? first.upperBound - 1 : first.upperBound
        return location <= end
    }
}

/// Image data on a pasteboard, if the pasted thing is an image (an image file, or image data that is the
/// pasteboard's preferred representation — so copying text from Word/Pages, which also carries a picture of the
/// text, still pastes text).
private func imageData(types: [String], fileURLs: [URL], data: (String) -> Data?) -> [Data] {
    let files = fileURLs.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    if !files.isEmpty { return files.compactMap { try? Data(contentsOf: $0) } }
    guard let first = types.first.flatMap(UTType.init), first.conforms(to: .image) else { return [] }
    return data(first.identifier).map { [$0] } ?? []
}

#if os(iOS)
import UIKit

extension DiaryTextView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PasteTextView {
        let tv = PasteTextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 18, bottom: 60, right: 18)
        tv.textContainer.lineFragmentPadding = 0
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.text = text
        Style.apply(to: tv.textStorage)
        tv.typingAttributes = Style.typingAttributes(atTitle: text.isEmpty)
        tv.onImages = { [weak coordinator = context.coordinator] in coordinator?.parent.onImages($0) }
        if autofocus { DispatchQueue.main.async { tv.becomeFirstResponder() } }
        return tv
    }

    func updateUIView(_ tv: PasteTextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            tv.text = text
            Style.apply(to: tv.textStorage)
            tv.updatePlaceholder()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DiaryTextView
        init(_ parent: DiaryTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            if tv.markedTextRange == nil {
                let selection = tv.selectedRange
                Style.apply(to: tv.textStorage)
                tv.selectedRange = selection
            }
            parent.text = tv.text
            (tv as? PasteTextView)?.updatePlaceholder()
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            tv.typingAttributes = Style.typingAttributes(atTitle: Style.cursorInTitle(tv.text, tv.selectedRange.location))
        }
    }
}

final class PasteTextView: UITextView {
    var onImages: (([Data]) -> Void)?
    private let placeholderLabel = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.attributedText = NSAttributedString(string: Style.placeholder, attributes: Style.placeholderAttributes)
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updatePlaceholder() { placeholderLabel.isHidden = !text.isEmpty }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        let size = placeholderLabel.sizeThatFits(CGSize(width: bounds.width - x - textContainerInset.right, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(origin: CGPoint(x: x, y: textContainerInset.top), size: size)
        updatePlaceholder()
    }

    private var pastedImages: [Data] {
        let pb = UIPasteboard.general
        guard pb.hasImages else { return [] }
        let found = imageData(types: pb.types, fileURLs: []) { pb.data(forPasteboardType: $0) }
        if !found.isEmpty { return found }
        return pb.hasStrings ? [] : (pb.images ?? []).compactMap { $0.jpegData(compressionQuality: 0.95) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let images = pastedImages
        if images.isEmpty { super.paste(sender) } else { onImages?(images) }
    }
}

#else
import AppKit

extension DiaryTextView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        // TextKit 1, so the non-scrolling variant can measure its height with the layout manager.
        let tv = PasteNSTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.isRichText = true            // for the title style; every edit re-applies the plain styles
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.textContainerInset = NSSize(width: 28, height: 18)
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.string = text
        if let storage = tv.textStorage { Style.apply(to: storage) }
        tv.typingAttributes = Style.typingAttributes(atTitle: text.isEmpty)
        tv.onImages = { [weak coordinator = context.coordinator] in coordinator?.parent.onImages($0) }
        if autofocus { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
        guard scrolls else {
            tv.isVerticallyResizable = false
            return tv
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        tv.frame = NSRect(origin: .zero, size: scroll.contentSize)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    private static func textView(_ view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? ((view as? NSScrollView)?.documentView as? NSTextView)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        guard let tv = Self.textView(view) else { return }
        if tv.string != text {
            tv.string = text
            if let storage = tv.textStorage { Style.apply(to: storage) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !scrolls, let tv = nsView as? NSTextView, let layout = tv.layoutManager, let container = tv.textContainer
        else { return nil }
        let width = proposal.width ?? 600
        // Measure at the proposed width, then put the container back: SwiftUI probes with other widths, and the
        // container only follows the view's own frame changes.
        let current = container.containerSize
        container.containerSize = NSSize(width: max(width - 2 * tv.textContainerInset.width, 40), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = layout.usedRect(for: container).height + 2 * tv.textContainerInset.height
        container.containerSize = current
        return CGSize(width: width, height: max(ceil(height), 90))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DiaryTextView
        init(_ parent: DiaryTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if !tv.hasMarkedText(), let storage = tv.textStorage { Style.apply(to: storage) }
            parent.text = tv.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            tv.typingAttributes = Style.typingAttributes(atTitle: Style.cursorInTitle(tv.string, tv.selectedRange().location))
        }
    }
}

final class PasteNSTextView: NSTextView {
    var onImages: (([Data]) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !isVerticallyResizable, let container = textContainer {   // the auto-height (non-scrolling) variant
            container.containerSize = NSSize(width: max(newSize.width - 2 * textContainerInset.width, 40), height: .greatestFiniteMagnitude)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        let rect = NSRect(x: x, y: textContainerOrigin.y, width: bounds.width - x - textContainerInset.width, height: 60)
        NSAttributedString(string: Style.placeholder, attributes: Style.placeholderAttributes).draw(in: rect)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]

    private func images(on pb: NSPasteboard) -> [Data] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return imageData(types: pb.types?.map(\.rawValue) ?? [], fileURLs: urls) { pb.data(forType: .init($0)) }
    }

    override func paste(_ sender: Any?) {
        let found = images(on: .general)
        if found.isEmpty { pasteAsPlainText(sender) } else { onImages?(found) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + Self.imageTypes + [.fileURL]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = images(on: sender.draggingPasteboard)
        if found.isEmpty { return super.performDragOperation(sender) }
        onImages?(found)
        return true
    }

    // Continuity Camera: Edit/context menu → "Import from iPhone" → Take Photo / Scan Documents.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, Self.imageTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        let found = images(on: pboard)
        if found.isEmpty { return super.readSelection(from: pboard) }
        onImages?(found)
        return true
    }
}
#endif
