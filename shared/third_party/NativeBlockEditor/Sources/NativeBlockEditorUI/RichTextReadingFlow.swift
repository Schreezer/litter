#if os(iOS)
import NativeBlockEditorEngine
import SwiftUI
import UIKit

/// A block that reading mode lays out inside the page's shared text view.
struct ReadingFlowBlock: Equatable {
    let node: BlockNode
    let path: BlockPath
    let depth: Int
    let number: Int?

    private static let flowingTypes: Set<String> = [
        "paragraph", "heading", "bulleted_list", "numbered_list", "todo_list", "quote",
    ]

    /// Prose flows as text. Every other block (code, images, tables,
    /// embeds) keeps its own view, laid over a placeholder in the text.
    static func flows(_ node: BlockNode) -> Bool {
        node.delta != nil && flowingTypes.contains(node.type)
    }

    var isEmbedded: Bool { !Self.flows(node) }

    var text: String { node.delta?.plainText ?? "" }

    /// Whether the block's own view handles touches, such as scrolling code
    /// or a visualization's buttons. Text selection starts elsewhere.
    var handlesOwnTouches: Bool {
        !["image", "divider"].contains(node.type)
    }

    /// What a selection covering this whole block says about it.
    static func readingDescription(of node: BlockNode) -> String {
        func nonEmpty(_ key: String) -> String? {
            node.data[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch node.type {
        case "divider":
            return ""
        case "image":
            return (nonEmpty("alt") ?? nonEmpty("caption")).map { "[Image: \($0)]" } ?? "[Image]"
        case "table":
            var rows: [Int: [(Int, String)]] = [:]
            for cell in node.children {
                guard let row = cell.data["rowPosition"]?.intValue,
                      let column = cell.data["colPosition"]?.intValue else { continue }
                let text = cell.children.compactMap { $0.delta?.plainText }.joined(separator: " ")
                rows[row, default: []].append((column, text))
            }
            return rows.keys.sorted().map { row in
                rows[row]!.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " | ")
            }.joined(separator: "\n")
        case "nbe/html":
            return nonEmpty("title").map { "[Interactive visualization: \($0)]" }
                ?? "[Interactive visualization]"
        case "nbe/media":
            let kind = (nonEmpty("kind") ?? "media").capitalized
            return (nonEmpty("title") ?? nonEmpty("url")).map { "[\(kind): \($0)]" } ?? "[\(kind)]"
        case "nbe/child_page", "nbe/page_reference":
            return nonEmpty("title").map { "[Page: \($0)]" } ?? "[Page]"
        case "link_preview":
            return (nonEmpty("title") ?? nonEmpty("url")).map { "[Link: \($0)]" } ?? "[Link]"
        default:
            let text = plainTextFragments(node).joined(separator: "\n")
            return text.isEmpty ? "[\(node.type)]" : text
        }
    }

    private static func plainTextFragments(_ node: BlockNode) -> [String] {
        var fragments: [String] = []
        if let text = node.delta?.plainText, !text.isEmpty { fragments.append(text) }
        fragments.append(contentsOf: node.children.flatMap(plainTextFragments))
        return fragments
    }
}

/// Lays a page's blocks out as paragraphs of one attributed string.
///
/// Each block in its own `UITextView` confines a selection to that block; one
/// text view lets a reader drag from the middle of one paragraph, past an
/// image or a code block, into the next. List markers and quote bars are
/// drawn beside the text rather than inserted into it, so they never appear
/// in a selection or a copy. Every other block is a single attachment
/// character whose space its real view covers.
struct ReadingFlowLayout {
    struct Decoration: Equatable {
        enum Kind: Equatable {
            case bullet
            case number(Int)
            case todo(checked: Bool)
            case quoteBar
        }

        let kind: Kind
        /// The block's text plus its paragraph break, so an empty block
        /// still owns a line to decorate.
        let paragraphRange: NSRange
        let leadingInset: CGFloat
    }

    static let depthIndent: CGFloat = 22
    static let markerWidth: CGFloat = 24
    static let markerSpacing: CGFloat = 5
    static let quoteInset: CGFloat = 18
    static let quoteBarWidth: CGFloat = 4

    let blocks: [ReadingFlowBlock]
    let attributedText: NSAttributedString
    /// Each block's text in `attributedText`, excluding paragraph breaks.
    let blockRanges: [NSRange]
    let decorations: [Decoration]
    /// The attachment character standing in for each embedded block.
    let embedIndices: [UUID: Int]

    init(
        blocks: [ReadingFlowBlock],
        annotations: [NativeBlockEditorTextAnnotation],
        traits: UITraitCollection,
        attachment: (ReadingFlowBlock) -> NSTextAttachment = { ReadingFlowAttachment(blockID: $0.node.id) }
    ) {
        let output = NSMutableAttributedString()
        var blockRanges: [NSRange] = []
        var decorations: [Decoration] = []
        var embedIndices: [UUID: Int] = [:]

        for (index, block) in blocks.enumerated() {
            if block.isEmbedded {
                let paragraph = NSMutableParagraphStyle()
                paragraph.firstLineHeadIndent = Self.depthIndent * CGFloat(block.depth)
                paragraph.headIndent = paragraph.firstLineHeadIndent
                if index > 0 {
                    paragraph.paragraphSpacingBefore = Self.rowPadding(blocks[index - 1])
                        + Self.rowPadding(block)
                }
                // A tiny font keeps the line from adding descent below the view.
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.embedFont,
                    .paragraphStyle: paragraph,
                ]
                let start = output.length
                let content = NSMutableAttributedString(attachment: attachment(block))
                content.addAttributes(attributes, range: NSRange(location: 0, length: content.length))
                output.append(content)
                blockRanges.append(NSRange(location: start, length: content.length))
                embedIndices[block.node.id] = start
                if index < blocks.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: attributes))
                }
                continue
            }

            let style = BlockTextStyle.style(for: block.node).resolved(for: traits)
            let content = NSMutableAttributedString(
                attributedString: RichTextCodec.attributedString(
                    from: block.node.delta ?? TextDelta(),
                    style: style
                )
            )
            // A soft break inside a block must not start a new paragraph,
            // which would repeat the block's marker and spacing. The line
            // separator keeps every UTF-16 offset unchanged.
            content.mutableString.replaceOccurrences(
                of: "\n",
                with: "\u{2028}",
                options: [],
                range: NSRange(location: 0, length: content.length)
            )

            let leading = Self.depthIndent * CGFloat(block.depth)
            let kind: Decoration.Kind?
            let textInset: CGFloat
            switch block.node.type {
            case "bulleted_list":
                kind = .bullet
                textInset = Self.markerWidth + Self.markerSpacing
            case "numbered_list":
                kind = .number(block.number ?? 1)
                textInset = Self.markerWidth + Self.markerSpacing
            case "todo_list":
                kind = .todo(checked: block.node.data["checked"]?.boolValue ?? false)
                textInset = Self.markerWidth + Self.markerSpacing
            case "quote":
                kind = .quoteBar
                textInset = Self.quoteInset
            default:
                kind = nil
                textInset = 0
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.setParagraphStyle(style.paragraphStyle)
            paragraph.firstLineHeadIndent = leading + textInset
            paragraph.headIndent = leading + textInset
            if index > 0 {
                // Matches the vertical padding between separate block rows.
                paragraph.paragraphSpacingBefore = Self.rowPadding(blocks[index - 1])
                    + Self.rowPadding(block)
            }
            content.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: content.length)
            )

            let start = output.length
            output.append(content)
            blockRanges.append(NSRange(location: start, length: content.length))

            for annotation in annotations where annotation.applies(to: block.node, at: block.path) {
                guard annotation.range.location >= 0,
                      annotation.range.length > 0,
                      NSMaxRange(annotation.range) <= content.length else { continue }
                output.addAttributes(
                    RichTextCodec.annotationAttributes(for: annotation),
                    range: NSRange(
                        location: start + annotation.range.location,
                        length: annotation.range.length
                    )
                )
            }

            var paragraphLength = content.length
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: [
                    .font: style.font,
                    .foregroundColor: style.color,
                    .paragraphStyle: paragraph,
                ]))
                paragraphLength += 1
            }
            if let kind {
                decorations.append(Decoration(
                    kind: kind,
                    paragraphRange: NSRange(location: start, length: paragraphLength),
                    leadingInset: leading
                ))
            }
        }

        self.blocks = blocks
        attributedText = output
        self.blockRanges = blockRanges
        self.decorations = decorations
        self.embedIndices = embedIndices
    }

    private static let embedFont = UIFont.systemFont(ofSize: 1)

    private static func rowPadding(_ block: ReadingFlowBlock) -> CGFloat {
        block.depth == 0 ? 3 : 1
    }

    /// The blocks a flow-wide `range` covers, each with its block-local range.
    /// Whitespace-only parts at either end are dropped. Returns nil for an
    /// empty selection.
    func selection(for range: NSRange) -> NativeBlockEditorSelection? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var segments: [NativeBlockEditorSelection.Segment] = []
        for (block, blockRange) in zip(blocks, blockRanges) {
            let overlap = NSIntersectionRange(range, blockRange)
            guard overlap.length > 0 else { continue }
            if block.isEmbedded {
                if let segment = Self.wholeBlockSegment(block) { segments.append(segment) }
                continue
            }
            let local = NSRange(location: overlap.location - blockRange.location, length: overlap.length)
            let text = block.text as NSString
            guard NSMaxRange(local) <= text.length else { continue }
            segments.append(NativeBlockEditorSelection.Segment(
                blockID: block.node.stableBlockID,
                path: block.path,
                range: local,
                text: text.substring(with: local)
            ))
        }
        let isBlank: (NativeBlockEditorSelection.Segment) -> Bool = {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        while let first = segments.first, isBlank(first) { segments.removeFirst() }
        while let last = segments.last, isBlank(last) { segments.removeLast() }
        return NativeBlockEditorSelection(segments: segments)
    }

    /// A selection covers an embedded block whole. Code and formulas keep
    /// their text; other blocks are described, and images carry their source.
    private static func wholeBlockSegment(_ block: ReadingFlowBlock) -> NativeBlockEditorSelection.Segment? {
        if let delta = block.node.delta {
            let text = delta.plainText
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return NativeBlockEditorSelection.Segment(
                blockID: block.node.stableBlockID,
                path: block.path,
                range: NSRange(location: 0, length: (text as NSString).length),
                text: text
            )
        }
        let description = ReadingFlowBlock.readingDescription(of: block.node)
        guard !description.isEmpty else { return nil }
        return NativeBlockEditorSelection.Segment(
            blockID: block.node.stableBlockID,
            path: block.path,
            range: NSRange(location: 0, length: 0),
            text: description,
            isWholeBlock: true,
            imageSource: block.node.type == "image" ? block.node.data["url"]?.stringValue : nil
        )
    }
}

/// Draws list markers and quote bars beside the paragraphs they belong to.
final class ReadingFlowLayoutManager: NSLayoutManager {
    var decorations: [ReadingFlowLayout.Decoration] = []
    var accentColor: UIColor = .tintColor

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard !decorations.isEmpty, textStorage != nil else { return }
        let drawnCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for decoration in decorations {
            guard decoration.paragraphRange.length > 0,
                  NSIntersectionRange(decoration.paragraphRange, drawnCharacters).length > 0 else { continue }
            let glyphs = glyphRange(forCharacterRange: decoration.paragraphRange, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            draw(decoration, glyphs: glyphs, origin: origin)
        }
    }

    private func draw(_ decoration: ReadingFlowLayout.Decoration, glyphs: NSRange, origin: CGPoint) {
        let x = origin.x + decoration.leadingInset
        if decoration.kind == .quoteBar {
            var bounds = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in
                bounds = bounds.union(usedRect)
            }
            guard !bounds.isNull else { return }
            accentColor.setFill()
            UIRectFill(CGRect(
                x: x,
                y: origin.y + bounds.minY,
                width: ReadingFlowLayout.quoteBarWidth,
                height: bounds.height
            ))
            return
        }

        let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let baseline = origin.y + line.minY + location(forGlyphAt: glyphs.location).y
        let column = CGRect(x: x, y: 0, width: ReadingFlowLayout.markerWidth, height: 0)

        switch decoration.kind {
        case .bullet:
            drawMarker("•", font: .systemFont(ofSize: 18, weight: .semibold), column: column, baseline: baseline)
        case let .number(number):
            let body = UIFont.preferredFont(forTextStyle: .body)
            drawMarker(
                "\(number).",
                font: .monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular),
                column: column,
                baseline: baseline
            )
        case let .todo(checked):
            let font = textStorage?.attribute(
                .font,
                at: characterIndexForGlyph(at: glyphs.location),
                effectiveRange: nil
            ) as? UIFont ?? .systemFont(ofSize: 16)
            let side: CGFloat = 22
            let box = CGRect(
                x: column.midX - side / 2,
                y: baseline - font.capHeight / 2 - side / 2,
                width: side,
                height: side
            ).insetBy(dx: 0.75, dy: 0.75)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 6)
            path.lineWidth = 1.5
            if checked {
                accentColor.setFill()
                path.fill()
                accentColor.setStroke()
                path.stroke()
                let checkmark = UIImage(
                    systemName: "checkmark",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                )?.withTintColor(.white, renderingMode: .alwaysOriginal)
                if let checkmark {
                    checkmark.draw(at: CGPoint(
                        x: box.midX - checkmark.size.width / 2,
                        y: box.midY - checkmark.size.height / 2
                    ))
                }
            } else {
                UIColor.systemGray3.setStroke()
                path.stroke()
            }
        case .quoteBar:
            break
        }
    }

    private func drawMarker(_ marker: String, font: UIFont, column: CGRect, baseline: CGFloat) {
        let text = NSAttributedString(string: marker, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
        ])
        let width = text.size().width
        text.draw(at: CGPoint(x: column.midX - width / 2, y: baseline - font.ascender))
    }
}

/// Reserves an embedded block's space in the text. The block's real view is
/// laid over it, so the attachment itself draws nothing.
final class ReadingFlowAttachment: NSTextAttachment {
    let blockID: UUID
    /// The block view's height at a given width.
    var height: (CGFloat) -> CGFloat = { _ in 1 }

    init(blockID: UUID) {
        self.blockID = blockID
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let width = max(1, lineFrag.width - position.x)
        // Before the text view has a width, measuring would wrap the view
        // into a single tall column.
        guard width >= 40 else { return CGRect(x: 0, y: 0, width: width, height: 1) }
        return CGRect(x: 0, y: 0, width: width, height: max(1, height(width)))
    }

    override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> UIImage? {
        Self.blank
    }

    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
}

/// An embedded block's view, with a tint shown while a selection covers it.
final class ReadingFlowEmbedView: UIView {
    private let highlight = UIView()

    init(content: UIView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isUserInteractionEnabled = false
        highlight.alpha = 0
        highlight.layer.cornerRadius = 8
        highlight.layer.cornerCurve = .continuous
        addSubview(highlight)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool, tint: UIColor) {
        highlight.backgroundColor = tint.withAlphaComponent(0.18)
        highlight.alpha = selected ? 1 : 0
    }
}

/// One embedded block: its hosted view and the attachment it covers.
final class ReadingFlowEmbed {
    let attachment: ReadingFlowAttachment
    let controller: UIHostingController<AnyView>
    let view: ReadingFlowEmbedView
    var handlesOwnTouches = true
    var measuredWidth: CGFloat = 0
    var measuredHeight: CGFloat = 0

    init(blockID: UUID) {
        attachment = ReadingFlowAttachment(blockID: blockID)
        controller = UIHostingController(rootView: AnyView(EmptyView()))
        controller.view.backgroundColor = .clear
        controller.safeAreaRegions = []
        view = ReadingFlowEmbedView(content: controller.view)
    }

    /// The view's height at `width`, measured once per width.
    func height(at width: CGFloat) -> CGFloat {
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            measuredHeight = ceil(controller.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height)
        }
        return measuredHeight
    }
}

/// Hosts the page's shared text view.
final class ReadingFlowContainerView: UIView {
    let textView: ReadingFlowTextView
    var onMoveToWindow: (() -> Void)?

    init(textView: ReadingFlowTextView) {
        self.textView = textView
        super.init(frame: .zero)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?()
    }
}

final class ReadingFlowBlockElement: UIAccessibilityElement {
    var activate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        activate?() ?? false
    }
}

final class ReadingFlowTextView: UITextView {
    /// An accessibility item per block, in reading order.
    enum AccessibleBlock {
        case text(identifier: String, label: String, value: String, range: NSRange, activate: () -> Bool)
        case embed(UIView)
    }

    var appearanceDidChange: ((ReadingFlowTextView) -> Void)?
    var copyHandler: ((NSRange) -> Bool)?
    var didLayout: (() -> Void)?
    /// Whether a touch at a point belongs to an embedded view, not to text selection.
    var embedOwnsTouch: ((CGPoint) -> Bool)?
    weak var linkTapRecognizer: UITapGestureRecognizer?
    weak var annotationTapRecognizer: UITapGestureRecognizer?
    var accessibleBlocks: [AccessibleBlock] = [] {
        didSet { blockElements = nil }
    }
    private var blockElements: [Any]?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { appearanceDidChange?(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }

    override func copy(_ sender: Any?) {
        if copyHandler?(selectedRange) == true { return }
        super.copy(sender)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Scrolling code or tapping a visualization must not start a text
        // selection. Selection handles over an embedded view still drag.
        if gestureRecognizer.view === self,
           embedOwnsTouch?(gestureRecognizer.location(in: self)) == true {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        // Beside an embedded view the line is as tall as the view; keep the
        // caret, and the selection handle drawn from it, text-sized.
        let maximum: CGFloat = 26
        guard rect.height > maximum * 1.5 else { return rect }
        let offset = self.offset(from: beginningOfDocument, to: position)
        let beforeAttachment = offset < textStorage.length
            && textStorage.attribute(.attachment, at: offset, effectiveRange: nil) != nil
        return CGRect(
            x: rect.minX,
            y: beforeAttachment ? rect.minY : rect.maxY - maximum,
            width: rect.width,
            height: maximum
        )
    }

    /// The area `range` occupies, in this view's coordinates.
    func boundingRect(ofCharacters range: NSRange) -> CGRect {
        guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    // Blocks are read one at a time, as separate block views were, so
    // VoiceOver reads paragraph by paragraph and tests can find a block by
    // identifier. Embedded views keep their own elements.
    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get {
            let elements = blockElements ?? accessibleBlocks.map { block -> Any in
                switch block {
                case let .text(identifier, label, value, _, activate):
                    let element = ReadingFlowBlockElement(accessibilityContainer: self)
                    element.accessibilityIdentifier = identifier
                    element.accessibilityLabel = label
                    element.accessibilityValue = value
                    element.accessibilityTraits = .staticText
                    element.activate = activate
                    return element
                case let .embed(view):
                    return view
                }
            }
            blockElements = elements
            for (element, block) in zip(elements, accessibleBlocks) {
                if case let .text(_, _, _, range, _) = block,
                   let element = element as? UIAccessibilityElement {
                    element.accessibilityFrameInContainerSpace = boundingRect(ofCharacters: range)
                }
            }
            return elements
        }
        set {}
    }
}

/// A read-only page whose blocks share one selection.
struct RichTextReadingFlow: UIViewRepresentable {
    let blocks: [ReadingFlowBlock]
    /// The view for each embedded block, such as an image or code.
    let embedContent: (ReadingFlowBlock) -> AnyView
    let annotations: [NativeBlockEditorTextAnnotation]
    let accentColor: UIColor
    let onOpenURL: (URL) -> Bool
    let onOpenAnnotation: (NativeBlockEditorTextAnnotation) -> Void
    /// Reports nil once nothing in this flow is selected.
    let onSelectionChange: (NativeBlockEditorSelection?) -> Void
    let onAskAboutSelection: ((NativeBlockEditorSelection) -> Void)?
    let onCopy: (NativeBlockEditorSelection) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ReadingFlowContainerView {
        let storage = NSTextStorage()
        let layoutManager = ReadingFlowLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = ReadingFlowTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.appearanceDidChange = { [weak coordinator = context.coordinator] textView in
            coordinator?.renderIfNeeded(in: textView)
        }
        textView.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (textView: ReadingFlowTextView, _: UITraitCollection) in
            textView.appearanceDidChange?(textView)
        }
        textView.copyHandler = { [weak coordinator = context.coordinator] range in
            coordinator?.copy(range) ?? false
        }
        textView.didLayout = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.layoutEmbeds(in: textView)
        }
        textView.embedOwnsTouch = { [weak coordinator = context.coordinator, weak textView] point in
            guard let textView else { return false }
            return coordinator?.embedOwnsTouch(at: point, in: textView) ?? false
        }

        let linkTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.openLink(_:)))
        linkTap.delegate = context.coordinator
        linkTap.cancelsTouchesInView = false
        textView.addGestureRecognizer(linkTap)
        textView.linkTapRecognizer = linkTap

        let annotationTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.openAnnotation(_:)))
        annotationTap.delegate = context.coordinator
        annotationTap.cancelsTouchesInView = false
        textView.addGestureRecognizer(annotationTap)
        textView.annotationTapRecognizer = annotationTap

        let view = ReadingFlowContainerView(textView: textView)
        view.onMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.adoptEmbedControllers()
        }
        context.coordinator.container = view
        context.coordinator.updateEmbeds(in: textView)
        context.coordinator.renderIfNeeded(in: textView)
        return view
    }

    func updateUIView(_ view: ReadingFlowContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateEmbeds(in: view.textView)
        context.coordinator.renderIfNeeded(in: view.textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ReadingFlowContainerView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let size = uiView.textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    static func dismantleUIView(_ view: ReadingFlowContainerView, coordinator: Coordinator) {
        view.textView.delegate = nil
        coordinator.removeAllEmbeds()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: RichTextReadingFlow
        weak var container: ReadingFlowContainerView?
        private var layout: ReadingFlowLayout?
        private var renderedKey: RenderKey?
        private var embeds: [UUID: ReadingFlowEmbed] = [:]

        private struct RenderKey: Equatable {
            let blocks: [ReadingFlowBlock]
            let annotations: [NativeBlockEditorTextAnnotation]
            let userInterfaceStyle: UIUserInterfaceStyle
            let contrast: UIAccessibilityContrast
        }

        init(parent: RichTextReadingFlow) {
            self.parent = parent
        }

        /// Rebuilds the text only when its content or appearance changed.
        /// Replacing it mid-gesture would cancel a reader dragging a
        /// selection handle, and every selection change refreshes the host.
        func renderIfNeeded(in textView: ReadingFlowTextView) {
            if let layoutManager = textView.layoutManager as? ReadingFlowLayoutManager,
               !layoutManager.accentColor.isEqual(parent.accentColor) {
                // Hosts pass a fresh dynamic color on every update, so compare
                // what it resolves to before redrawing.
                let traits = textView.traitCollection
                if layoutManager.accentColor.resolvedColor(with: traits)
                    != parent.accentColor.resolvedColor(with: traits) {
                    textView.setNeedsDisplay()
                }
                layoutManager.accentColor = parent.accentColor
            }
            let key = RenderKey(
                blocks: parent.blocks,
                annotations: parent.annotations,
                userInterfaceStyle: textView.traitCollection.userInterfaceStyle,
                contrast: textView.traitCollection.accessibilityContrast
            )
            guard key != renderedKey else { return }
            renderedKey = key

            let embeds = embeds
            let layout = ReadingFlowLayout(
                blocks: parent.blocks,
                annotations: parent.annotations,
                traits: textView.traitCollection,
                attachment: { embeds[$0.node.id]?.attachment ?? ReadingFlowAttachment(blockID: $0.node.id) }
            )
            self.layout = layout
            if let layoutManager = textView.layoutManager as? ReadingFlowLayoutManager {
                layoutManager.decorations = layout.decorations
            }
            let selection = textView.selectedRange
            textView.attributedText = layout.attributedText
            let location = min(selection.location, layout.attributedText.length)
            textView.selectedRange = NSRange(
                location: location,
                length: min(selection.length, layout.attributedText.length - location)
            )
            textView.setNeedsDisplay()
            textView.setNeedsLayout()
            updateEmbedHighlights(in: textView)

            textView.accessibleBlocks = layout.blocks.enumerated().compactMap { index, block in
                if block.isEmbedded {
                    return embeds[block.node.id].map { .embed($0.view) }
                }
                let range = layout.blockRanges[index]
                return .text(
                    identifier: "native-editor-block-\(block.path.identifier)",
                    label: block.node.type.replacingOccurrences(of: "_", with: " ").capitalized,
                    value: block.text,
                    range: range,
                    activate: { [weak self, weak textView] in
                        guard let self, let textView else { return false }
                        return self.activateFirstTarget(in: range, textView: textView)
                    }
                )
            }
        }

        // MARK: Embedded blocks

        /// Creates, refreshes, and removes the hosted views for embedded
        /// blocks. Their content refreshes on every update, like any view.
        func updateEmbeds(in textView: ReadingFlowTextView) {
            var current: [UUID: ReadingFlowEmbed] = [:]
            for block in parent.blocks where block.isEmbedded {
                let id = block.node.id
                let embed = embeds[id] ?? makeEmbed(blockID: id, in: textView)
                embed.handlesOwnTouches = block.handlesOwnTouches
                embed.controller.rootView = rootView(for: block, embed: embed, textView: textView)
                current[id] = embed
            }
            for (id, embed) in embeds where current[id] == nil {
                remove(embed)
            }
            embeds = current
        }

        private func makeEmbed(blockID: UUID, in textView: ReadingFlowTextView) -> ReadingFlowEmbed {
            let embed = ReadingFlowEmbed(blockID: blockID)
            embed.attachment.height = { [weak embed] width in embed?.height(at: width) ?? 1 }
            textView.addSubview(embed.view)
            adopt(embed.controller)
            return embed
        }

        private func rootView(
            for block: ReadingFlowBlock,
            embed: ReadingFlowEmbed,
            textView: ReadingFlowTextView
        ) -> AnyView {
            AnyView(
                parent.embedContent(block)
                    // Report the content's own height; the view's frame
                    // follows it once the text makes room.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        [weak self, weak embed, weak textView] height in
                        // Geometry changes arrive during layout; resize after it.
                        DispatchQueue.main.async {
                            guard let self, let embed, let textView else { return }
                            self.embed(embed, didChangeHeight: height, in: textView)
                        }
                    }
                    .tint(Color(uiColor: parent.accentColor))
            )
        }

        private func embed(
            _ embed: ReadingFlowEmbed,
            didChangeHeight height: CGFloat,
            in textView: ReadingFlowTextView
        ) {
            let height = ceil(height)
            guard embed.measuredWidth > 0,
                  abs(height - embed.measuredHeight) > 0.5,
                  let index = layout?.embedIndices[embed.attachment.blockID] else { return }
            embed.measuredHeight = height
            textView.layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: index, length: 1),
                actualCharacterRange: nil
            )
            textView.invalidateIntrinsicContentSize()
            textView.setNeedsLayout()
            container?.invalidateIntrinsicContentSize()
        }

        /// Places each embedded view over its attachment.
        func layoutEmbeds(in textView: ReadingFlowTextView) {
            guard let layout, !embeds.isEmpty else { return }
            let layoutManager = textView.layoutManager
            layoutManager.ensureLayout(for: textView.textContainer)
            for (id, index) in layout.embedIndices {
                guard let embed = embeds[id], index < textView.textStorage.length else { continue }
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: index, length: 1),
                    actualCharacterRange: nil
                )
                var frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
                    .offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
                frame.size.height = max(frame.height, embed.measuredHeight)
                if embed.view.frame != frame { embed.view.frame = frame }
            }
        }

        func embedOwnsTouch(at point: CGPoint, in textView: ReadingFlowTextView) -> Bool {
            guard embeds.values.contains(where: {
                $0.handlesOwnTouches && $0.view.frame.contains(point)
            }) else { return false }
            // A selection handle sitting over the view still drags.
            if let range = textView.selectedTextRange, !range.isEmpty {
                let handles = [range.start, range.end].map {
                    textView.caretRect(for: $0).insetBy(dx: -28, dy: -28)
                }
                if handles.contains(where: { $0.contains(point) }) { return false }
            }
            return true
        }

        private func updateEmbedHighlights(in textView: UITextView) {
            guard let layout else { return }
            let selection = textView.selectedRange
            for (id, index) in layout.embedIndices {
                embeds[id]?.view.setSelected(
                    selection.length > 0 && NSLocationInRange(index, selection),
                    tint: parent.accentColor
                )
            }
        }

        /// Embedded hosting controllers join the nearest view controller, so
        /// their views can present sheets and receive appearance calls.
        func adoptEmbedControllers() {
            for embed in embeds.values { adopt(embed.controller) }
        }

        private func adopt(_ controller: UIViewController) {
            guard controller.parent == nil,
                  let parentController = sequence(first: container as UIResponder?, next: { $0?.next })
                    .first(where: { $0 is UIViewController }) as? UIViewController else { return }
            parentController.addChild(controller)
            controller.didMove(toParent: parentController)
        }

        private func remove(_ embed: ReadingFlowEmbed) {
            embed.controller.willMove(toParent: nil)
            embed.view.removeFromSuperview()
            embed.controller.removeFromParent()
        }

        func removeAllEmbeds() {
            embeds.values.forEach(remove)
            embeds = [:]
        }

        func copy(_ range: NSRange) -> Bool {
            guard let selection = layout?.selection(for: range) else { return false }
            return parent.onCopy(selection)
        }

        /// VoiceOver activation opens a block's first link or annotation, the
        /// same targets a tap reaches.
        private func activateFirstTarget(in range: NSRange, textView: UITextView) -> Bool {
            var opened = false
            textView.textStorage.enumerateAttributes(in: range) { attributes, _, stop in
                if let url = attributes[.link] as? URL {
                    open(url)
                    opened = true
                } else if let id = attributes[RichTextCodec.annotationIDKey] as? String,
                          let annotation = parent.annotations.first(where: { $0.id == id }) {
                    parent.onOpenAnnotation(annotation)
                    opened = true
                }
                if opened { stop.pointee = true }
            }
            return opened
        }

        private func open(_ url: URL) {
            if !parent.onOpenURL(url) {
                UIApplication.shared.open(url)
            }
        }

        @objc func openLink(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView,
                  let index = textView.nbeCharacterIndex(at: recognizer.location(in: textView)),
                  let url = textView.textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL
            else { return }
            open(url)
        }

        @objc func openAnnotation(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let textView = recognizer.view as? UITextView,
                  let index = textView.nbeCharacterIndex(at: recognizer.location(in: textView)),
                  let id = textView.textStorage.attribute(
                    RichTextCodec.annotationIDKey,
                    at: index,
                    effectiveRange: nil
                  ) as? String,
                  let annotation = parent.annotations.first(where: { $0.id == id })
            else { return }
            parent.onOpenAnnotation(annotation)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let textView = gestureRecognizer.view as? ReadingFlowTextView,
                  let index = textView.nbeCharacterIndex(at: touch.location(in: textView))
            else { return false }
            if gestureRecognizer === textView.linkTapRecognizer {
                return textView.textStorage.attribute(.link, at: index, effectiveRange: nil) != nil
            }
            if gestureRecognizer === textView.annotationTapRecognizer {
                return textView.textStorage.attribute(
                    RichTextCodec.annotationIDKey,
                    at: index,
                    effectiveRange: nil
                ) != nil
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let textView = gestureRecognizer.view as? ReadingFlowTextView else { return false }
            return gestureRecognizer === textView.linkTapRecognizer
                || otherGestureRecognizer === textView.linkTapRecognizer
                || gestureRecognizer === textView.annotationTapRecognizer
                || otherGestureRecognizer === textView.annotationTapRecognizer
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateEmbedHighlights(in: textView)
            guard textView.isFirstResponder else { return }
            parent.onSelectionChange(layout?.selection(for: textView.selectedRange))
        }

        @available(iOS 17.0, *)
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in self?.open(url) }
        }

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            selectionMenu(range: range, suggestedActions: suggestedActions)
        }

        @available(iOS 26.0, *)
        func textView(
            _ textView: UITextView,
            editMenuForTextInRanges ranges: [NSValue],
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let first = ranges.first else { return UIMenu(children: suggestedActions) }
            let combined = ranges.dropFirst().reduce(first.rangeValue) { NSUnionRange($0, $1.rangeValue) }
            return selectionMenu(range: combined, suggestedActions: suggestedActions)
        }

        private func selectionMenu(range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu {
            guard let onAskAboutSelection = parent.onAskAboutSelection,
                  let selection = layout?.selection(for: range) else {
                return UIMenu(children: suggestedActions)
            }
            let action = UIAction(
                title: "Ask About This",
                image: UIImage(systemName: "sparkles")
            ) { _ in
                onAskAboutSelection(selection)
            }
            return UIMenu(children: suggestedActions + [action])
        }
    }
}

extension NativeBlockEditorTextAnnotation {
    /// Whether this annotation is drawn in `node`. The stable block ID wins
    /// over the path so annotations follow a block that moved.
    func applies(to node: BlockNode, at path: BlockPath) -> Bool {
        if let blockID, let stableBlockID = node.stableBlockID {
            return blockID == stableBlockID
        }
        return self.path == path
    }
}

extension UITextView {
    /// The character under `point`, or nil when the point misses the text.
    func nbeCharacterIndex(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        let containerPoint = CGPoint(
            x: point.x - textContainerInset.left,
            y: point.y - textContainerInset.top
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        guard glyphRect.insetBy(dx: -6, dy: -6).contains(containerPoint) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else { return nil }
        return characterIndex
    }
}
#endif
