#if os(iOS)
import NativeBlockEditorEngine
import SwiftUI
import UIKit

enum InlineFormat: String, CaseIterable, Identifiable {
    case bold
    case italic
    case underline
    case strikethrough
    case code

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .code: "Inline code"
        }
    }
}

@MainActor
final class RichTextEditingSession: ObservableObject {
    @Published private(set) var activePath: BlockPath?
    @Published private(set) var selectedFormats: Set<InlineFormat> = []
    @Published private(set) var selectedInlineAttributes: TextAttributes = [:]
    @Published private(set) var selectedTextRange: NSRange?
    @Published private(set) var selectedText: String?

    private weak var textView: UITextView?
    private var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    private var defaultColor: UIColor = .label
    private var semanticStrikethrough = false
    private var typingInlineAttributes: TextAttributes = [:]
    private var commit: ((TextDelta) -> Void)?

    func activate(
        textView: UITextView,
        path: BlockPath,
        baseFont: UIFont,
        defaultColor: UIColor,
        semanticStrikethrough: Bool,
        commit: @escaping (TextDelta) -> Void
    ) {
        let isNewEditor = self.textView !== textView || activePath != path
        self.textView = textView
        if activePath != path {
            activePath = path
        }
        self.baseFont = baseFont
        self.defaultColor = defaultColor
        self.semanticStrikethrough = semanticStrikethrough
        self.commit = commit
        if isNewEditor {
            typingInlineAttributes = inlineAttributesAtCaret(in: textView, fallback: [:])
        }
        applyTypingAttributes(to: textView)
        refreshSelectedFormats()
    }

    func updateConfiguration(
        for textView: UITextView,
        baseFont: UIFont,
        defaultColor: UIColor,
        semanticStrikethrough: Bool,
        commit: @escaping (TextDelta) -> Void
    ) {
        guard self.textView === textView else { return }
        self.baseFont = baseFont
        self.defaultColor = defaultColor
        self.semanticStrikethrough = semanticStrikethrough
        self.commit = commit
        applyTypingAttributes(to: textView)
    }

    func deactivate(_ textView: UITextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        if activePath != nil { activePath = nil }
        if !selectedFormats.isEmpty { selectedFormats = [] }
        if !selectedInlineAttributes.isEmpty { selectedInlineAttributes = [:] }
        selectedTextRange = nil
        selectedText = nil
        typingInlineAttributes = [:]
        commit = nil
    }

    func dismissKeyboard() {
        textView?.resignFirstResponder()
    }

    func toggle(_ format: InlineFormat) {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length == 0 {
            let enabled = RichTextCodec.isEnabled(format, in: typingInlineAttributes)
            RichTextCodec.set(
                format,
                enabled: !enabled,
                in: &typingInlineAttributes
            )
            applyTypingAttributes(to: textView)
            refreshSelectedFormats()
            return
        }

        let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
        let shouldEnable = !selectionContains(format, attributed: attributed, range: range)
        attributed.enumerateAttribute(
            RichTextCodec.inlineAttributesKey,
            in: range,
            options: []
        ) { value, effectiveRange, _ in
            var inline = RichTextCodec.decodeInlineAttributes(value)
            RichTextCodec.set(format, enabled: shouldEnable, in: &inline)
            attributed.setAttributes(
                RichTextCodec.visualAttributes(
                    for: inline,
                    baseFont: baseFont,
                    paragraphStyle: RichTextCodec.paragraphStyle(
                        from: attributed.attributes(at: effectiveRange.location, effectiveRange: nil)
                    ),
                    defaultColor: defaultColor,
                    semanticStrikethrough: semanticStrikethrough
                ),
                range: effectiveRange
            )
        }

        textView.attributedText = attributed
        textView.selectedRange = range
        commit?(RichTextCodec.delta(from: attributed))
        refreshSelectedFormats()
    }

    func setInlineAttribute(_ key: String, value: JSONValue?) {
        updateInlineAttributes { attributes in
            if let value {
                attributes[key] = value
            } else {
                attributes.removeValue(forKey: key)
            }
        }
    }

    func clearTextFormatting() {
        let formattingKeys = [
            "bold", "italic", "underline", "strikethrough", "code",
            "font_color", "bg_color", "font_size", "font_family",
        ]
        updateInlineAttributes { attributes in
            for key in formattingKeys { attributes.removeValue(forKey: key) }
        }
    }

    func selectedValue(for key: String) -> JSONValue? {
        selectedInlineAttributes[key]
    }

    func selectionDidChange() {
        if let textView, textView.selectedRange.length == 0 {
            typingInlineAttributes = inlineAttributesAtCaret(
                in: textView,
                fallback: typingInlineAttributes
            )
            applyTypingAttributes(to: textView)
        }
        refreshSelectedText()
        refreshSelectedFormats()
    }

    func textDidChange(_ textView: UITextView) {
        guard self.textView === textView, textView.selectedRange.length == 0 else {
            refreshSelectedFormats()
            return
        }
        typingInlineAttributes = inlineAttributesAtCaret(
            in: textView,
            fallback: typingInlineAttributes
        )
        applyTypingAttributes(to: textView)
        refreshSelectedText()
        refreshSelectedFormats()
    }

    private func refreshSelectedText() {
        guard let textView else {
            selectedTextRange = nil
            selectedText = nil
            return
        }
        let range = textView.selectedRange
        guard range.length > 0,
              NSMaxRange(range) <= textView.textStorage.length else {
            selectedTextRange = nil
            selectedText = nil
            return
        }
        let text = (textView.text as NSString)
            .substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            selectedTextRange = nil
            selectedText = nil
            return
        }
        selectedTextRange = range
        selectedText = text
    }

    func visualTypingAttributes(in textView: UITextView) -> [NSAttributedString.Key: Any] {
        RichTextCodec.visualAttributes(
            for: typingInlineAttributes,
            baseFont: baseFont,
            paragraphStyle: RichTextCodec.paragraphStyle(from: textView.typingAttributes),
            defaultColor: defaultColor,
            semanticStrikethrough: semanticStrikethrough
        )
    }

    private func applyTypingAttributes(to textView: UITextView) {
        textView.typingAttributes = RichTextCodec.visualAttributes(
            for: typingInlineAttributes,
            baseFont: baseFont,
            paragraphStyle: RichTextCodec.paragraphStyle(from: textView.typingAttributes),
            defaultColor: defaultColor,
            semanticStrikethrough: semanticStrikethrough
        )
    }

    private func updateInlineAttributes(_ update: (inout TextAttributes) -> Void) {
        guard let textView else { return }
        let range = textView.selectedRange

        if range.length == 0 {
            update(&typingInlineAttributes)
            applyTypingAttributes(to: textView)
            refreshSelectedFormats()
            return
        }

        let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
        attributed.enumerateAttribute(
            RichTextCodec.inlineAttributesKey,
            in: range,
            options: []
        ) { value, effectiveRange, _ in
            var inline = RichTextCodec.decodeInlineAttributes(value)
            update(&inline)
            attributed.setAttributes(
                RichTextCodec.visualAttributes(
                    for: inline,
                    baseFont: baseFont,
                    paragraphStyle: RichTextCodec.paragraphStyle(
                        from: attributed.attributes(at: effectiveRange.location, effectiveRange: nil)
                    ),
                    defaultColor: defaultColor,
                    semanticStrikethrough: semanticStrikethrough
                ),
                range: effectiveRange
            )
        }

        textView.attributedText = attributed
        textView.selectedRange = range
        commit?(RichTextCodec.delta(from: attributed))
        refreshSelectedFormats()
    }

    private func inlineAttributesAtCaret(
        in textView: UITextView,
        fallback: TextAttributes
    ) -> TextAttributes {
        let attributed = textView.attributedText ?? NSAttributedString()
        guard attributed.length > 0 else { return fallback }
        let caret = min(textView.selectedRange.location, attributed.length)
        let location = caret > 0 ? caret - 1 : 0
        return RichTextCodec.inlineAttributes(
            from: attributed.attributes(at: location, effectiveRange: nil)
        )
    }

    private func selectionContains(
        _ format: InlineFormat,
        attributed: NSAttributedString,
        range: NSRange
    ) -> Bool {
        guard range.length > 0 else { return false }
        var allEnabled = true
        attributed.enumerateAttribute(
            RichTextCodec.inlineAttributesKey,
            in: range,
            options: []
        ) { value, _, stop in
            if !RichTextCodec.isEnabled(format, in: RichTextCodec.decodeInlineAttributes(value)) {
                allEnabled = false
                stop.pointee = true
            }
        }
        return allEnabled
    }

    private func refreshSelectedFormats() {
        guard let textView else {
            if !selectedFormats.isEmpty { selectedFormats = [] }
            if !selectedInlineAttributes.isEmpty { selectedInlineAttributes = [:] }
            return
        }

        if textView.selectedRange.length > 0 {
            let attributed = textView.attributedText ?? NSAttributedString()
            let inline = commonInlineAttributes(in: attributed, range: textView.selectedRange)
            if selectedInlineAttributes != inline { selectedInlineAttributes = inline }
            let formats = Set(InlineFormat.allCases.filter {
                selectionContains($0, attributed: attributed, range: textView.selectedRange)
            })
            if selectedFormats != formats { selectedFormats = formats }
            return
        }

        if selectedInlineAttributes != typingInlineAttributes {
            selectedInlineAttributes = typingInlineAttributes
        }
        let formats = Set(InlineFormat.allCases.filter {
            RichTextCodec.isEnabled($0, in: typingInlineAttributes)
        })
        if selectedFormats != formats { selectedFormats = formats }
    }

    private func commonInlineAttributes(
        in attributed: NSAttributedString,
        range: NSRange
    ) -> TextAttributes {
        var common: TextAttributes?
        attributed.enumerateAttribute(
            RichTextCodec.inlineAttributesKey,
            in: range,
            options: []
        ) { value, _, _ in
            let inline = RichTextCodec.decodeInlineAttributes(value)
            if let current = common {
                common = current.filter { inline[$0.key] == $0.value }
            } else {
                common = inline
            }
        }
        return common ?? [:]
    }
}

struct RichTextBlockEditor: UIViewRepresentable {
    let delta: TextDelta
    let path: BlockPath
    let textStyle: BlockTextStyle
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let session: RichTextEditingSession
    let isEditable: Bool
    let onDeltaChange: (TextDelta) -> Void
    let splitsOnReturn: Bool
    let focusRequestID: UUID?
    let focusRequestOffset: Int
    let onFocusRequestHandled: () -> Void
    let onReturn: (Int) -> Void
    let onDeleteBackwardAtEmpty: () -> Void
    let onCopy: (NSRange) -> Bool
    let onCut: (NSRange) -> Bool
    let onPaste: (NSRange) -> Bool
    let onOpenURL: (URL) -> Bool
    let onAskAboutSelection: (NSRange, String) -> Void
    let annotations: [NativeBlockEditorTextAnnotation]
    let onTapAnnotations: (NativeBlockEditorAnnotationHit) -> Void
    /// Names the VoiceOver action for one cluster of annotations and its passage.
    let annotationActionName: (([NativeBlockEditorTextAnnotation], String) -> String)?
    let onSelectionChange: (NSRange) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = DocumentRichTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardDismissMode = .interactive
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.attributedText = annotatedString(traits: textView.traitCollection)
        textView.appearanceDidChange = { [weak coordinator = context.coordinator] textView in
            coordinator?.refreshAppearance(in: textView)
        }
        textView.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (textView: DocumentRichTextView, _: UITraitCollection) in
            textView.appearanceDidChange?(textView)
        }
        configureClipboardCallbacks(textView)
        configureKeyboardCallbacks(textView, coordinator: context.coordinator)
        configureLinkTap(textView, coordinator: context.coordinator)
        configureAnnotationTap(textView, coordinator: context.coordinator)
        configureAnnotationAccessibility(textView, coordinator: context.coordinator)
        textView.typingAttributes = RichTextCodec.visualAttributes(
            for: [:],
            baseFont: textStyle.font,
            paragraphStyle: textStyle.paragraphStyle,
            defaultColor: textStyle.color,
            semanticStrikethrough: textStyle.strikesText
        )
        context.coordinator.renderedStyleSignature = textStyle.signature
        context.coordinator.renderedAnnotationSignature = annotationSignature
        context.coordinator.renderedAppearanceSignature = appearanceSignature(for: textView.traitCollection)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        // Read-only selection also needs first-responder ownership. Only end
        // editing when the mode changes, never on an ordinary reader refresh.
        if textView.isEditable != isEditable {
            if !isEditable, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            textView.isEditable = isEditable
        }
        textView.isSelectable = true
        configureClipboardCallbacks(textView)
        configureKeyboardCallbacks(textView, coordinator: context.coordinator)
        configureLinkTap(textView, coordinator: context.coordinator)
        configureAnnotationTap(textView, coordinator: context.coordinator)

        let current = RichTextCodec.delta(from: textView.attributedText)
        let contentChanged = current != delta.normalized()
            || context.coordinator.renderedStyleSignature != textStyle.signature
            || context.coordinator.renderedAppearanceSignature != appearanceSignature(for: textView.traitCollection)
        let annotationsChanged = context.coordinator.renderedAnnotationSignature != annotationSignature
        // Restyling under a live selection would drop its handles and menu, so
        // a highlight that changes then waits until the selection collapses.
        let defersAnnotations = !contentChanged && annotationsChanged
            && textView.isFirstResponder && textView.selectedRange.length > 0
        if contentChanged || annotationsChanged, !defersAnnotations, textView.markedTextRange == nil {
            context.coordinator.render(
                in: textView,
                fades: !contentChanged && !isEditable && textView.window != nil
                    && !UIAccessibility.isReduceMotionEnabled
            )
        }
        configureAnnotationAccessibility(textView, coordinator: context.coordinator)

        if isEditable, textView.isFirstResponder {
            session.updateConfiguration(
                for: textView,
                baseFont: textStyle.font,
                defaultColor: textStyle.color,
                semanticStrikethrough: textStyle.strikesText,
                commit: onDeltaChange
            )
        }

        if isEditable,
           let focusRequestID,
           context.coordinator.handledFocusRequestID != focusRequestID,
           context.coordinator.scheduledFocusRequestID != focusRequestID {
            context.coordinator.scheduleFocus(
                id: focusRequestID,
                textView: textView,
                offset: focusRequestOffset,
                onHandled: onFocusRequestHandled
            )
        }
    }

    private func configureClipboardCallbacks(_ textView: UITextView) {
        guard let textView = textView as? DocumentRichTextView else { return }
        textView.copyHandler = onCopy
        textView.cutHandler = isEditable ? onCut : nil
        textView.pasteHandler = isEditable ? onPaste : nil
    }

    private func configureKeyboardCallbacks(_ textView: UITextView, coordinator: Coordinator) {
        guard let textView = textView as? DocumentRichTextView else { return }
        textView.deleteBackwardAtEmptyHandler = isEditable
            ? { [weak coordinator] in coordinator?.parent.onDeleteBackwardAtEmpty() }
            : nil
    }

    private func configureLinkTap(_ textView: UITextView, coordinator: Coordinator) {
        guard let textView = textView as? DocumentRichTextView else { return }
        if textView.linkTapRecognizer == nil {
            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.openLink(_:))
            )
            recognizer.delegate = coordinator
            recognizer.cancelsTouchesInView = false
            textView.addGestureRecognizer(recognizer)
            textView.linkTapRecognizer = recognizer
        }
    }

    private func configureAnnotationTap(_ textView: UITextView, coordinator: Coordinator) {
        guard let textView = textView as? DocumentRichTextView else { return }
        if textView.annotationTapRecognizer == nil {
            // A double-tap on a highlighted word selects it; it never opens
            // the highlight, so the single tap waits for the double to fail.
            let doubleTap = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.ignoreAnnotationDoubleTap(_:))
            )
            doubleTap.numberOfTapsRequired = 2
            doubleTap.delegate = coordinator
            doubleTap.cancelsTouchesInView = false
            doubleTap.delaysTouchesEnded = false
            textView.addGestureRecognizer(doubleTap)
            textView.annotationDoubleTapRecognizer = doubleTap

            let recognizer = UITapGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.openAnnotation(_:))
            )
            recognizer.delegate = coordinator
            recognizer.cancelsTouchesInView = false
            recognizer.require(toFail: doubleTap)
            textView.addGestureRecognizer(recognizer)
            textView.annotationTapRecognizer = recognizer
        }
        // Editing places the caret; highlights are only drawn, never opened.
        textView.annotationTapRecognizer?.isEnabled = !isEditable
        textView.annotationDoubleTapRecognizer?.isEnabled = !isEditable
    }

    /// One VoiceOver action per cluster of highlights, since a highlight can
    /// only be tapped by sight.
    private func configureAnnotationAccessibility(_ textView: UITextView, coordinator: Coordinator) {
        guard !isEditable else {
            textView.accessibilityCustomActions = nil
            return
        }
        let text = textView.attributedText.string as NSString
        let clusters = NativeBlockEditorAnnotationComposer.clusters(annotations, textLength: text.length)
        textView.accessibilityCustomActions = clusters.isEmpty ? nil : clusters.map { cluster in
            let start = cluster.map(\.range.location).min() ?? 0
            let end = cluster.map { NSMaxRange($0.range) }.max() ?? start
            let passage = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = passage.count > 40 ? String(passage.prefix(40)) + "…" : passage
            let name = annotationActionName?(cluster, passage) ?? "Open “\(quoted)”"
            return UIAccessibilityCustomAction(name: name) { [weak coordinator, weak textView] _ in
                guard let coordinator, let textView else { return false }
                return coordinator.openCluster(cluster, in: textView)
            }
        }
    }

    private var annotationSignature: String {
        // Editing draws every highlight as the same faint line, so a style
        // change, such as a branch page finishing, must not redraw mid-typing.
        annotations
            .sorted { $0.id < $1.id }
            .map { annotation in
                let style = isEditable
                    ? (annotation.style.isBranch ? "branch" : "discussion")
                    : annotation.style.rawValue
                return "\(annotation.id):\(annotation.range.location):\(annotation.range.length):\(style)"
            }
            .joined(separator: "|") + (isEditable ? "|editing" : "")
    }

    private func appearanceSignature(for traits: UITraitCollection) -> String {
        "\(traits.userInterfaceStyle.rawValue)|\(traits.accessibilityContrast.rawValue)|\(textStyle.color.resolvedColor(with: traits))"
    }

    private func annotatedString(from currentDelta: TextDelta? = nil, traits: UITraitCollection) -> NSAttributedString {
        let output = NSMutableAttributedString(
            attributedString: RichTextCodec.attributedString(
                from: currentDelta ?? delta,
                style: textStyle.resolved(for: traits)
            )
        )
        let runs = NativeBlockEditorAnnotationComposer.runs(
            for: annotations,
            textLength: output.length,
            isEditable: isEditable
        )
        for run in runs {
            output.addAttributes(RichTextCodec.annotationAttributes(for: run, traits: traits), range: run.range)
        }
        return output
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(textStyle.minimumHeight, ceil(size.height)))
    }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.parent.session.deactivate(textView)
        textView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: RichTextBlockEditor
        var renderedStyleSignature = ""
        var renderedAnnotationSignature = ""
        var renderedAppearanceSignature = ""
        var handledFocusRequestID: UUID?
        var scheduledFocusRequestID: UUID?
        var pendingInsertion: (range: NSRange, attributes: [NSAttributedString.Key: Any])?
        private var isRendering = false

        init(parent: RichTextBlockEditor) {
            self.parent = parent
        }

        func refreshAppearance(in textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            // UIKit can attach a read-only text view before its window's final
            // appearance arrives. Reapply colors without changing semantic text
            // or using a SwiftUI snapshot that may lag an active local edit.
            let currentDelta = RichTextCodec.delta(from: textView.attributedText)
            let selection = textView.selectedRange
            let typingAttributes = textView.typingAttributes
            textView.attributedText = parent.annotatedString(
                from: currentDelta,
                traits: textView.traitCollection
            )
            textView.selectedRange = selection
            textView.typingAttributes = RichTextCodec.visualAttributes(
                for: RichTextCodec.inlineAttributes(from: typingAttributes),
                baseFont: parent.textStyle.font,
                paragraphStyle: parent.textStyle.paragraphStyle,
                defaultColor: parent.textStyle.color.resolvedColor(with: textView.traitCollection),
                semanticStrikethrough: parent.textStyle.strikesText
            )
            renderedAppearanceSignature = parent.appearanceSignature(for: textView.traitCollection)
        }

        /// Draws the block's text and highlights, keeping the selection.
        func render(in textView: UITextView, fades: Bool) {
            // Restoring the selection reports a selection change; that must
            // not start another render.
            guard !isRendering else { return }
            isRendering = true
            defer { isRendering = false }
            let selection = textView.selectedRange
            let apply = {
                textView.attributedText = self.parent.annotatedString(traits: textView.traitCollection)
                let location = min(selection.location, textView.attributedText.length)
                let length = min(selection.length, textView.attributedText.length - location)
                textView.selectedRange = NSRange(location: location, length: length)
            }
            if fades {
                // A highlight changing state, such as a branch page finishing,
                // dissolves in place instead of snapping.
                UIView.transition(with: textView, duration: 0.25, options: .transitionCrossDissolve, animations: apply)
            } else {
                apply()
            }
            renderedStyleSignature = parent.textStyle.signature
            renderedAnnotationSignature = parent.annotationSignature
            renderedAppearanceSignature = parent.appearanceSignature(for: textView.traitCollection)
        }

        func scheduleFocus(
            id: UUID,
            textView: UITextView,
            offset: Int,
            onHandled: @escaping () -> Void,
            remainingAttempts: Int = 5
        ) {
            scheduledFocusRequestID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.parent.focusRequestID == id else {
                    self.scheduledFocusRequestID = nil
                    return
                }
                guard textView.window != nil, textView.becomeFirstResponder() else {
                    if remainingAttempts > 1 {
                        self.scheduleFocus(
                            id: id,
                            textView: textView,
                            offset: offset,
                            onHandled: onHandled,
                            remainingAttempts: remainingAttempts - 1
                        )
                    } else {
                        self.scheduledFocusRequestID = nil
                    }
                    return
                }
                self.handledFocusRequestID = id
                self.scheduledFocusRequestID = nil
                textView.selectedRange = NSRange(
                    location: min(offset, textView.attributedText.length),
                    length: 0
                )
                onHandled()
            }
        }

        @objc func openLink(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView,
                  let characterIndex = characterIndex(
                    at: recognizer.location(in: textView),
                    in: textView
                  ),
                  let url = textView.textStorage.attribute(
                    .link,
                    at: characterIndex,
                    effectiveRange: nil
                  ) as? URL
            else { return }
            if !parent.onOpenURL(url) {
                UIApplication.shared.open(url)
            }
        }

        @objc func openAnnotation(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView,
                  let characterIndex = characterIndex(
                    at: recognizer.location(in: textView),
                    in: textView
                  ),
                  let hit = hit(
                    at: characterIndex,
                    in: textView,
                    isCommandClick: recognizer.modifierFlags.contains(.command)
                  )
            else { return }
            parent.onTapAnnotations(hit)
        }

        @objc func ignoreAnnotationDoubleTap(_ recognizer: UITapGestureRecognizer) {}

        /// Opens one cluster of highlights for VoiceOver with every annotation
        /// in it, since overlapping highlights need not share a character.
        func openCluster(_ cluster: [NativeBlockEditorTextAnnotation], in textView: UITextView) -> Bool {
            guard let primary = NativeBlockEditorAnnotationComposer.primary(of: cluster),
                  NSMaxRange(primary.range) <= textView.textStorage.length else { return false }
            parent.onTapAnnotations(NativeBlockEditorAnnotationHit(
                annotations: cluster,
                primary: primary,
                blockID: primary.blockID,
                path: parent.path,
                blockText: textView.textStorage.string,
                anchorRectInWindow: anchorRect(of: primary.range, at: primary.range.location, in: textView)
            ))
            return true
        }

        private func hit(
            at characterIndex: Int,
            in textView: UITextView,
            isCommandClick: Bool
        ) -> NativeBlockEditorAnnotationHit? {
            let covering = NativeBlockEditorAnnotationComposer.annotations(
                covering: characterIndex,
                in: parent.annotations,
                textLength: textView.textStorage.length
            )
            guard let primary = NativeBlockEditorAnnotationComposer.primary(of: covering) else { return nil }
            return NativeBlockEditorAnnotationHit(
                annotations: covering,
                primary: primary,
                blockID: primary.blockID,
                path: parent.path,
                blockText: textView.textStorage.string,
                anchorRectInWindow: anchorRect(of: primary.range, at: characterIndex, in: textView),
                isCommandClick: isCommandClick
            )
        }

        /// The part of the passage on the tapped line, so a popover points at
        /// the words that were tapped rather than the middle of a paragraph.
        private func anchorRect(of range: NSRange, at characterIndex: Int, in textView: UITextView) -> CGRect {
            let layoutManager = textView.layoutManager
            let container = textView.textContainer
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            var lineGlyphs = NSRange()
            let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
            let passageGlyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let onLine = NSIntersectionRange(passageGlyphs, lineGlyphs)
            let rect = onLine.length > 0
                ? layoutManager.boundingRect(forGlyphRange: onLine, in: container)
                : lineRect
            return textView.convert(
                rect.offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top),
                to: nil
            )
        }

        private func characterIndex(at point: CGPoint, in textView: UITextView) -> Int? {
            textView.nbeCharacterIndex(at: point)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let textView = gestureRecognizer.view as? DocumentRichTextView,
                  let characterIndex = characterIndex(
                    at: touch.location(in: textView),
                    in: textView
                  )
            else { return false }

            if gestureRecognizer === textView.linkTapRecognizer {
                return textView.textStorage.attribute(
                    .link,
                    at: characterIndex,
                    effectiveRange: nil
                ) != nil
            }
            if gestureRecognizer === textView.annotationDoubleTapRecognizer {
                // Any second tap counts, even one that drifts off the
                // highlight, so a double-tap never falls back to opening it.
                return !textView.isEditable
            }
            if gestureRecognizer === textView.annotationTapRecognizer {
                // A link inside a highlight is followed, not the highlight.
                guard textView.textStorage.attribute(
                    RichTextCodec.annotationIDKey,
                    at: characterIndex,
                    effectiveRange: nil
                ) != nil,
                textView.textStorage.attribute(.link, at: characterIndex, effectiveRange: nil) == nil
                else { return false }
                return allowsAnnotationTap(in: textView)
            }
            return true
        }

        /// Checked again when the tap is recognized: a long press that ends
        /// up selecting a highlighted word is a selection, not a tap.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let textView = gestureRecognizer.view as? DocumentRichTextView,
                  gestureRecognizer === textView.annotationTapRecognizer else { return true }
            return allowsAnnotationTap(in: textView)
        }

        /// A tap that clears a selection, or stops a scroll, is not a request
        /// to open the highlight under it.
        private func allowsAnnotationTap(in textView: DocumentRichTextView) -> Bool {
            !textView.isEditable
                && !DocumentRichTextView.hasLiveSelection(besides: textView)
                && !(textView.isFirstResponder && textView.selectedRange.length > 0)
                && !textView.isInMovingScrollView
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let textView = gestureRecognizer.view as? DocumentRichTextView else {
                return false
            }
            if (gestureRecognizer === textView.annotationTapRecognizer
                && otherGestureRecognizer === textView.annotationDoubleTapRecognizer)
                || (gestureRecognizer === textView.annotationDoubleTapRecognizer
                    && otherGestureRecognizer === textView.annotationTapRecognizer) {
                // The single tap must wait for the double tap, not run beside it.
                return false
            }
            return gestureRecognizer === textView.linkTapRecognizer
                || otherGestureRecognizer === textView.linkTapRecognizer
                || gestureRecognizer === textView.annotationTapRecognizer
                || otherGestureRecognizer === textView.annotationTapRecognizer
                || gestureRecognizer === textView.annotationDoubleTapRecognizer
                || otherGestureRecognizer === textView.annotationDoubleTapRecognizer
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.session.activate(
                textView: textView,
                path: parent.path,
                baseFont: parent.textStyle.font,
                defaultColor: parent.textStyle.color,
                semanticStrikethrough: parent.textStyle.strikesText,
                commit: parent.onDeltaChange
            )
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.session.deactivate(textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n", range.length == 0, parent.splitsOnReturn {
                pendingInsertion = nil
                parent.onReturn(range.location)
                return false
            }
            if text.isEmpty {
                pendingInsertion = nil
            } else {
                pendingInsertion = (
                    NSRange(location: range.location, length: text.utf16.count),
                    parent.session.visualTypingAttributes(in: textView)
                )
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            if let pendingInsertion,
               NSMaxRange(pendingInsertion.range) <= textView.textStorage.length {
                textView.textStorage.setAttributes(
                    pendingInsertion.attributes,
                    range: pendingInsertion.range
                )
            }
            pendingInsertion = nil
            parent.session.textDidChange(textView)
            parent.onDeltaChange(RichTextCodec.delta(from: textView.attributedText))
            if renderedAppearanceSignature != parent.appearanceSignature(for: textView.traitCollection) {
                refreshAppearance(in: textView)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? DocumentRichTextView)?.selectionDidChange()
            // Catch up on highlights held back during a reading selection.
            // While editing, a keystroke can land here before the text is
            // committed, so redrawing then would undo it.
            if !isRendering,
               !textView.isEditable,
               textView.selectedRange.length == 0,
               renderedAnnotationSignature != parent.annotationSignature,
               textView.markedTextRange == nil {
                render(in: textView, fades: false)
            }
            guard textView.isFirstResponder else { return }
            parent.session.selectionDidChange()
            parent.onSelectionChange(textView.selectedRange)
        }

        @available(iOS 17.0, *)
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content else {
                return defaultAction
            }
            return UIAction { [weak self] _ in
                guard let self else { return }
                if !self.parent.onOpenURL(url) {
                    UIApplication.shared.open(url)
                }
            }
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            selectionMenu(textView: textView, range: range, suggestedActions: suggestedActions)
        }

        @available(iOS 26.0, *)
        func textView(
            _ textView: UITextView,
            editMenuForTextInRanges ranges: [NSValue],
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let first = ranges.first else { return UIMenu(children: suggestedActions) }
            let combinedRange = ranges.dropFirst().reduce(first.rangeValue) {
                NSUnionRange($0, $1.rangeValue)
            }
            return selectionMenu(
                textView: textView,
                range: combinedRange,
                suggestedActions: suggestedActions
            )
        }

        private func selectionMenu(
            textView: UITextView,
            range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu {
            guard range.length > 0,
                  NSMaxRange(range) <= textView.textStorage.length else {
                return UIMenu(children: suggestedActions)
            }
            let selectedText = (textView.text as NSString)
                .substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedText.isEmpty else { return UIMenu(children: suggestedActions) }

            let action = UIAction(
                title: "Ask About This",
                image: UIImage(systemName: "sparkles")
            ) { [weak self] _ in
                self?.parent.onAskAboutSelection(range, selectedText)
            }
            return UIMenu(children: suggestedActions + [action])
        }
    }
}

private final class DocumentRichTextView: UITextView {
    var appearanceDidChange: ((UITextView) -> Void)?
    var copyHandler: ((NSRange) -> Bool)?
    var cutHandler: ((NSRange) -> Bool)?
    var pasteHandler: ((NSRange) -> Bool)?
    var deleteBackwardAtEmptyHandler: (() -> Void)?
    weak var linkTapRecognizer: UITapGestureRecognizer?
    weak var annotationTapRecognizer: UITapGestureRecognizer?
    weak var annotationDoubleTapRecognizer: UITapGestureRecognizer?

    /// The block that last held a selection. A page is many text views, so a
    /// tap in one block can be the tap that clears a selection in another.
    private static weak var selectionOwner: DocumentRichTextView?

    func selectionDidChange() {
        if selectedRange.length > 0 {
            Self.selectionOwner = self
        } else if Self.selectionOwner === self {
            Self.selectionOwner = nil
        }
    }

    static func hasLiveSelection(besides view: DocumentRichTextView) -> Bool {
        // Each window keeps its own selection; one in another window says
        // nothing about this tap.
        guard let owner = selectionOwner, owner !== view,
              let window = view.window, owner.window === window else { return false }
        return owner.isFirstResponder && owner.selectedRange.length > 0
    }

    /// Whether the scroll view around this block is being dragged or is still
    /// gliding: a tap then stops the scroll and nothing else.
    var isInMovingScrollView: Bool {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled,
               scrollView.isDragging || scrollView.isDecelerating {
                return true
            }
            view = current.superview
        }
        return false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { appearanceDidChange?(self) }
    }

    override func deleteBackward() {
        // UITextViewDelegate is not called when Backspace is pressed while the
        // view is already empty, so surface that keystroke explicitly.
        if textStorage.length == 0,
           selectedRange == NSRange(location: 0, length: 0),
           let deleteBackwardAtEmptyHandler {
            deleteBackwardAtEmptyHandler()
            return
        }
        super.deleteBackward()
    }

    override func copy(_ sender: Any?) {
        if copyHandler?(selectedRange) == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if cutHandler?(selectedRange) == true { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        if pasteHandler?(selectedRange) == true { return }
        super.paste(sender)
    }
}

struct BlockTextStyle {
    let font: UIFont
    let color: UIColor
    let lineSpacing: CGFloat
    let minimumHeight: CGFloat
    let strikesText: Bool

    init(
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        minimumHeight: CGFloat,
        strikesText: Bool = false
    ) {
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
        self.minimumHeight = minimumHeight
        self.strikesText = strikesText
    }

    var signature: String {
        "\(font.fontName)|\(font.pointSize)|\(color.description)|\(lineSpacing)|\(minimumHeight)|\(strikesText)"
    }

    func resolved(for traits: UITraitCollection) -> BlockTextStyle {
        BlockTextStyle(
            font: font,
            color: color.resolvedColor(with: traits),
            lineSpacing: lineSpacing,
            minimumHeight: minimumHeight,
            strikesText: strikesText
        )
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func style(for node: BlockNode) -> BlockTextStyle {
        switch node.type {
        case "heading":
            switch node.data["level"]?.intValue ?? 1 {
            case 1:
                BlockTextStyle(
                    font: .systemFont(ofSize: 24, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 32
                )
            case 2:
                BlockTextStyle(
                    font: .systemFont(ofSize: 22, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 30
                )
            case 3:
                BlockTextStyle(
                    font: .systemFont(ofSize: 20, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 28
                )
            case 4:
                BlockTextStyle(
                    font: .systemFont(ofSize: 18, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 26
                )
            case 5:
                BlockTextStyle(
                    font: .systemFont(ofSize: 16, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 24
                )
            default:
                BlockTextStyle(
                    font: .systemFont(ofSize: 14, weight: .semibold),
                    color: .label,
                    lineSpacing: 3,
                    minimumHeight: 22
                )
            }
        case "quote":
            BlockTextStyle(
                font: .systemFont(ofSize: 16),
                color: .label,
                lineSpacing: 4,
                minimumHeight: 24
            )
        case "todo_list" where node.data["checked"]?.boolValue == true:
            BlockTextStyle(
                font: .systemFont(ofSize: 16),
                color: .systemGray3,
                lineSpacing: 4,
                minimumHeight: 24,
                strikesText: true
            )
        case "code":
            BlockTextStyle(
                font: .monospacedSystemFont(ofSize: 15, weight: .regular),
                color: .label,
                lineSpacing: 4,
                minimumHeight: 28
            )
        case "nbe/formula":
            BlockTextStyle(
                font: .systemFont(ofSize: 19, weight: .medium),
                color: .label,
                lineSpacing: 6,
                minimumHeight: 32
            )
        default:
            BlockTextStyle(
                font: .systemFont(ofSize: 16),
                color: .label,
                lineSpacing: 4,
                minimumHeight: 24
            )
        }
    }
}

enum RichTextCodec {
    static let inlineAttributesKey = NSAttributedString.Key("NativeBlockEditor.inlineAttributes")
    static let annotationIDKey = NSAttributedString.Key("NativeBlockEditor.annotationID")

    static func attributedString(from delta: TextDelta, style: BlockTextStyle) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for operation in delta.operations {
            guard case let .insert(text, inline) = operation else { continue }
            output.append(
                NSAttributedString(
                    string: text,
                    attributes: visualAttributes(
                        for: inline ?? [:],
                        baseFont: style.font,
                        paragraphStyle: style.paragraphStyle,
                        defaultColor: style.color
                    )
                )
            )
        }
        if style.strikesText, output.length > 0 {
            output.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: output.length)
            )
        }
        return output
    }

    /// Colors for one annotation run. The ID marks the run as annotated; taps
    /// read the covering annotations from their ranges, not from this key.
    /// The reading flow draws its runs the same way.
    static func annotationAttributes(
        for run: NativeBlockEditorAnnotationComposer.Run,
        traits: UITraitCollection
    ) -> [NSAttributedString.Key: Any] {
        let token = run.token
        let isDark = traits.userInterfaceStyle == .dark
        let contrast: CGFloat = traits.accessibilityContrast == .high ? 1.5 : 1
        let hue: UIColor = token.underlineHue == .branch ? .systemPurple : .systemBlue
        var attributes: [NSAttributedString.Key: Any] = [annotationIDKey: run.primaryID]

        let fillAlpha: CGFloat? = switch token.fill {
        case .none: nil
        case .branchNew: isDark ? 0.22 : 0.14
        case .branch: isDark ? 0.10 : 0.06
        case .discussion: 0.20
        }
        if let fillAlpha {
            let color: UIColor = token.fill == .discussion ? .systemBlue : .systemPurple
            let stacked: CGFloat = token.isStacked ? 0.04 : 0
            attributes[.backgroundColor] = color.withAlphaComponent(min(1, (fillAlpha + stacked) * contrast))
        }

        let underlineAlpha: CGFloat
        if token.isInert {
            underlineAlpha = 0.35
        } else if contrast > 1 {
            underlineAlpha = 1
        } else if token.underlineHue == .discussion {
            underlineAlpha = 0.65
        } else if token.underlinePattern == .dashed {
            underlineAlpha = 0.6
        } else {
            underlineAlpha = token.isUnderlineStrong ? 0.8 : 0.45
        }
        var style: NSUnderlineStyle = token.isStacked && !token.isInert ? .double : .single
        if token.underlinePattern == .dashed, !token.isInert { style.insert(.patternDash) }
        attributes[.underlineStyle] = style.rawValue
        attributes[.underlineColor] = hue.withAlphaComponent(underlineAlpha)
        return attributes
    }

    static func delta(from attributed: NSAttributedString) -> TextDelta {
        guard attributed.length > 0 else { return TextDelta() }
        var operations: [TextOperation] = []
        attributed.enumerateAttribute(
            inlineAttributesKey,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            let inline = decodeInlineAttributes(value)
            operations.append(.insert(text, attributes: inline.isEmpty ? nil : inline))
        }
        return TextDelta(operations).normalized()
    }

    static func visualAttributes(
        for inline: TextAttributes,
        baseFont: UIFont,
        paragraphStyle: NSParagraphStyle,
        defaultColor: UIColor = .label,
        semanticStrikethrough: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(base: baseFont, inline: inline),
            .foregroundColor: color(from: inline["font_color"]?.stringValue) ?? defaultColor,
            .paragraphStyle: paragraphStyle,
            inlineAttributesKey: encodeInlineAttributes(inline),
        ]

        if inline["underline"]?.boolValue == true {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline["strikethrough"]?.boolValue == true || semanticStrikethrough {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inline["code"]?.boolValue == true {
            result[.backgroundColor] = UIColor.secondarySystemFill
        } else if let background = color(from: inline["bg_color"]?.stringValue) {
            result[.backgroundColor] = background
        }
        if let href = inline["href"]?.stringValue, let url = URL(string: href) {
            result[.link] = url
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return result
    }

    static func paragraphStyle(from attributes: [NSAttributedString.Key: Any]) -> NSParagraphStyle {
        attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
    }

    static func inlineAttributes(from attributes: [NSAttributedString.Key: Any]) -> TextAttributes {
        decodeInlineAttributes(attributes[inlineAttributesKey])
    }

    static func decodeInlineAttributes(_ value: Any?) -> TextAttributes {
        guard
            let string = value as? String,
            let data = string.data(using: .utf8),
            let attributes = try? JSONDecoder().decode(TextAttributes.self, from: data)
        else {
            return [:]
        }
        return attributes
    }

    static func isEnabled(_ format: InlineFormat, in attributes: TextAttributes) -> Bool {
        attributes[key(for: format)]?.boolValue == true
    }

    static func set(
        _ format: InlineFormat,
        enabled: Bool,
        in attributes: inout TextAttributes
    ) {
        if enabled {
            attributes[key(for: format)] = true
        } else {
            attributes.removeValue(forKey: key(for: format))
        }
    }

    private static func key(for format: InlineFormat) -> String {
        switch format {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .code: "code"
        }
    }

    private static func encodeInlineAttributes(_ attributes: TextAttributes) -> String {
        guard let data = try? JSONEncoder().encode(attributes) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func resolvedFont(base: UIFont, inline: TextAttributes) -> UIFont {
        let pointSize = inline["font_size"]?.doubleValue ?? Double(base.pointSize)
        let requestedBase = inline["font_family"]?.stringValue
            .flatMap { UIFont(name: $0, size: pointSize) }
            ?? UIFont(descriptor: base.fontDescriptor, size: pointSize)

        if inline["code"]?.boolValue == true {
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        }

        var traits = requestedBase.fontDescriptor.symbolicTraits
        if inline["bold"]?.boolValue == true { traits.insert(.traitBold) }
        if inline["italic"]?.boolValue == true { traits.insert(.traitItalic) }
        let descriptor = requestedBase.fontDescriptor.withSymbolicTraits(traits)
            ?? requestedBase.fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    private static func color(from value: String?) -> UIColor? {
        guard var value else { return nil }
        value = value.replacingOccurrences(of: "#", with: "")
        if value.lowercased().hasPrefix("0x") { value.removeFirst(2) }
        guard (value.count == 6 || value.count == 8),
              let number = UInt64(value, radix: 16)
        else { return nil }
        let alpha = value.count == 8
            ? CGFloat((number >> 24) & 0xFF) / 255
            : 1
        return UIColor(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: alpha
        )
    }
}

#endif
