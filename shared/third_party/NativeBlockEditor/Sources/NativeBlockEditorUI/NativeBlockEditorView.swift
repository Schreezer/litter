#if os(iOS)
import NativeBlockEditorEngine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Visual and behavioral options for the reusable editor canvas.
///
/// The configuration deliberately contains no application concepts such as
/// folders, persistence, accounts, or CloudKit. Host applications own those
/// concerns and pass a document binding to `NativeBlockEditorView`.
@MainActor
public struct NativeBlockEditorConfiguration {
    public var accentColor: Color
    public var contentMaxWidth: CGFloat
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat
    public var showsFormattingToolbar: Bool
    public var showsDocumentToolbar: Bool
    public var allowsBlockReordering: Bool
    public var isEditable: Bool
    public var showsTrailingAddBlockRow: Bool
    public var hiddenBlockIDs: Set<UUID>
    public var enabledBlockTypes: Set<String>?

    public init(
        accentColor: Color = Color(red: 0, green: 0.737, blue: 0.941),
        contentMaxWidth: CGFloat = 720,
        horizontalPadding: CGFloat = 20,
        verticalPadding: CGFloat = 20,
        showsFormattingToolbar: Bool = true,
        showsDocumentToolbar: Bool = true,
        allowsBlockReordering: Bool = true,
        isEditable: Bool = true,
        showsTrailingAddBlockRow: Bool = true,
        hiddenBlockIDs: Set<UUID> = [],
        enabledBlockTypes: Set<String>? = nil
    ) {
        self.accentColor = accentColor
        self.contentMaxWidth = contentMaxWidth
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.showsFormattingToolbar = showsFormattingToolbar
        self.showsDocumentToolbar = showsDocumentToolbar
        self.allowsBlockReordering = allowsBlockReordering
        self.isEditable = isEditable
        self.showsTrailingAddBlockRow = showsTrailingAddBlockRow
        self.hiddenBlockIDs = hiddenBlockIDs
        self.enabledBlockTypes = enabledBlockTypes
    }

    public static let standard = NativeBlockEditorConfiguration()
}

/// A page-like destination that an embedding application can resolve.
/// NativeBlockEditorUI never owns or persists pages; it only renders and opens
/// references through the supplied callbacks.
public struct NativeBlockEditorPageDestination: Hashable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String
    public var subtitle: String?

    public init(id: String, title: String, systemImage: String = "doc.text", subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
    }
}

public struct NativeBlockEditorSelection: Hashable, Sendable {
    public var blockID: String?
    public var path: BlockPath
    public var range: NSRange
    public var text: String

    public init(blockID: String?, path: BlockPath, range: NSRange, text: String) {
        self.blockID = blockID
        self.path = path
        self.range = range
        self.text = text
    }
}

/// A host-owned, non-document annotation rendered over a text range.
///
/// Annotations never enter the block delta, undo history, clipboard, or saved
/// document. Hosts can therefore use them for discussion anchors and other
/// transient projections without mutating learner-authored content.
public struct NativeBlockEditorTextAnnotation: Hashable, Identifiable, Sendable {
    /// How the annotated range is drawn.
    public enum Style: String, Hashable, Sendable {
        /// A highlighted range the learner is discussing.
        case discussion
        /// A lighter dotted underline where a branch page starts.
        case branch
    }

    public var id: String
    public var blockID: String?
    public var path: BlockPath
    public var range: NSRange
    public var style: Style

    public init(id: String, blockID: String?, path: BlockPath, range: NSRange, style: Style = .discussion) {
        self.id = id
        self.blockID = blockID
        self.path = path
        self.range = range
        self.style = style
    }
}

/// A reusable, persistence-agnostic block document editor.
///
/// Integrators provide a `Binding<BlockDocument>`. The view owns transient UI
/// state and undo history, while the host remains responsible for saving,
/// syncing, navigation, and page/folder organization.
@MainActor
public struct NativeBlockEditorView: View {
    public typealias PageResolver = (String) -> NativeBlockEditorPageDestination?
    public typealias CustomBlockRenderer = (BlockNode, BlockPath) -> AnyView?

    private static let textColors: [EditorInlineStyleChoice] = [
        .init(id: "default", name: "Default", value: nil),
        .init(id: "gray", name: "Gray", value: "0xff8f959e"),
        .init(id: "brown", name: "Brown", value: "0xffa66a3f"),
        .init(id: "orange", name: "Orange", value: "0xffff8a00"),
        .init(id: "yellow", name: "Yellow", value: "0xffd6a600"),
        .init(id: "green", name: "Green", value: "0xff2aa876"),
        .init(id: "blue", name: "Blue", value: "0xff2f80ed"),
        .init(id: "purple", name: "Purple", value: "0xff9b51e0"),
        .init(id: "pink", name: "Pink", value: "0xffe255a1"),
        .init(id: "red", name: "Red", value: "0xffe5484d"),
    ]
    private static let highlightColors: [EditorInlineStyleChoice] = [
        .init(id: "none", name: "None", value: nil),
        .init(id: "gray", name: "Gray", value: "0x338f959e"),
        .init(id: "orange", name: "Orange", value: "0x33ff8a00"),
        .init(id: "yellow", name: "Yellow", value: "0x40ffd43b"),
        .init(id: "green", name: "Green", value: "0x332aa876"),
        .init(id: "blue", name: "Blue", value: "0x332f80ed"),
        .init(id: "purple", name: "Purple", value: "0x339b51e0"),
        .init(id: "pink", name: "Pink", value: "0x33e255a1"),
        .init(id: "red", name: "Red", value: "0x33e5484d"),
    ]
    private static let textSizes: [EditorInlineStyleChoice] = [
        .init(id: "default", name: "Default size", value: nil),
        .init(id: "small", name: "Small", value: 14),
        .init(id: "body", name: "Body", value: 16),
        .init(id: "large", name: "Large", value: 20),
        .init(id: "title", name: "Title", value: 24),
    ]
    private static let fontFamilies: [EditorInlineStyleChoice] = [
        .init(id: "system", name: "System", value: nil),
        .init(id: "avenir", name: "Avenir", value: "AvenirNext-Regular"),
        .init(id: "serif", name: "Serif", value: "Georgia"),
        .init(id: "monospaced", name: "Monospaced", value: "Menlo-Regular"),
    ]

    @Binding private var document: BlockDocument
    private let configuration: NativeBlockEditorConfiguration
    private let header: AnyView?
    private let footer: AnyView?
    private let initialReadingPosition: NativeBlockEditorReadingPosition?
    private let onReadingPositionChange: ((NativeBlockEditorReadingPosition) -> Void)?
    private let pageResolver: PageResolver?
    private let onOpenPage: ((NativeBlockEditorPageDestination) -> Void)?
    private let onOpenURL: ((URL) -> Bool)?
    private let customBlockRenderer: CustomBlockRenderer?
    private let onDocumentChange: ((BlockDocument) -> Void)?
    private let onSelectionChange: ((NativeBlockEditorSelection) -> Void)?
    private let onAskAboutSelection: ((NativeBlockEditorSelection) -> Void)?
    private let textAnnotations: [NativeBlockEditorTextAnnotation]
    private let onOpenTextAnnotation: ((NativeBlockEditorTextAnnotation) -> Void)?
    @Binding private var wrapsCodeLines: Bool

    @State private var engine: BlockDocumentEngine
    @State private var revision = 0
    @State private var errorMessage: String?
    @State private var focusRequest: EditorFocusRequest?
    @State private var draggedBlockID: UUID?
    @State private var dropTarget: EditorDropTarget?
    @State private var selectedManagedBlockID: UUID?
    @StateObject private var editingSession = RichTextEditingSession()

    public init(
        document: Binding<BlockDocument>,
        configuration: NativeBlockEditorConfiguration = .standard,
        header: AnyView? = nil,
        footer: AnyView? = nil,
        pageResolver: PageResolver? = nil,
        onOpenPage: ((NativeBlockEditorPageDestination) -> Void)? = nil,
        onOpenURL: ((URL) -> Bool)? = nil,
        customBlockRenderer: CustomBlockRenderer? = nil,
        onDocumentChange: ((BlockDocument) -> Void)? = nil,
        onAskAboutSelection: ((NativeBlockEditorSelection) -> Void)? = nil,
        onSelectionChange: ((NativeBlockEditorSelection) -> Void)? = nil,
        textAnnotations: [NativeBlockEditorTextAnnotation] = [],
        onOpenTextAnnotation: ((NativeBlockEditorTextAnnotation) -> Void)? = nil,
        wrapsCodeLines: Binding<Bool> = .constant(false),
        initialReadingPosition: NativeBlockEditorReadingPosition? = nil,
        onReadingPositionChange: ((NativeBlockEditorReadingPosition) -> Void)? = nil
    ) {
        _document = document
        self.configuration = configuration
        self.header = header
        self.footer = footer
        self.initialReadingPosition = initialReadingPosition
        self.onReadingPositionChange = onReadingPositionChange
        self.pageResolver = pageResolver
        self.onOpenPage = onOpenPage
        self.onOpenURL = onOpenURL
        self.customBlockRenderer = customBlockRenderer
        self.onDocumentChange = onDocumentChange
        self.onSelectionChange = onSelectionChange
        self.onAskAboutSelection = onAskAboutSelection
        self.textAnnotations = textAnnotations
        self.onOpenTextAnnotation = onOpenTextAnnotation
        _wrapsCodeLines = wrapsCodeLines
        _engine = State(initialValue: BlockDocumentEngine(document: Self.anchored(document.wrappedValue)))
    }

    @ViewBuilder
    private var canvasContent: some View {
        if let header { header.padding(.bottom, 12) }
        ForEach(visibleBlocks) { block in
            blockRow(block)
        }
        if configuration.isEditable {
            if visibleBlocks.isEmpty {
                emptyDocumentActions
            } else if configuration.showsTrailingAddBlockRow {
                addBlockRow
            } else {
                trailingWritingArea
            }
        }
        if let footer { footer.padding(.top, 24) }
    }

    public var body: some View {
        ScrollView {
            Group {
                if onReadingPositionChange != nil {
                    // Eager reading layout gives restoration stable content geometry,
                    // including a long block in the middle of an article.
                    VStack(alignment: .leading, spacing: 0) { canvasContent }
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) { canvasContent }
                }
            }
            .frame(maxWidth: configuration.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, configuration.horizontalPadding)
            .padding(.top, configuration.verticalPadding)
            .padding(.bottom, 72)
            .frame(maxWidth: .infinity)
        }
        .modifier(NativeBlockEditorReadingModifier(
            initialPosition: initialReadingPosition,
            onChange: onReadingPositionChange.map { callback in
                { position in if !configuration.isEditable { callback(position) } }
            }
        ))
        .background(Color(uiColor: .systemBackground))
        .tint(configuration.accentColor)
        .toolbar {
            if configuration.isEditable, configuration.showsDocumentToolbar {
                documentToolbar
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if configuration.isEditable,
               configuration.showsFormattingToolbar,
               editingSession.activePath != nil {
                formattingToolbar
            }
        }
        .alert(
            "The edit could not be applied",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onChange(of: document) { _, updated in
            guard updated != engine.document else { return }
            engine = BlockDocumentEngine(document: Self.anchored(updated))
            if let selectedManagedBlockID,
               !updated.flattenedNodes().contains(where: { $0.node.id == selectedManagedBlockID }) {
                self.selectedManagedBlockID = nil
            }
            revision &+= 1
        }
        .onChange(of: editingSession.activePath) { _, path in
            if path != nil { selectedManagedBlockID = nil }
        }
    }

    private var visibleBlocks: [EditorVisibleBlock] {
        _ = revision
        return Self.flatten(
            engine.document.root.children,
            hiddenBlockIDs: configuration.hiddenBlockIDs
        )
    }

    @ToolbarContentBuilder
    private var documentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { perform { _ = try engine.undo() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!engine.canUndo)
            .accessibilityLabel("Undo")

            Button { perform { _ = try engine.redo() } } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!engine.canRedo)
            .accessibilityLabel("Redo")

            Menu {
                Toggle(isOn: $wrapsCodeLines) {
                    Label("Wrap code lines", systemImage: "text.word.spacing")
                }
                Divider()
                addBlockButtons
                Divider()
                Button("Copy document", systemImage: "doc.on.doc") { copyDocument() }
                Button("Paste rich content", systemImage: "doc.on.clipboard") { pasteDocument() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Document actions")
            .accessibilityIdentifier("native-editor-document-actions")
        }
    }

    @ViewBuilder
    private func blockRow(_ block: EditorVisibleBlock) -> some View {
        let isManaged = isManagedBlock(block)
        let isSelected = selectedManagedBlockID == block.id
        let content = blockContent(block)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? configuration.accentColor.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(configuration.accentColor.opacity(0.8), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if configuration.isEditable, isManaged, block.depth == 0 {
                    managedBlockHandle(block, isSelected: isSelected)
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard configuration.isEditable, isManaged else { return }
                    editingSession.dismissKeyboard()
                    selectedManagedBlockID = block.id
                }
            )
        .padding(.leading, CGFloat(block.depth) * 22)
        .padding(.vertical, block.depth == 0 ? 3 : 1)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if dropTarget == EditorDropTarget(blockID: block.id, placement: .before) {
                Rectangle().fill(configuration.accentColor).frame(height: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if dropTarget == EditorDropTarget(blockID: block.id, placement: .after) {
                Rectangle().fill(configuration.accentColor).frame(height: 3)
            }
        }

        if configuration.isEditable, configuration.allowsBlockReordering, block.depth == 0 {
            content.overlay {
                if draggedBlockID != nil {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            dropZone(block, placement: .before)
                                .frame(height: geometry.size.height / 2)
                            dropZone(block, placement: .after)
                                .frame(height: geometry.size.height / 2)
                        }
                    }
                }
            }
        } else {
            content
        }
    }

    private func managedBlockHandle(_ block: EditorVisibleBlock, isSelected: Bool) -> some View {
        Menu {
            managedBlockActions(block)
        } label: {
            Image(systemName: "circle.grid.2x3.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? configuration.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: -22)
        .onDrag {
            selectedManagedBlockID = block.id
            draggedBlockID = block.id
            return NSItemProvider(object: block.id.uuidString as NSString)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                editingSession.dismissKeyboard()
                selectedManagedBlockID = block.id
            }
        )
        .accessibilityLabel("Block actions, \(managedBlockName(block.node))")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("native-editor-block-actions-\(block.path.identifier)")
    }

    @ViewBuilder
    private func managedBlockActions(_ block: EditorVisibleBlock) -> some View {
        if onAskAboutSelection != nil {
            Button("Ask Course Agent", systemImage: "sparkles") {
                askAboutBlock(block)
            }
        }

        switch block.node.type {
        case "columns":
            Button("Add column", systemImage: "rectangle.split.3x1") {
                perform { try engine.addColumn(at: block.path) }
            }
            Button("Remove last column", systemImage: "rectangle.split.2x1", role: .destructive) {
                perform { try engine.deleteLastColumn(at: block.path) }
            }
            .disabled(block.node.children.count <= 1)
            Divider()
        case "table":
            let rows = max(0, block.node.data["rowsLen"]?.intValue ?? 0)
            let columns = max(0, block.node.data["colsLen"]?.intValue ?? 0)
            Button("Add row", systemImage: "rectangle.split.1x2") {
                perform { try engine.addTableRow(at: block.path) }
            }
            Button("Add column", systemImage: "rectangle.split.2x1") {
                perform { try engine.addTableColumn(at: block.path) }
            }
            Button("Remove last row", systemImage: "minus.rectangle", role: .destructive) {
                perform { try engine.deleteTableRow(at: block.path, index: rows - 1) }
            }
            .disabled(rows <= 1)
            Button("Remove last column", systemImage: "minus.rectangle", role: .destructive) {
                perform { try engine.deleteTableColumn(at: block.path, index: columns - 1) }
            }
            .disabled(columns <= 1)
            Divider()
        default:
            EmptyView()
        }

        Button("Copy", systemImage: "doc.on.doc") {
            copyManagedBlock(block)
        }
        Button("Duplicate", systemImage: "plus.square.on.square") {
            duplicateManagedBlock(block)
        }

        Divider()

        Button("Move up", systemImage: "arrow.up") {
            moveManagedBlock(block, delta: -1)
        }
        .disabled(block.path.last == 0)
        Button("Move down", systemImage: "arrow.down") {
            moveManagedBlock(block, delta: 1)
        }
        .disabled(block.path.last == engine.document.root.children.count - 1)

        Divider()

        Button("Delete \(managedBlockName(block.node))", systemImage: "trash", role: .destructive) {
            deleteManagedBlock(block)
        }
    }

    private func isManagedBlock(_ block: EditorVisibleBlock) -> Bool {
        block.depth == 0 && block.node.delta == nil && block.node.type != "column"
    }

    private func managedBlockName(_ node: BlockNode) -> String {
        switch node.type {
        case "image": return "image"
        case "nbe/media": return node.data["kind"]?.stringValue ?? "media"
        case "table": return "table"
        case "columns": return "column group"
        case "divider": return "divider"
        case "link_preview": return "link preview"
        case "nbe/child_page", "nbe/page_reference": return "page reference"
        case "nbe/plugin": return "plugin"
        case "nbe/database": return "database"
        case "nbe/html": return "embed"
        default: return "block"
        }
    }

    private func askAboutBlock(_ block: EditorVisibleBlock) {
        let text = managedBlockContext(block.node)
        onAskAboutSelection?(NativeBlockEditorSelection(
            blockID: block.node.stableBlockID,
            path: block.path,
            range: NSRange(location: 0, length: text.utf16.count),
            text: text
        ))
    }

    private func managedBlockContext(_ node: BlockNode) -> String {
        var details: [String] = []
        for key in ["title", "caption", "alt", "kind", "url"] {
            if let value = node.data[key]?.stringValue, !value.isEmpty {
                details.append("\(key.capitalized): \(value)")
            }
        }
        details.append(contentsOf: node.children.flatMap(Self.plainTextFragments))
        let body = details.isEmpty ? "No additional text metadata." : details.joined(separator: "\n")
        return "Entire \(managedBlockName(node)) block:\n\(body)"
    }

    private static func plainTextFragments(_ node: BlockNode) -> [String] {
        var fragments: [String] = []
        if let text = node.delta?.plainText.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            fragments.append(text)
        }
        fragments.append(contentsOf: node.children.flatMap(plainTextFragments))
        return fragments
    }

    private func copyManagedBlock(_ block: EditorVisibleBlock) {
        do {
            try EditorClipboard.write(BlockDocument(
                root: BlockNode(type: "page", children: [block.node])
            ))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func duplicateManagedBlock(_ block: EditorVisibleBlock) {
        guard let index = block.path.last else { return }
        let duplicate = Self.duplicateNode(block.node)
        perform { try engine.insertNode(duplicate, at: BlockPath([index + 1])) }
        selectedManagedBlockID = duplicate.id
    }

    private static func duplicateNode(_ node: BlockNode) -> BlockNode {
        var data = node.data
        data["block_id"] = .string(UUID().uuidString.lowercased())
        return BlockNode(
            type: node.type,
            data: data,
            children: node.children.map(duplicateNode)
        )
    }

    private func moveManagedBlock(_ block: EditorVisibleBlock, delta: Int) {
        guard let index = block.path.last else { return }
        let destinationIndex = index + delta
        guard destinationIndex >= 0,
              destinationIndex < engine.document.root.children.count else { return }
        let destination = delta > 0
            ? BlockPath([destinationIndex + 1])
            : BlockPath([destinationIndex])
        perform { try engine.moveNode(from: block.path, to: destination) }
    }

    private func deleteManagedBlock(_ block: EditorVisibleBlock) {
        perform { try engine.deleteNode(at: block.path) }
        selectedManagedBlockID = nil
    }

    private func dropZone(_ block: EditorVisibleBlock, placement: EditorDropTarget.Placement) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.text],
                delegate: EditorReorderDropDelegate(
                    target: EditorDropTarget(blockID: block.id, placement: placement),
                    draggedBlockID: $draggedBlockID,
                    dropTarget: $dropTarget,
                    commit: moveBlock
                )
            )
    }

    @ViewBuilder
    private func blockContent(_ block: EditorVisibleBlock) -> some View {
        switch block.node.type {
        case "divider":
            Rectangle().fill(Color(uiColor: .separator))
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.vertical, 14)
        case "quote":
            textEditor(block)
                .padding(.leading, 18)
                .overlay(alignment: .leading) {
                    Rectangle().fill(configuration.accentColor).frame(width: 4)
                }
        case "todo_list", "bulleted_list", "numbered_list":
            HStack(alignment: .top, spacing: 5) {
                listMarker(block)
                    .frame(width: 24, alignment: .top)
                    .frame(minHeight: 24, alignment: .top)
                textEditor(block)
            }
        case "paragraph", "heading":
            textEditor(block)
        case "code":
            codeEditor(block)
        case "nbe/formula":
            HStack(alignment: .top, spacing: 8) {
                Text("ƒ").foregroundStyle(configuration.accentColor)
                textEditor(block)
            }
            .padding(10)
            .background(configuration.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case "nbe/child_page", "nbe/page_reference":
            pageBlock(block)
        case "image":
            DocumentImageBlockView(
                node: block.node,
                identifier: block.path.identifier,
                onResize: { width in
                    perform { try engine.updateNode(at: block.path, attributes: ["width": .number(width)]) }
                }
            )
        case "table":
            tableBlock(block)
        case "columns":
            columnsBlock(block)
        case "column":
            nestedChildren(block)
        case "nbe/media":
            NativeMediaBlockView(node: block.node, identifier: block.path.identifier)
        case "link_preview":
            LinkPreviewBlockView(node: block.node)
        case "nbe/plugin":
            PluginBlockView(node: block.node, identifier: block.path.identifier)
        case "nbe/database":
            DatabaseBlockView(
                node: block.node,
                identifier: block.path.identifier,
                onCellChange: { row, column, value in
                    perform { try engine.updateDatabaseCell(at: block.path, rowID: row, columnID: column, value: value) }
                },
                onAddRow: { perform { try engine.addDatabaseRow(at: block.path) } }
            )
        case "nbe/html":
            BrowserHTMLBlockContainer(
                html: block.node.data["html"]?.stringValue ?? "",
                allowNetwork: block.node.data["allow_network"]?.boolValue ?? false,
                allowJavaScript: block.node.data["allow_javascript"]?.boolValue ?? false,
                identifier: block.path.identifier
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        default:
            if let rendered = customBlockRenderer?(block.node, block.path) {
                rendered
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Unsupported block", systemImage: "shippingbox")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(block.node.delta?.plainText ?? block.node.type)
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func codeEditor(_ block: EditorVisibleBlock) -> some View {
        if wrapsCodeLines {
            textEditor(block)
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        } else {
            ScrollView(.horizontal) {
                textEditor(block)
                    .frame(width: unwrappedCodeWidth(for: block), alignment: .leading)
                    .padding(12)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func unwrappedCodeWidth(for block: EditorVisibleBlock) -> CGFloat {
        let font = BlockTextStyle.style(for: block.node).font
        let longestLine = (block.node.delta?.plainText ?? "")
            .components(separatedBy: .newlines)
            .max(by: { $0.count < $1.count }) ?? ""
        let measuredWidth = (longestLine as NSString).size(withAttributes: [.font: font]).width
        return max(1, ceil(measuredWidth) + 2)
    }

    private func textEditor(_ block: EditorVisibleBlock) -> some View {
        RichTextBlockEditor(
            delta: block.node.delta ?? TextDelta(),
            path: block.path,
            textStyle: .style(for: block.node),
            accessibilityLabel: block.node.type.replacingOccurrences(of: "_", with: " ").capitalized,
            accessibilityIdentifier: "native-editor-block-\(block.path.identifier)",
            session: editingSession,
            isEditable: configuration.isEditable,
            onDeltaChange: { replaceText(at: block.path, with: $0) },
            splitsOnReturn: !["code", "nbe/formula"].contains(block.node.type),
            focusRequestID: focusRequest?.path == block.path ? focusRequest?.id : nil,
            focusRequestOffset: focusRequest?.path == block.path ? focusRequest?.offset ?? 0 : 0,
            onFocusRequestHandled: { if focusRequest?.path == block.path { focusRequest = nil } },
            onReturn: { splitBlock(at: block.path, offset: $0) },
            onDeleteBackwardAtEmpty: { deleteEmptyBlock(at: block.path) },
            onCopy: { copyInline(at: block.path, range: $0) },
            onCut: { cutInline(at: block.path, range: $0) },
            onPaste: { pasteInline(at: block.path, range: $0) },
            onOpenURL: { onOpenURL?($0) ?? false },
            onAskAboutSelection: { range, text in
                onAskAboutSelection?(NativeBlockEditorSelection(
                    blockID: block.node.stableBlockID,
                    path: block.path,
                    range: range,
                    text: text
                ))
            },
            annotations: textAnnotations.filter { annotation in
                if let blockID = annotation.blockID,
                   let stableBlockID = block.node.stableBlockID {
                    return blockID == stableBlockID
                }
                return annotation.path == block.path
            },
            onOpenAnnotation: { annotation in
                onOpenTextAnnotation?(annotation)
            },
            onSelectionChange: { range in
                try? engine.setSelection(Selection(path: block.path, startOffset: range.location, endOffset: NSMaxRange(range)))
                let text = (block.node.delta?.plainText ?? "") as NSString
                guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return }
                onSelectionChange?(NativeBlockEditorSelection(
                    blockID: block.node.stableBlockID,
                    path: block.path,
                    range: range,
                    text: text.substring(with: range)
                ))
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func listMarker(_ block: EditorVisibleBlock) -> some View {
        switch block.node.type {
        case "todo_list":
            let checked = block.node.data["checked"]?.boolValue ?? false
            Button { perform { try engine.toggleTodo(at: block.path) } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(checked ? configuration.accentColor : .clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(checked ? configuration.accentColor : Color(uiColor: .systemGray3), lineWidth: 1.5)
                        }
                    if checked {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(!configuration.isEditable)
        case "bulleted_list":
            Text("•").font(.system(size: 18, weight: .semibold))
        case "numbered_list":
            Text("\(block.number ?? 1).").monospacedDigit()
        default:
            EmptyView()
        }
    }

    private func pageBlock(_ block: EditorVisibleBlock) -> some View {
        let pageID = block.node.data["page_id"]?.stringValue ?? ""
        let destination = pageResolver?(pageID)
        let fallbackTitle = block.node.data["title"]?.stringValue ?? "Untitled"
        return Button {
            if let destination { onOpenPage?(destination) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination?.systemImage ?? "doc.text")
                    .foregroundStyle(destination == nil ? Color.secondary : configuration.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination?.title ?? fallbackTitle).font(.body.weight(.medium))
                    if let subtitle = destination?.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    } else if destination == nil {
                        Text("Page unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(destination == nil || onOpenPage == nil)
    }

    private func tableBlock(_ block: EditorVisibleBlock) -> some View {
        let rows = max(0, block.node.data["rowsLen"]?.intValue ?? 0)
        let columns = max(0, block.node.data["colsLen"]?.intValue ?? 0)
        var cells: [String: (Int, BlockNode)] = [:]
        for (index, cell) in block.node.children.enumerated() {
            guard let row = cell.data["rowPosition"]?.intValue,
                  let column = cell.data["colPosition"]?.intValue else { continue }
            cells["\(row):\(column)"] = (index, cell)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Table", systemImage: "tablecells").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Menu("Edit") {
                    Button("Add row") { perform { try engine.addTableRow(at: block.path) } }
                    Button("Delete last row", role: .destructive) {
                        perform { try engine.deleteTableRow(at: block.path, index: rows - 1) }
                    }.disabled(rows <= 1)
                    Button("Add column") { perform { try engine.addTableColumn(at: block.path) } }
                    Button("Delete last column", role: .destructive) {
                        perform { try engine.deleteTableColumn(at: block.path, index: columns - 1) }
                    }.disabled(columns <= 1)
                }.font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0 ..< rows, id: \.self) { row in
                        GridRow {
                            ForEach(0 ..< columns, id: \.self) { column in
                                if let (cellIndex, cell) = cells["\(row):\(column)"] {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(cell.children.enumerated()), id: \.element.id) { childIndex, child in
                                            if child.delta != nil {
                                                textEditor(EditorVisibleBlock(
                                                    node: child,
                                                    path: block.path.appending(cellIndex).appending(childIndex),
                                                    depth: 0,
                                                    number: nil
                                                ))
                                            }
                                        }
                                    }
                                    .frame(minWidth: 132, minHeight: 42, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .overlay { Rectangle().stroke(Color(uiColor: .separator), lineWidth: 0.5) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func columnsBlock(_ block: EditorVisibleBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Columns", systemImage: "rectangle.split.3x1")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Add", systemImage: "plus") { perform { try engine.addColumn(at: block.path) } }
                    .font(.caption)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(block.node.children.enumerated()), id: \.element.id) { columnIndex, column in
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(column.children.enumerated()), id: \.element.id) { childIndex, child in
                                AnyView(blockContent(EditorVisibleBlock(
                                    node: child,
                                    path: block.path.appending(columnIndex).appending(childIndex),
                                    depth: 0,
                                    number: nil
                                )))
                            }
                        }
                        .frame(width: column.data["width"]?.doubleValue ?? 220, alignment: .topLeading)
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func nestedChildren(_ block: EditorVisibleBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(block.node.children.enumerated()), id: \.element.id) { childIndex, child in
                AnyView(blockContent(EditorVisibleBlock(
                    node: child,
                    path: block.path.appending(childIndex),
                    depth: 0,
                    number: nil
                )))
            }
        }
    }

    private var addBlockRow: some View {
        Menu {
            addBlockButtons
        } label: {
            Label("Add a block", systemImage: "plus")
                .foregroundStyle(configuration.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
        .accessibilityIdentifier("native-editor-add-block")
    }

    private var trailingWritingArea: some View {
        Button {
            addBlock(.paragraph(), focus: true)
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue writing")
        .accessibilityHint("Adds a text block at the end of the page")
        .accessibilityIdentifier("native-editor-continue-writing")
    }

    private var emptyDocumentActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Start writing", systemImage: "square.and.pencil") {
                addBlock(.paragraph(), focus: true)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("native-editor-start-writing")

            Menu {
                addBlockButtons
            } label: {
                Label("Add another block type", systemImage: "plus")
            }
            .accessibilityIdentifier("native-editor-empty-add-block")
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var addBlockButtons: some View {
        blockButton("Text", systemImage: "text.alignleft", type: "paragraph", node: .paragraph())
        blockButton("Heading", systemImage: "textformat.size.larger", type: "heading", node: .heading())
        blockButton("To-do", systemImage: "checkmark.square", type: "todo_list", node: .todo())
        blockButton("Bulleted list", systemImage: "list.bullet", type: "bulleted_list", node: .bulletedList())
        blockButton("Numbered list", systemImage: "list.number", type: "numbered_list", node: .numberedList())
        blockButton("Quote", systemImage: "text.quote", type: "quote", node: .quote())
        blockButton("Code", systemImage: "chevron.left.forwardslash.chevron.right", type: "code", node: .code())
        blockButton("Formula", systemImage: "function", type: "nbe/formula", node: .formula())
        blockButton("Divider", systemImage: "minus", type: "divider", node: .divider())
        blockButton("Table", systemImage: "tablecells", type: "table", node: .table(cellRows: [[ [.paragraph()], [.paragraph()] ], [ [.paragraph()], [.paragraph()] ]]))
        blockButton("Columns", systemImage: "rectangle.split.2x1", type: "columns", node: .columns())
        blockButton("HTML", systemImage: "safari", type: "nbe/html", node: .html("<p>Edit this HTML through your application hook.</p>"))
    }

    @ViewBuilder
    private func blockButton(_ title: String, systemImage: String, type: String, node: BlockNode) -> some View {
        if configuration.enabledBlockTypes == nil || configuration.enabledBlockTypes?.contains(type) == true {
            Button(title, systemImage: systemImage) { addBlock(node, focus: node.delta != nil) }
        }
    }

    private var formattingToolbar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if onAskAboutSelection != nil,
                       editingSession.selectedTextRange != nil,
                       editingSession.selectedText != nil {
                        Button {
                            askAboutActiveSelection()
                        } label: {
                            Label("Ask AI", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(height: 40)
                                .background(
                                    configuration.accentColor.opacity(0.16),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(configuration.accentColor)
                        .accessibilityIdentifier("native-editor-ask-selection")

                        Divider()
                            .frame(height: 24)
                            .padding(.horizontal, 2)
                    }

                    ForEach(InlineFormat.allCases) { format in
                        let isSelected = editingSession.selectedFormats.contains(format)
                        Button { editingSession.toggle(format) } label: {
                            formattingIcon(format)
                                .frame(width: 40, height: 40)
                                .background(
                                    isSelected ? configuration.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? configuration.accentColor : Color.primary)
                        .accessibilityLabel(format.accessibilityLabel)
                        .accessibilityIdentifier("native-editor-format-\(format.rawValue)")
                    }

                    Divider()
                        .frame(height: 24)
                        .padding(.horizontal, 2)

                    Menu {
                        addBlockButtons
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add block")
                    .accessibilityIdentifier("native-editor-toolbar-add-block")

                    textStyleMenu
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
            }

            Button { editingSession.dismissKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Dismiss keyboard")
            .accessibilityIdentifier("native-editor-dismiss-keyboard")
        }
        .frame(height: 49)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func askAboutActiveSelection() {
        guard let path = editingSession.activePath,
              let range = editingSession.selectedTextRange,
              let text = editingSession.selectedText,
              let block = visibleBlocks.first(where: { $0.path == path }) else {
            return
        }
        onAskAboutSelection?(NativeBlockEditorSelection(
            blockID: block.node.stableBlockID,
            path: path,
            range: range,
            text: text
        ))
    }

    private var textStyleMenu: some View {
        Menu {
            Menu("Block style", systemImage: "paragraphsign") {
                blockStyleButtons
            }
            .accessibilityIdentifier("native-editor-block-style-menu")

            Divider()

            inlineStyleMenu(
                "Text color",
                systemImage: "paintpalette",
                key: "font_color",
                choices: Self.textColors,
                idPrefix: "native-editor-text-color"
            )
            inlineStyleMenu(
                "Highlight",
                systemImage: "highlighter",
                key: "bg_color",
                choices: Self.highlightColors,
                idPrefix: "native-editor-highlight"
            )
            inlineStyleMenu(
                "Text size",
                systemImage: "textformat.size",
                key: "font_size",
                choices: Self.textSizes,
                idPrefix: "native-editor-text-size"
            )
            inlineStyleMenu(
                "Font",
                systemImage: "textformat",
                key: "font_family",
                choices: Self.fontFamilies,
                idPrefix: "native-editor-font"
            )

            Divider()

            Button("Clear text formatting", systemImage: "eraser") {
                editingSession.clearTextFormatting()
            }
            .accessibilityIdentifier("native-editor-clear-formatting")
        } label: {
            Image(systemName: "textformat.size")
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Text style")
        .accessibilityHint("Change the block style, color, highlight, size, or font")
        .accessibilityIdentifier("native-editor-text-style-menu")
    }

    private func inlineStyleMenu(
        _ title: String,
        systemImage: String,
        key: String,
        choices: [EditorInlineStyleChoice],
        idPrefix: String
    ) -> some View {
        Menu(title, systemImage: systemImage) {
            ForEach(choices) { choice in
                Button {
                    editingSession.setInlineAttribute(key, value: choice.value)
                } label: {
                    Label(
                        choice.name,
                        systemImage: editingSession.selectedValue(for: key) == choice.value
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
                .accessibilityIdentifier("\(idPrefix)-\(choice.id)")
            }
        }
        .accessibilityIdentifier("\(idPrefix)-menu")
    }

    @ViewBuilder
    private var blockStyleButtons: some View {
        blockStyleButton("Text", systemImage: "text.alignleft", type: "paragraph")
        blockStyleButton("Heading 1", systemImage: "textformat.size.larger", type: "heading", attributes: ["level": 1])
        blockStyleButton("Heading 2", systemImage: "textformat.size", type: "heading", attributes: ["level": 2])
        blockStyleButton("Heading 3", systemImage: "textformat.size.smaller", type: "heading", attributes: ["level": 3])
        blockStyleButton("To-do", systemImage: "checkmark.square", type: "todo_list")
        blockStyleButton("Bulleted list", systemImage: "list.bullet", type: "bulleted_list")
        blockStyleButton("Numbered list", systemImage: "list.number", type: "numbered_list")
        blockStyleButton("Quote", systemImage: "text.quote", type: "quote")
        blockStyleButton("Code block", systemImage: "chevron.left.forwardslash.chevron.right", type: "code", attributes: ["language": "swift"])
    }

    @ViewBuilder
    private func blockStyleButton(
        _ title: String,
        systemImage: String,
        type: String,
        attributes: [String: JSONValue] = [:]
    ) -> some View {
        if configuration.enabledBlockTypes == nil || configuration.enabledBlockTypes?.contains(type) == true {
            let isSelected = activeBlockMatches(type: type, attributes: attributes)
            Button {
                changeActiveBlock(type: type, attributes: attributes)
            } label: {
                Label(title, systemImage: isSelected ? "checkmark.circle.fill" : systemImage)
            }
        }
    }

    private func activeBlockMatches(type: String, attributes: [String: JSONValue]) -> Bool {
        guard let path = editingSession.activePath,
              let node = engine.node(at: path),
              node.type == type else { return false }
        return attributes.allSatisfy { node.data[$0.key] == $0.value }
    }

    private func changeActiveBlock(type: String, attributes: [String: JSONValue]) {
        guard let path = editingSession.activePath else { return }
        perform { try engine.changeBlockType(at: path, to: type, attributes: attributes) }
    }

    @ViewBuilder
    private func formattingIcon(_ format: InlineFormat) -> some View {
        switch format {
        case .bold: Text("B").bold()
        case .italic: Text("I").italic()
        case .underline: Text("U").underline()
        case .strikethrough: Text("S").strikethrough()
        case .code: Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
    }

    private func replaceText(at path: BlockPath, with newDelta: TextDelta) {
        guard let oldDelta = engine.node(at: path)?.delta else { return }
        let content = newDelta.normalized()
        guard content != oldDelta.normalized() else { return }
        var operations = content.operations
        if oldDelta.contentUTF16Length > 0 { operations.append(.delete(oldDelta.contentUTF16Length)) }
        let change = TextDelta(operations).normalized()
        if engine.node(at: path)?.type == "nbe/formula" {
            perform { try engine.editFormula(at: path, change: change) }
        } else {
            perform { try engine.editText(at: path, change: change) }
        }
    }

    private func splitBlock(at path: BlockPath, offset: Int) {
        do {
            let next = try path.nextSibling()
            try engine.splitBlock(at: path, offset: offset)
            focusRequest = EditorFocusRequest(path: next)
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEmptyBlock(at path: BlockPath) {
        guard let delta = engine.node(at: path)?.delta, delta.contentUTF16Length == 0 else { return }
        do {
            let transaction = try engine.deleteEmptyTextBlock(at: path)
            guard !transaction.operations.isEmpty else { return }
            if let position = engine.selection?.normalized.start {
                focusRequest = EditorFocusRequest(path: position.path, offset: position.offset)
            }
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addBlock(_ node: BlockNode, focus: Bool) {
        let path = BlockPath([engine.document.root.children.count])
        do {
            try engine.insertNode(node, at: path)
            if focus { focusRequest = EditorFocusRequest(path: path) }
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveBlock(_ sourceID: UUID, _ target: EditorDropTarget) {
        defer {
            draggedBlockID = nil
            dropTarget = nil
        }
        guard sourceID != target.blockID,
              let source = engine.document.root.children.firstIndex(where: { $0.id == sourceID }),
              let destination = engine.document.root.children.firstIndex(where: { $0.id == target.blockID }) else { return }
        let insertion = target.placement == .before ? destination : destination + 1
        do {
            try engine.moveNode(from: [source], to: [insertion])
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyInline(at path: BlockPath, range: NSRange) -> Bool {
        guard range.length > 0,
              let node = engine.node(at: path),
              let delta = node.delta,
              let slice = try? delta.slice(from: range.location, to: NSMaxRange(range)) else { return false }
        var fragment = node
        fragment.delta = slice
        fragment.children = []
        do {
            try EditorClipboard.write(BlockDocument(root: BlockNode(type: "page", children: [fragment])))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func cutInline(at path: BlockPath, range: NSRange) -> Bool {
        guard copyInline(at: path, range: range) else { return false }
        do {
            try engine.editText(at: path, change: TextDelta([.retain(range.location), .delete(range.length)]))
            publishChange()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func pasteInline(at path: BlockPath, range: NSRange) -> Bool {
        do {
            guard let fragment = try EditorClipboard.read() else { return false }
            try engine.replaceTextRange(at: path, range: range.location ..< NSMaxRange(range), with: fragment)
            publishChange()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func copyDocument() {
        do { try EditorClipboard.write(engine.document) }
        catch { errorMessage = error.localizedDescription }
    }

    private func pasteDocument() {
        do {
            guard let fragment = try EditorClipboard.read() else { return }
            try engine.insertNodes(fragment.root.children, at: [engine.document.root.children.count])
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            publishChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishChange() {
        document = engine.document
        revision &+= 1
        onDocumentChange?(engine.document)
    }

    private static func anchored(_ document: BlockDocument) -> BlockDocument {
        var document = document
        document.ensureStableBlockIDs()
        return document
    }

    private static func flatten(
        _ nodes: [BlockNode],
        parent: BlockPath = [],
        depth: Int = 0,
        hiddenBlockIDs: Set<UUID> = []
    ) -> [EditorVisibleBlock] {
        var result: [EditorVisibleBlock] = []
        var nextNumber = 1
        for (index, node) in nodes.enumerated() {
            guard !hiddenBlockIDs.contains(node.id) else { continue }
            let path = parent.appending(index)
            let number: Int?
            if node.type == "numbered_list" {
                number = node.data["number"]?.intValue ?? nextNumber
                nextNumber = (number ?? nextNumber) + 1
            } else {
                number = nil
                nextNumber = 1
            }
            result.append(EditorVisibleBlock(node: node, path: path, depth: depth, number: number))
            if !["table", "columns", "column"].contains(node.type) {
                result.append(contentsOf: flatten(
                    node.children,
                    parent: path,
                    depth: depth + 1,
                    hiddenBlockIDs: hiddenBlockIDs
                ))
            }
        }
        return result
    }
}

private struct EditorVisibleBlock: Identifiable {
    let node: BlockNode
    let path: BlockPath
    let depth: Int
    let number: Int?
    var id: UUID { node.id }
}

private struct EditorInlineStyleChoice: Identifiable {
    let id: String
    let name: String
    let value: JSONValue?
}

private struct EditorFocusRequest: Equatable {
    let id = UUID()
    let path: BlockPath
    let offset: Int

    init(path: BlockPath, offset: Int = 0) {
        self.path = path
        self.offset = offset
    }
}

private struct EditorDropTarget: Equatable {
    enum Placement { case before, after }
    let blockID: UUID
    let placement: Placement
}

private struct EditorReorderDropDelegate: DropDelegate {
    let target: EditorDropTarget
    @Binding var draggedBlockID: UUID?
    @Binding var dropTarget: EditorDropTarget?
    let commit: (UUID, EditorDropTarget) -> Void

    func dropEntered(info: DropInfo) {
        guard draggedBlockID != nil else { return }
        dropTarget = target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedBlockID else { return false }
        commit(draggedBlockID, target)
        return true
    }
}

private extension BlockPath {
    var identifier: String { indices.map(String.init).joined(separator: "-") }
}
#endif
