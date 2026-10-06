import CryptoKit
import NativeBlockEditorCore
import NativeBlockEditorUI
import SwiftUI
import UIKit

struct CourseSelectionDiscussionConflict: Identifiable {
    let id: UUID
    let existing: CourseSelectionDiscussion
    let reference: CourseTextReference
    let selectedTarget: CourseAgentExecutionTarget

    init(
        id: UUID = UUID(),
        existing: CourseSelectionDiscussion,
        reference: CourseTextReference,
        selectedTarget: CourseAgentExecutionTarget
    ) {
        self.id = id
        self.existing = existing
        self.reference = reference
        self.selectedTarget = selectedTarget
    }
}

private struct CourseSelectionDiscussionAlertsModifier: ViewModifier {
    @Binding var chatError: String?
    @Binding var conflict: CourseSelectionDiscussionConflict?
    let onContinueExisting: (CourseSelectionDiscussion) -> Void
    let onReplaceConflict: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                "Can’t start discussion",
                isPresented: Binding(
                    get: { chatError != nil },
                    set: { if !$0 { chatError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { chatError = nil }
                    .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.failure-ok")
            } message: {
                Text(chatError ?? "The selected agent is unavailable.")
            }
            .alert(
                "A discussion already exists",
                isPresented: Binding(
                    get: { conflict != nil },
                    set: { if !$0 { conflict = nil } }
                )
            ) {
                if let conflict {
                    Button(
                        "Continue with \(conflict.existing.agentRuntimeKind?.displayLabel ?? "Existing Agent")"
                    ) {
                        onContinueExisting(conflict.existing)
                        self.conflict = nil
                    }
                    .accessibilityIdentifier(
                        "courseRecoveryCheckpoint.conflict.continue-existing"
                    )
                    Button(
                        "Close & Start New with \(conflict.selectedTarget.displayName)",
                        role: .destructive
                    ) {
                        onReplaceConflict()
                    }
                    .accessibilityIdentifier(
                        "courseRecoveryCheckpoint.conflict.close-start-new"
                    )
                }
                Button("Cancel", role: .cancel) { conflict = nil }
                    .accessibilityIdentifier("courseRecoveryCheckpoint.conflict.cancel")
            } message: {
                if let conflict {
                    Text(
                        "This exact passage already has an open discussion with \(conflict.existing.agentRuntimeKind?.displayLabel ?? "another agent"). You selected \(conflict.selectedTarget.displayName)."
                    )
                }
            }
    }
}

extension View {
    func courseSelectionDiscussionAlerts(
        chatError: Binding<String?>,
        conflict: Binding<CourseSelectionDiscussionConflict?>,
        onContinueExisting: @escaping (CourseSelectionDiscussion) -> Void,
        onReplaceConflict: @escaping () -> Void
    ) -> some View {
        modifier(CourseSelectionDiscussionAlertsModifier(
            chatError: chatError,
            conflict: conflict,
            onContinueExisting: onContinueExisting,
            onReplaceConflict: onReplaceConflict
        ))
    }
}

#if DEBUG
struct CourseEditorRuntimeProbeConfiguration: Equatable {
    static let enableFlag = "--live-acceptance-editor-runtime-probes"
    static let runTokenFlag = "--live-acceptance-run-token"
    static let keyEnvironmentVariable = "LEARNFOLD_EDITOR_RUNTIME_PROBE_HMAC_KEY"

    let runToken: String
    private let keyData: Data

    init(runToken: String, keyData: Data) {
        self.runToken = runToken
        self.keyData = keyData
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CourseEditorRuntimeProbeConfiguration? {
        // A strict/component fixture can exercise the same production view,
        // but it is never admissible as live runtime evidence.
        guard !arguments.contains(where: {
            $0.hasPrefix("--ui-test-") || $0.hasPrefix("--checkpoint-")
        }) else { return nil }
        guard arguments.filter({ $0 == enableFlag }).count == 1 else { return nil }

        let tokenIndices = arguments.indices.filter { arguments[$0] == runTokenFlag }
        guard tokenIndices.count == 1, let tokenIndex = tokenIndices.first else { return nil }
        let valueIndex = arguments.index(after: tokenIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        let suppliedToken = arguments[valueIndex]
        guard let uuid = UUID(uuidString: suppliedToken),
              suppliedToken == uuid.uuidString.lowercased() else { return nil }

        guard let encodedKey = environment[keyEnvironmentVariable],
              let keyData = Data(base64Encoded: encodedKey),
              keyData.count == 32 else { return nil }
        return CourseEditorRuntimeProbeConfiguration(
            runToken: suppliedToken,
            keyData: keyData
        )
    }

    func digest(domain: String, data: Data) -> String {
        var authenticatedData = Data("learnfold-editor-probe-v1\u{0}\(runToken)\u{0}\(domain)\u{0}".utf8)
        authenticatedData.append(data)
        let code = HMAC<SHA256>.authenticationCode(
            for: authenticatedData,
            using: SymmetricKey(data: keyData)
        )
        return code.map { String(format: "%02x", $0) }.joined()
    }

    func digest(domain: String, value: String) -> String {
        digest(domain: domain, data: Data(value.utf8))
    }
}

/// Hashing and canonicalization shared by the Debug-only runtime evidence
/// markers. Every content-derived digest is a per-run HMAC, so known or
/// low-entropy learner text cannot be recovered by comparing public hashes.
enum CourseEditorRuntimeProbeDigest {
    static func document(
        _ document: BlockDocument,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(document) {
            return configuration.digest(domain: "lf50-document", data: data)
        }
        // Keep the field a deterministic digest without leaking a failed
        // payload. BlockDocument is Codable, so this path is defensive only.
        return configuration.digest(
            domain: "lf50-document",
            value: "block-document-encoding-unavailable"
        )
    }

    static func order(
        _ document: BlockDocument,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = document.flattenedNodes().map { entry in
            let path = entry.path.indices.map(String.init).joined(separator: ".")
            let nodeIdentity = entry.node.stableBlockID
                ?? (try? encoder.encode(entry.node)).map {
                    configuration.digest(domain: "lf50-order-node", data: $0)
                }
                ?? configuration.digest(
                    domain: "lf50-order-node",
                    value: "unidentified-block"
                )
            return "\(path)|\(nodeIdentity)|\(entry.node.type)"
        }
        .joined(separator: "\u{0}")
        return configuration.digest(domain: "lf50-order", value: canonical)
    }
}

struct CourseEditorLF50RuntimeProbeSnapshot: Equatable {
    let saveState: String
    let hasPendingEdit: Bool
    let confirmedRevision: Int64?
    let documentDigest: String
    let orderDigest: String

    @MainActor
    init(
        model: CoursePageEditorModel,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) {
        saveState = model.saveState.runtimeProbeValue
        hasPendingEdit = model.runtimeProbeHasPendingEdit
        confirmedRevision = model.runtimeProbeConfirmedRevision
        documentDigest = CourseEditorRuntimeProbeDigest.document(
            model.document,
            configuration: configuration
        )
        orderDigest = CourseEditorRuntimeProbeDigest.order(
            model.document,
            configuration: configuration
        )
    }

    var accessibilityValue: String {
        [
            "save-state=\(saveState)",
            "pending-edit=\(hasPendingEdit)",
            "confirmed-revision=\(confirmedRevision.map { String($0) } ?? "none")",
            "document-digest=\(documentDigest)",
            "order-digest=\(orderDigest)",
        ].joined(separator: ";")
    }
}

struct CourseEditorLF51RuntimeProbeState: Equatable {
    private struct SelectionReceipt: Equatable {
        let selectedTextDigest: String
        let selectedTextUTF16Length: Int
        let blockID: String?
        let path: [Int]
        let range: NSRange
        let resolvedPageID: String?
    }

    private struct AnnotationCallbackReceipt: Equatable {
        let annotationID: String
        let blockID: String?
        let path: [Int]
        let range: NSRange
        let wasOpened: Bool

        func matchesGeometry(of annotation: NativeBlockEditorTextAnnotation) -> Bool {
            blockID == annotation.blockID
                && path == annotation.path.indices
                && range == annotation.range
        }
    }

    private struct CallbackReceipt: Equatable {
        let kind: String
        let count: Int
        let result: String
    }

    private var selectionReceipt: SelectionReceipt?
    private var annotationCallbackReceipt: AnnotationCallbackReceipt?
    private var callbackReceipt: CallbackReceipt?

    mutating func recordSelection(
        _ selection: NativeBlockEditorSelection,
        resolvedReference: CourseTextReference?,
        callbackResult: String,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) {
        let normalized = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSelectedText = resolvedReference?.selectedText ?? normalized
        selectionReceipt = SelectionReceipt(
            selectedTextDigest: configuration.digest(
                domain: "lf51-selected-text",
                value: resolvedSelectedText
            ),
            selectedTextUTF16Length: resolvedSelectedText.utf16.count,
            blockID: resolvedReference?.blockID ?? selection.blockID,
            path: resolvedReference?.pathIndices ?? selection.path.indices,
            range: NSRange(
                location: resolvedReference?.rangeLocation ?? selection.range.location,
                length: resolvedReference?.rangeLength ?? selection.range.length
            ),
            resolvedPageID: resolvedReference?.pageID
        )
        recordCallback(kind: "selection", result: callbackResult)
    }

    mutating func recordOpenedAnnotation(
        _ annotation: NativeBlockEditorTextAnnotation,
        wasOpened: Bool,
        callbackResult: String
    ) {
        annotationCallbackReceipt = AnnotationCallbackReceipt(
            annotationID: annotation.id,
            blockID: annotation.blockID,
            path: annotation.path.indices,
            range: annotation.range,
            wasOpened: wasOpened
        )
        recordCallback(kind: "annotation", result: callbackResult)
    }

    var hookAccessibilityValue: String? {
        guard let callbackReceipt else { return nil }
        return [
            "callback-kind=\(callbackReceipt.kind)",
            "callback-count=\(callbackReceipt.count)",
            "callback-result=\(callbackReceipt.result)",
        ].joined(separator: ";")
    }

    func accessibilityValue(
        annotationProvenances: [CourseEditorLF51AnnotationStoreProvenance]
    ) -> String {
        var fields: [String] = []
        if let selectionReceipt {
            fields += [
                "selected-text-digest=\(selectionReceipt.selectedTextDigest)",
                "selected-text-utf16-length=\(selectionReceipt.selectedTextUTF16Length)",
                "selection-block=\(selectionReceipt.blockID ?? "none")",
                "selection-path=\(Self.pathValue(selectionReceipt.path))",
                "selection-range=\(Self.rangeValue(selectionReceipt.range))",
                "resolved-page-id=\(selectionReceipt.resolvedPageID ?? "unresolved")",
            ]
        }

        let sortedProvenances = annotationProvenances.sorted(by: {
            $0.annotation.id < $1.annotation.id
        })
        let callbackProvenance = annotationCallbackReceipt.flatMap { receipt in
            sortedProvenances.first(where: {
                $0.annotation.id == receipt.annotationID
            })
        }
        let provenance = callbackProvenance ?? sortedProvenances.first
        if let provenance {
            let annotation = provenance.annotation
            let wasOpened = annotationCallbackReceipt?.annotationID == annotation.id
                && annotationCallbackReceipt?.wasOpened == true
                && annotationCallbackReceipt?.matchesGeometry(of: annotation) == true
            fields += [
                "annotation-id=\(annotation.id)",
                "annotation-projection=\(wasOpened ? "opened" : "projected")",
                "annotation-block=\(annotation.blockID ?? "none")",
                "annotation-path=\(Self.pathValue(annotation.path.indices))",
                "annotation-range=\(Self.rangeValue(annotation.range))",
                "annotation-page-id=\(provenance.resolvedPageID)",
                "reopen-persistence-receipt=\(provenance.storeReceipt)",
            ]
        }
        return fields.joined(separator: ";")
    }

    private mutating func recordCallback(kind: String, result: String) {
        callbackReceipt = CallbackReceipt(
            kind: kind,
            count: (callbackReceipt?.count ?? 0) + 1,
            result: result
        )
    }

    private static func pathValue(_ path: [Int]) -> String {
        path.isEmpty ? "root" : path.map(String.init).joined(separator: ".")
    }

    private static func rangeValue(_ range: NSRange) -> String {
        "\(range.location):\(range.length)"
    }
}

struct CourseEditorLF51AnnotationStoreProvenance: Equatable {
    private struct ReceiptPayload: Encodable {
        let discussionID: String
        let courseID: String
        let pageID: String
        let blockID: String?
        let path: [Int]
        let rangeLocation: Int
        let rangeLength: Int
        let selectedText: String
        let wasTruncated: Bool
        let status: String
        let projectedBlockID: String?
        let projectedPath: [Int]
        let projectedRangeLocation: Int
        let projectedRangeLength: Int
    }

    let annotation: NativeBlockEditorTextAnnotation
    let resolvedPageID: String
    let storeReceipt: String

    init?(
        discussion: CourseSelectionDiscussion,
        annotation: NativeBlockEditorTextAnnotation,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) {
        guard annotation.id == discussion.id.uuidString else { return nil }
        let payload = ReceiptPayload(
            discussionID: discussion.id.uuidString,
            courseID: discussion.courseID,
            pageID: discussion.pageID,
            blockID: discussion.blockID,
            path: discussion.pathIndices,
            rangeLocation: discussion.rangeLocation,
            rangeLength: discussion.rangeLength,
            selectedText: discussion.selectedText,
            wasTruncated: discussion.wasTruncated,
            status: discussion.status.rawValue,
            projectedBlockID: annotation.blockID,
            projectedPath: annotation.path.indices,
            projectedRangeLocation: annotation.range.location,
            projectedRangeLength: annotation.range.length
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return nil }
        self.annotation = annotation
        resolvedPageID = discussion.pageID
        storeReceipt = configuration.digest(
            domain: "lf51-persisted-selection-discussion",
            data: data
        )
    }
}
#endif

@MainActor
private final class CourseReadingViewport {
    var position: NativeBlockEditorReadingPosition?
}

private struct CoursePageChatPresentation: Identifiable {
    let context: CoursePageChatContext
    let discussionID: UUID
    var assessment: CourseAssessmentDefinition? = nil
    var assessmentAttempt: CourseAssessmentAttempt? = nil

    var id: UUID { discussionID }
}

struct CoursePageEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    let course: LearningCourse
    let pageID: String
    @Bindable var store: CourseExperienceStore

    @State private var model: CoursePageEditorModel?
    @State private var readingNodes: [CourseLearningNode] = []
    @State private var initialReadingPosition: NativeBlockEditorReadingPosition?
    @State private var latestReadingViewport = CourseReadingViewport()
    @State private var loadingError: String?
    @State private var reloadGeneration = 0
    @State private var chatError: String?
    @State private var activePageChat: CoursePageChatPresentation?
    @State private var assessmentAttempts: CourseAssessmentAttemptStore?
    @State private var assessmentStorageError: String?
    @State private var activeDiscussion: CourseSelectionDiscussion?
    @State private var discussionConflict: CourseSelectionDiscussionConflict?
    @State private var explorationLauncher = CourseExplorationLauncher()
#if DEBUG
    @State private var lf51RuntimeProbeState = CourseEditorLF51RuntimeProbeState()
#endif

    private var loadID: CoursePageEditorLoadID {
        CoursePageEditorLoadID(
            courseID: course.id,
            workspaceID: course.workspaceID,
            pageID: pageID,
            reloadGeneration: reloadGeneration
        )
    }

    var body: some View {
        // Keep modal presentation attached to one concrete host as the reader
        // and assessment state update underneath an open discussion.
        ZStack {
            if let model, !model.isLoading {
                #if targetEnvironment(macCatalyst)
                macReadingWorkspace(for: model)
                #else
                editorCanvas(for: model)
                #endif
            } else if let loadingError {
                CoursePageLoadFailureView(pageID: pageID, error: loadingError) {
                    model = nil
                    self.loadingError = nil
                    reloadGeneration &+= 1
                }
            } else {
                ProgressView("Opening course page…")
                    .accessibilityIdentifier("course-page-opening-\(pageID)")
            }
        }
        // Stable outer marker on the real product hierarchy. It remains
        // present across opening, loaded, failed-load, and post-dialog states
        // without encoding a course or page identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-page-editor-root")
#if DEBUG
        .overlay(alignment: .topLeading) {
            runtimeProbeOverlay
        }
#endif
        #if targetEnvironment(macCatalyst)
        // The window title names the course; an empty title would fall back
        // to the app name.
        .navigationTitle(course.title)
        #else
        .navigationTitle("")
        #endif
        .task(id: loadID) {
            await loadPage(requestID: loadID)
        }
        .onDisappear {
            guard let model else { return }
            Task { await model.flush() }
        }
        #if targetEnvironment(macCatalyst)
        .onChange(of: pageID) { _, _ in closeInlineDiscussion() }
        .onChange(of: course.id) { _, _ in closeInlineDiscussion() }
        #else
        .fullScreenCover(item: $activePageChat) { chat in
            NavigationStack {
                pageDiscussionView(chat)
            }
            .id(chat.discussionID)
        }
        .fullScreenCover(item: $activeDiscussion) { discussion in
            if let reference = discussion.reference {
                NavigationStack {
                    selectionDiscussionView(discussion, reference: reference)
                }
#if DEBUG
                .overlay(alignment: .topLeading) {
                    runtimeProbeOverlay
                }
#endif
                .id(discussion.id)
            } else {
                // A full-screen cover has no swipe-to-dismiss, so presenting
                // nothing here left the learner on a blank screen with no way
                // back. (The sheet this replaced could at least be dragged
                // away.) A discussion can lose its reference when its anchor
                // no longer resolves against the current page text.
                CourseSelectionDiscussionUnavailableView {
                    activeDiscussion = nil
                }
            }
        }
        #endif
        .courseSelectionDiscussionAlerts(
            chatError: $chatError,
            conflict: $discussionConflict,
            onContinueExisting: presentSelectionDiscussion,
            onReplaceConflict: replaceConflictingDiscussion
        )
        .task(id: store.courseWorkspaceRefreshVersion) {
            // New explorations fork off this page while it stays open.
            guard model != nil,
                  let repository = try? await store.documentRepository(for: course),
                  let outline = try? await repository.outline(),
                  !Task.isCancelled else { return }
            readingNodes = outline.learningPages
        }
    }

    private func editorCanvas(
        for model: CoursePageEditorModel,
        onToggleOutline: (() -> Void)? = nil,
        isOutlineVisible: Bool = false
    ) -> some View {
        CoursePageEditorCanvas(
            model: model,
            textAnnotations: textAnnotations(in: model),
            onAskAboutSelection: { selection in
                askAboutSelection(selection, model: model)
            },
            onExploreSelection: isReadablePage ? { selection, question in
                try await explorationLauncher.fork(
                    explorationRequest(
                        direction: .question,
                        question: question,
                        quotedPassage: selection.text,
                        model: model
                    ),
                    anchor: CourseSelectionAnchorResolver.reference(
                        courseID: course.id,
                        pageID: pageID,
                        pageTitle: model.title,
                        selection: selection,
                        document: model.document
                    ).map {
                        CourseExplorationAnchor(
                            blockID: $0.blockID,
                            pathIndices: $0.pathIndices,
                            rangeLocation: $0.rangeLocation,
                            rangeLength: $0.rangeLength,
                            selectedText: $0.selectedText
                        )
                    },
                    course: course, store: store, appModel: appModel, appState: appState
                )
            } : nil,
            explorationOverlap: { selection in explorationOverlap(with: selection, in: model) },
            explorationStatus: explorationStatus,
            onOpenTextAnnotation: { annotation in
                openDiscussion(annotation: annotation)
            },
            onTapTextAnnotations: handleAnnotationHit,
            passageThreads: passageThreads,
            onPassageAction: performPassageAction,
            onOpenPage: { destination in
                // A link to an exploration follows the same rule as everywhere
                // else: written pages open, unwritten ones are written instead.
                if let node = CourseExplorationMap.node(withPageID: destination.id, in: readingNodes),
                   CourseExplorationMap.isExploration(node) {
                    explorationLauncher.open(node, course: course, store: store, appModel: appModel, appState: appState)
                } else {
                    store.openCoursePage(courseID: course.id, pageID: destination.id)
                }
            },
            readingFooter: readingFooter(for: model),
            additionalHiddenReadingBlockIDs: CourseAssessmentPageContent.extract(
                from: model.document
            ).hiddenBlockIDs,
            onAskAboutPage: { openPageChat(model: model) },
            initialReadingPosition: initialReadingPosition,
            onReadingPositionChange: { position in
                guard store.navigationPath.last == .coursePage(courseID: course.id, pageID: pageID),
                      isReadablePage else { return }
                latestReadingViewport.position = position
                store.saveReadingBookmark(CourseReadingBookmark(
                    pageID: pageID, offset: position.offset, isAtEnd: position.isAtEnd
                ), for: course)
                store.recordReading(pageID: pageID, isAtEnd: position.isAtEnd, for: course)
            },
            onToggleOutline: onToggleOutline,
            isOutlineVisible: isOutlineVisible
        )
        .id(pageID)
        .onAppear {
            if let position = latestReadingViewport.position {
                store.saveReadingBookmark(CourseReadingBookmark(
                    pageID: pageID, offset: position.offset, isAtEnd: position.isAtEnd
                ), for: course)
            }
        }
    }

    private func pageDiscussionView(
        _ chat: CoursePageChatPresentation,
        isEmbedded: Bool = false
    ) -> CourseChatView {
        CourseChatView(
            store: store,
            pageContext: chat.context,
            selectionDiscussionID: chat.discussionID,
            showsDismissButton: true,
            isEmbedded: isEmbedded,
            onDismiss: isEmbedded ? closeInlineDiscussion : nil,
            onSelectionDiscussionReplaced: { replacement in
                presentPageDiscussion(CoursePageChatPresentation(
                    context: chat.context,
                    discussionID: replacement.id,
                    assessment: chat.assessment,
                    assessmentAttempt: chat.assessmentAttempt
                ))
            },
            onAssistantInitiationSent: {
                guard let attempt = chat.assessmentAttempt else { return }
                do {
                    try assessmentAttempts?.markDiscussionStarted(for: attempt)
                } catch {
                    chatError = error.localizedDescription
                }
            }
        )
    }

    private func selectionDiscussionView(
        _ discussion: CourseSelectionDiscussion,
        reference: CourseTextReference,
        isEmbedded: Bool = false
    ) -> CourseChatView {
        CourseChatView(
            store: store,
            selectionContext: reference,
            selectionDiscussionID: discussion.id,
            showsDismissButton: true,
            isEmbedded: isEmbedded,
            onDismiss: isEmbedded ? closeInlineDiscussion : nil,
            onSelectionDiscussionReplaced: presentSelectionDiscussion
        )
    }

    private func presentPageDiscussion(_ presentation: CoursePageChatPresentation) {
        #if targetEnvironment(macCatalyst)
        activeDiscussion = nil
        #endif
        activePageChat = presentation
    }

    private func presentSelectionDiscussion(_ discussion: CourseSelectionDiscussion) {
        #if targetEnvironment(macCatalyst)
        activePageChat = nil
        #endif
        activeDiscussion = discussion
    }

    private func closeInlineDiscussion() {
        activePageChat = nil
        activeDiscussion = nil
    }

    #if targetEnvironment(macCatalyst)
    private func macReadingWorkspace(for model: CoursePageEditorModel) -> some View {
        MacCourseReadingWorkspace(
            courseTitle: course.title,
            nodes: CourseLearningPathResolver.overlayGeneratingStatus(
                in: readingNodes,
                targetNodeIDs: store.activeExplorationNodeIDs(courseID: course.id).union(
                    store.backgroundGeneratingCourseID == course.id
                        ? store.backgroundGeneratingNodeID.map { [$0] } ?? [] : []
                )
            ),
            selectedPageID: pageID,
            runtimeID: course.agentRuntimeKind ?? CourseAgentProvider.codex,
            generationDisabled: store.isCourseNodeGenerationDisabled,
            hasDiscussion: activePageChat != nil || activeDiscussion != nil,
            onOpenPage: { destinationID in
                guard destinationID != pageID else { return }
                store.openReadingPage(
                    courseID: course.id, pageID: destinationID, replacingCurrentPage: true
                )
            },
            onGenerate: { node in
                if CourseExplorationMap.isExploration(node) {
                    // Explorations have their own writers; the course agent
                    // stays free, and nothing opens when the page is written.
                    explorationLauncher.open(
                        node, course: course, store: store, appModel: appModel, appState: appState
                    )
                } else {
                    store.generateCourseNodeInBackground(
                        for: course, node: node, appModel: appModel, appState: appState
                    )
                }
            },
            reader: { chrome in
                editorCanvas(
                    for: model,
                    onToggleOutline: chrome.toggleOutline,
                    isOutlineVisible: chrome.isOutlineVisible
                )
            },
            discussion: { inlineDiscussion }
        )
    }

    @ViewBuilder
    private var inlineDiscussion: some View {
        if let chat = activePageChat {
            pageDiscussionView(chat, isEmbedded: true)
                .id(chat.discussionID)
        } else if let discussion = activeDiscussion {
            if let reference = discussion.reference {
                selectionDiscussionView(discussion, reference: reference, isEmbedded: true)
                    .id(discussion.id)
            } else {
                ContentUnavailableView {
                    Label("This discussion is unavailable", systemImage: "text.badge.xmark")
                } description: {
                    Text("Its passage is no longer part of this page.")
                } actions: {
                    Button("Back to lesson", action: closeInlineDiscussion)
                        .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("course-selection-discussion-unavailable")
            }
        }
    }
    #endif

    private func openPageChat(model: CoursePageEditorModel, initialQuestion: String? = nil) {
        let context = CoursePageChatContext(
            pageID: pageID,
            pageTitle: model.title,
            content: AppFlowyMarkdownCodec().encode(model.document),
            initialQuestion: initialQuestion
        )
        do {
            let discussion = try store.beginPageDiscussion(for: course, context: context)
            presentPageDiscussion(CoursePageChatPresentation(
                context: context,
                discussionID: discussion.id
            ))
        } catch {
            chatError = error.localizedDescription
        }
    }

    /// Lesson navigation, when this page is part of the reading order.
    private func readingFooter(for model: CoursePageEditorModel) -> AnyView? {
        let content = CourseAssessmentPageContent.extract(from: model.document)
        guard !content.hiddenBlockIDs.isEmpty else { return lessonReadingFooter }
        return AnyView(VStack(alignment: .leading, spacing: 24) {
            if let assessmentAttempts {
                CourseAssessmentPanel(
                    assessments: content.assessments,
                    invalidCheckCount: content.invalidCheckCount,
                    attempts: assessmentAttempts,
                    review: { assessment, attempt in
                        let context = CoursePageChatContext(
                            pageID: pageID,
                            pageTitle: model.title,
                            content: AppFlowyMarkdownCodec().encode(model.document)
                        )
                        return try await store.reviewAssessment(
                            assessment,
                            attempt: attempt,
                            context: context,
                            course: course,
                            appModel: appModel
                        )
                    },
                    discuss: { assessment, attempt, openingQuestion in
                        openAssessmentDiscussion(
                            assessment, attempt: attempt, openingQuestion: openingQuestion, model: model
                        )
                    }
                )
                .id("\(course.id)/\(pageID)/assessment-section")
            } else {
                Label(
                    assessmentStorageError ?? "Saved practice is unavailable. You can continue reading.",
                    systemImage: "exclamationmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("course-assessment-storage-error")
            }
            if let lessonReadingFooter { lessonReadingFooter }
        })
    }

    private func openAssessmentDiscussion(
        _ assessment: CourseAssessmentDefinition,
        attempt: CourseAssessmentAttempt?,
        openingQuestion: String?,
        model: CoursePageEditorModel
    ) {
        // A slow review may finish after the learner has opened another page.
        // Save its feedback, but only present chat from its own visible page.
        guard store.navigationPath.last == .coursePage(courseID: course.id, pageID: pageID) else { return }
        let latestAttempt = assessmentAttempts?.latestAttempt(for: assessment) ?? attempt
        let pageContext = CoursePageChatContext(
            pageID: pageID, pageTitle: model.title,
            content: AppFlowyMarkdownCodec().encode(model.document)
        )
        var instruction: String?
        // Keep the frozen opening available for a replacement thread too.
        // Scoped acceptance receipts prevent replay on the existing thread.
        do {
            let rawAnswer = assessment.kind == .multipleChoice
                ? latestAttempt?.selectedOptionID
                : latestAttempt?.answerText
            let trimmedAnswer = rawAnswer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = buildCourseAssessmentDiscussionPrompt(
                assessment: assessment,
                pageContext: pageContext.content,
                learnerAnswer: trimmedAnswer.isEmpty ? nil : trimmedAnswer,
                openingQuestion: openingQuestion
            )
            guard let generated = prompt.prompt else {
                chatError = prompt.error ?? "This discussion can’t be started."
                return
            }
            if let latestAttempt {
                // Keep one durable opening per attempt, even if unrelated page
                // prose changes before a failed or interrupted send is retried.
                let identified = generated + "\n<learnfold_assessment_attempt_id>\(latestAttempt.id.uuidString)</learnfold_assessment_attempt_id>"
                do {
                    instruction = try assessmentAttempts?.discussionInstruction(
                        for: latestAttempt, creating: identified
                    ) ?? identified
                } catch {
                    chatError = error.localizedDescription
                    return
                }
            } else {
                instruction = generated
            }
        }
        let context = CoursePageChatContext(
            pageID: pageID,
            pageTitle: model.title,
            content: AppFlowyMarkdownCodec().encode(model.document),
            assistantInitiation: instruction
        )
        do {
            let discussion = try store.beginPageDiscussion(for: course, context: context)
            presentPageDiscussion(CoursePageChatPresentation(
                context: context, discussionID: discussion.id, assessment: assessment,
                assessmentAttempt: latestAttempt
            ))
        } catch {
            chatError = error.localizedDescription
        }
    }

    /// Planned lessons and explorations alike: every page on the course map.
    private var isReadablePage: Bool {
        CourseReadingOrder.readablePages(in: readingNodes).contains { $0.pageID == pageID }
    }

    private var lessonReadingFooter: AnyView? {
        guard isReadablePage,
              let node = CourseExplorationMap.node(withPageID: pageID, in: readingNodes) else { return nil }
        let isExploration = CourseExplorationMap.isExploration(node)
        let progress = store.explorationProgress(for: course)
        return AnyView(VStack(alignment: .leading, spacing: 28) {
            CourseWhereNextSection(
                exploredFromHere: node.children.filter(CourseExplorationMap.isExploration),
                stateOf: { store.explorationState(of: $0, courseID: course.id, progress: progress) },
                labelOf: explorationLabel,
                forkParent: CourseExplorationMap.forkParent(ofPageID: pageID, in: readingNodes),
                isExploration: isExploration,
                isPinned: progress.pinnedNodeIDs.contains(node.id),
                launcher: explorationLauncher,
                onFork: { direction, question in
                    guard let model else { return }
                    launchExploration(
                        direction: direction, question: question, quotedPassage: nil, model: model
                    )
                },
                onOpen: { child in
                    explorationLauncher.open(
                        child, course: course, store: store, appModel: appModel, appState: appState
                    )
                },
                onBack: returnToForkParent,
                onTogglePin: { store.togglePinnedGoal(nodeID: node.id, for: course) }
            )
            suggestedRouteFooter(isExploration: isExploration)
        })
    }

    /// The approved plan stays available as a suggested route, never a rail.
    @ViewBuilder
    private func suggestedRouteFooter(isExploration: Bool) -> some View {
        if let next = CourseReadingOrder.next(after: pageID, in: readingNodes) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggested route")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                CourseLessonActionButton(
                    course: course, node: next, store: store,
                    title: isExploration ? "Back to the suggested route" : "Next lesson",
                    replacesCurrentPage: true
                )
            }
        } else {
            VStack(spacing: 12) {
                Label("You’ve reached the end of the suggested route", systemImage: "checkmark.circle")
                    .font(.headline)
                Button("Back to course") {
                    store.navigationPath = [.course(course.id)]
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("course-reading-end")
        }
    }

    private func launchExploration(
        direction: CourseExplorationDirection,
        question: String?,
        quotedPassage: String?,
        model: CoursePageEditorModel
    ) {
        explorationLauncher.launch(
            explorationRequest(direction: direction, question: question, quotedPassage: quotedPassage, model: model),
            course: course, store: store, appModel: appModel, appState: appState
        )
    }

    private func explorationRequest(
        direction: CourseExplorationDirection,
        question: String?,
        quotedPassage: String?,
        model: CoursePageEditorModel
    ) -> CourseExplorationRequest {
        let explored = CourseExplorationMap.explorations(in: readingNodes)
            .filter { $0.status == .generated && $0.pageID != pageID }
            .map(\.title)
        return CourseExplorationRequest(
            parentPageID: pageID,
            parentTitle: model.title,
            direction: direction,
            question: question,
            quotedPassage: quotedPassage,
            exploredTitles: explored
        )
    }

    /// Every exploration the learner started in this course, from any page,
    /// as one quiet status in the reader's toolbar.
    private var explorationStatus: CourseExplorationStatusContent? {
        let summary = CourseExplorationStatusSummary(
            jobs: store.explorationJobs(courseID: course.id),
            currentPageID: pageID
        )
        guard !summary.isEmpty else { return nil }
        return CourseExplorationStatusContent(
            summary: summary,
            currentPageID: pageID,
            onOpen: { job in
                guard let childPageID = job.pageID else {
                    store.dismissExplorationJob(nodeID: job.id)
                    return
                }
                store.openReadingPage(courseID: course.id, pageID: childPageID, replacingCurrentPage: false)
            },
            onRetry: { job in
                store.retryExploration(nodeID: job.id, appModel: appModel, appState: appState)
            },
            onDismiss: { job in store.dismissExplorationJob(nodeID: job.id) },
            onMarkAllSeen: { store.dismissExplorationNotices(courseID: course.id) }
        )
    }

    /// The explorations that fork from this page, in the order they were forked.
    private var explorationsFromHere: [CourseLearningNode] {
        (CourseExplorationMap.node(withPageID: pageID, in: readingNodes)?.children ?? [])
            .filter(CourseExplorationMap.isExploration)
    }

    /// How the learner asked for an exploration, until it has its own title.
    private func explorationLabel(_ node: CourseLearningNode) -> String {
        store.explorationJob(nodeID: node.id)?.label ?? CourseExplorationRequest.statusLabel(for: node)
    }

    /// A tap on highlighted text. Explorations show everything that starts
    /// there; a discussion on its own opens directly, as it always has.
    /// Returns true when the passage's threads should be shown.
    private func handleAnnotationHit(_ hit: NativeBlockEditorAnnotationHit) -> Bool {
        let nodeIDs = hit.annotations.compactMap(CourseSelectionAnchorResolver.branchNodeID(of:))
        guard !nodeIDs.isEmpty else {
            openDiscussion(annotation: hit.primary)
            return false
        }
        // ⌘-click is the Mac shortcut straight into a single written page.
        if hit.isCommandClick, hit.annotations.count == 1,
           let node = explorationsFromHere.first(where: { $0.id == nodeIDs[0] }),
           store.explorationState(
               of: node, courseID: course.id, progress: store.explorationProgress(for: course)
           ).isWritten {
            explorationLauncher.open(node, course: course, store: store, appModel: appModel, appState: appState)
            return false
        }
        // A new passage starts clean; only its own Write It can show an error.
        explorationLauncher.error = nil
        return true
    }

    /// What starts at a tapped passage. Built on every update, so a page that
    /// finishes while this is open turns into a row that opens it.
    private func passageThreads(
        for hit: NativeBlockEditorAnnotationHit,
        perform: @escaping (CoursePassageAction) -> Void
    ) -> AnyView {
        let nodeIDs = Set(hit.annotations.compactMap(CourseSelectionAnchorResolver.branchNodeID(of:)))
        let progress = store.explorationProgress(for: course)
        let explorations = explorationsFromHere.filter { nodeIDs.contains($0.id) }.map { node in
            CoursePassageThreadsList.Exploration(
                node: node,
                state: store.explorationState(of: node, courseID: course.id, progress: progress),
                label: explorationLabel(node)
            )
        }
        let discussions = hit.annotations
            .filter { CourseSelectionAnchorResolver.branchNodeID(of: $0) == nil }
            .compactMap { UUID(uuidString: $0.id).flatMap(store.selectionDiscussion(id:)) }
            .filter { $0.status == .unresolved }
        // Exploring again starts from the most specific explored passage here.
        let explored = hit.annotations.filter { $0.style.isBranch }
        let passage = NativeBlockEditorAnnotationComposer.primary(of: explored) ?? hit.primary
        let selection = hit.selection(for: passage)
        return AnyView(CoursePassageThreadsList(
            explorations: explorations,
            discussions: discussions,
            error: explorationLauncher.error,
            onOpenExploration: { perform(.openExploration($0)) },
            onWrite: { node in
                explorationLauncher.open(node, course: course, store: store, appModel: appModel, appState: appState)
            },
            onOpenDiscussion: { perform(.openDiscussion($0)) },
            onExploreAgain: { perform(.exploreAgain(selection)) },
            onAsk: discussions.isEmpty ? { perform(.ask(selection)) } : nil
        ))
    }

    private func performPassageAction(_ action: CoursePassageAction) {
        switch action {
        case .openExploration(let node):
            explorationLauncher.open(node, course: course, store: store, appModel: appModel, appState: appState)
        case .openDiscussion(let discussion):
            presentSelectionDiscussion(discussion)
        case .exploreAgain, .ask:
            // The canvas owns the Explore prompt and the selection actions.
            break
        }
    }

    /// Explorations that already start on a selected passage, so the Explore
    /// prompt can say so before the learner forks the same idea twice.
    private func explorationOverlap(
        with selection: NativeBlockEditorSelection,
        in model: CoursePageEditorModel
    ) -> CourseExplorationOverlap {
        let overlapping = textAnnotations(in: model).filter { annotation in
            guard annotation.style.isBranch else { return false }
            let sameBlock = annotation.blockID != nil && selection.blockID != nil
                ? annotation.blockID == selection.blockID
                : annotation.path == selection.path
            return sameBlock && NSIntersectionRange(annotation.range, selection.range).length > 0
        }
        let nodeIDs = Set(overlapping.compactMap(CourseSelectionAnchorResolver.branchNodeID(of:)))
        let nodes = explorationsFromHere.filter { nodeIDs.contains($0.id) }
        let progress = store.explorationProgress(for: course)
        return CourseExplorationOverlap(
            titles: nodes.map { node in
                store.explorationState(of: node, courseID: course.id, progress: progress).isWritten
                    ? node.title : explorationLabel(node)
            },
            usedIntents: Set(CourseExplorePassageIntent.allCases.filter { intent in
                nodes.contains { $0.originQuestion?.hasPrefix(intent.question) == true }
            })
        )
    }

    private func returnToForkParent(_ parent: CourseLearningNode) {
        guard let parentPageID = parent.pageID else { return }
        let parentRoute = CourseRoute.coursePage(courseID: course.id, pageID: parentPageID)
        let path = store.navigationPath
        if path.count >= 2, path[path.count - 2] == parentRoute {
            store.navigationPath.removeLast()
        } else {
            store.openReadingPage(courseID: course.id, pageID: parentPageID, replacingCurrentPage: true)
        }
    }

    private func loadPage(requestID: CoursePageEditorLoadID) async {
        guard CoursePageEditorLoadPolicy.acceptsCompletion(
            requestID: requestID,
            currentID: loadID,
            taskIsCancelled: Task.isCancelled
        ) else { return }
        model = nil
        loadingError = nil
        assessmentAttempts = nil
        assessmentStorageError = nil
        do {
            let repository = try await store.documentRepository(for: course)
            guard CoursePageEditorLoadPolicy.acceptsCompletion(
                requestID: requestID,
                currentID: loadID,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            let editorModel = CoursePageEditorModel(
                pageID: requestID.pageID,
                repository: repository
            )
            await editorModel.load()
            guard CoursePageEditorLoadPolicy.acceptsCompletion(
                requestID: requestID,
                currentID: loadID,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            if let error = editorModel.errorMessage {
                loadingError = error
            } else {
                let outline = try await repository.outline()
                guard !Task.isCancelled, requestID == loadID else { return }
                readingNodes = outline.learningPages
                let bookmark = store.readingBookmark(for: course)
                let isReadable = CourseReadingOrder.readablePages(in: outline.learningPages)
                    .contains { $0.pageID == pageID }
                if isReadable {
                    store.recordReading(pageID: pageID, isAtEnd: false, for: course)
                    let saved: CourseReadingBookmark
                    if let bookmark, bookmark.pageID == pageID {
                        saved = bookmark
                    } else {
                        saved = CourseReadingBookmark(pageID: pageID, offset: 0, isAtEnd: false)
                    }
                    initialReadingPosition = NativeBlockEditorReadingPosition(offset: saved.offset, isAtEnd: saved.isAtEnd)
                    store.saveReadingBookmark(saved, for: course)
                } else {
                    initialReadingPosition = nil
                }
                latestReadingViewport.position = initialReadingPosition
                do {
                    assessmentAttempts = try store.assessmentAttemptStore(for: course, pageID: requestID.pageID)
                } catch {
                    assessmentStorageError = error.localizedDescription
                }
                model = editorModel
            }
        } catch {
            guard CoursePageEditorLoadPolicy.acceptsCompletion(
                requestID: requestID,
                currentID: loadID,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            loadingError = error.localizedDescription
        }
    }

    private func askAboutSelection(
        _ selection: NativeBlockEditorSelection,
        model: CoursePageEditorModel
    ) -> CourseTextReference? {
        guard let reference = CourseSelectionAnchorResolver.reference(
            courseID: course.id,
            pageID: pageID,
            pageTitle: model.title,
            selection: selection,
            document: model.document
        ) else {
#if DEBUG
            recordLF51SelectionCallback(
                selection,
                resolvedReference: nil,
                result: "anchor-unresolved"
            )
#endif
            chatError = "That selection could not be attached to this page. Select the passage again."
            return nil
        }
        let callbackResult: String
        do {
            switch try store.beginSelectionDiscussion(for: course, reference: reference) {
            case .open(let discussion):
                presentSelectionDiscussion(discussion)
                callbackResult = "discussion-opened"
            case .targetConflict(let existing, let selected):
                discussionConflict = CourseSelectionDiscussionConflict(
                    existing: existing,
                    reference: reference,
                    selectedTarget: selected
                )
                callbackResult = "target-conflict"
            }
        } catch {
            chatError = error.localizedDescription
            callbackResult = "discussion-error"
        }
#if DEBUG
        recordLF51SelectionCallback(
            selection,
            resolvedReference: reference,
            result: callbackResult
        )
#endif
        return reference
    }

    private func replaceConflictingDiscussion() {
        guard let conflict = discussionConflict else { return }
        discussionConflict = nil
        Task {
            do {
                let replacement = try await store.replaceSelectionDiscussion(
                    existingID: conflict.existing.id,
                    reference: conflict.reference,
                    selectedTarget: conflict.selectedTarget,
                    appModel: appModel
                )
                presentSelectionDiscussion(replacement)
            } catch {
                chatError = error.localizedDescription
            }
        }
    }

    private func textAnnotations(
        in model: CoursePageEditorModel
    ) -> [NativeBlockEditorTextAnnotation] {
        let discussions = store.unresolvedSelectionDiscussions(courseID: course.id, pageID: pageID)
            .compactMap {
                CourseSelectionAnchorResolver.annotation(
                    for: $0,
                    document: model.document
                )
            }
        // Where each exploration forked from a passage on this page, inked by
        // its state: dashed until written, filled until first opened.
        let progress = store.explorationProgress(for: course)
        let branches = explorationsFromHere.compactMap { node -> NativeBlockEditorTextAnnotation? in
            guard let anchor = node.originAnchor else { return nil }
            let style: NativeBlockEditorTextAnnotation.Style =
                switch store.explorationState(of: node, courseID: course.id, progress: progress) {
                case .written(let isNew, _): isNew ? .branchNew : .branch
                case .queued, .writing, .failed, .unwritten: .branchPending
                }
            return CourseSelectionAnchorResolver.branchAnnotation(
                nodeID: node.id,
                anchor: anchor,
                style: style,
                document: model.document
            )
        }
        return branches + discussions
    }

    @discardableResult
    private func openDiscussion(annotation: NativeBlockEditorTextAnnotation) -> Bool {
        guard let id = UUID(uuidString: annotation.id),
              let discussion = store.selectionDiscussion(id: id),
              discussion.status == .unresolved else {
#if DEBUG
            recordLF51AnnotationCallback(
                annotation,
                wasOpened: false,
                result: "discussion-unavailable"
            )
#endif
            return false
        }
        presentSelectionDiscussion(discussion)
#if DEBUG
        recordLF51AnnotationCallback(
            annotation,
            wasOpened: true,
            result: "discussion-opened"
        )
#endif
        return true
    }

#if DEBUG
    @ViewBuilder
    private var runtimeProbeOverlay: some View {
        if let configuration = CourseEditorRuntimeProbeConfiguration.current(),
           let model,
           !model.isLoading {
            let annotationProvenances = lf51AnnotationProvenances(
                in: model,
                configuration: configuration
            )
            let lf51Value = lf51RuntimeProbeState.accessibilityValue(
                annotationProvenances: annotationProvenances
            )
            ZStack(alignment: .topLeading) {
                CourseEditorRuntimeProbeMarker(
                    identifier: "lf-50-runtime-probe",
                    label: "LF-50 editor persistence runtime probe",
                    value: CourseEditorLF50RuntimeProbeSnapshot(
                        model: model,
                        configuration: configuration
                    ).accessibilityValue
                )
                if model.saveState.canRetry {
                    CourseEditorRuntimeProbeMarker(
                        identifier: "lf-50-fault-hook",
                        label: "LF-50 failed-save product hook",
                        value: "save-state=failed"
                    )
                }
                if !lf51Value.isEmpty {
                    CourseEditorRuntimeProbeMarker(
                        identifier: "lf-51-runtime-probe",
                        label: "LF-51 selection and annotation runtime probe",
                        value: lf51Value
                    )
                }
                if let hookValue = lf51RuntimeProbeState.hookAccessibilityValue {
                    CourseEditorRuntimeProbeMarker(
                        identifier: "lf-51-runtime-probe-hook",
                        label: "LF-51 native editor callback receipt",
                        value: hookValue
                    )
                }
            }
            .frame(width: 1, height: 1, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private func lf51AnnotationProvenances(
        in model: CoursePageEditorModel,
        configuration: CourseEditorRuntimeProbeConfiguration
    ) -> [CourseEditorLF51AnnotationStoreProvenance] {
        store.unresolvedSelectionDiscussions(courseID: course.id, pageID: pageID)
            .compactMap { discussion in
                guard let annotation = CourseSelectionAnchorResolver.annotation(
                    for: discussion,
                    document: model.document
                ) else { return nil }
                return CourseEditorLF51AnnotationStoreProvenance(
                    discussion: discussion,
                    annotation: annotation,
                    configuration: configuration
                )
            }
    }

    private func recordLF51SelectionCallback(
        _ selection: NativeBlockEditorSelection,
        resolvedReference: CourseTextReference?,
        result: String
    ) {
        guard let configuration = CourseEditorRuntimeProbeConfiguration.current() else { return }
        var updated = lf51RuntimeProbeState
        updated.recordSelection(
            selection,
            resolvedReference: resolvedReference,
            callbackResult: result,
            configuration: configuration
        )
        lf51RuntimeProbeState = updated
    }

    private func recordLF51AnnotationCallback(
        _ annotation: NativeBlockEditorTextAnnotation,
        wasOpened: Bool,
        result: String
    ) {
        guard CourseEditorRuntimeProbeConfiguration.current() != nil else { return }
        var updated = lf51RuntimeProbeState
        updated.recordOpenedAnnotation(
            annotation,
            wasOpened: wasOpened,
            callbackResult: result
        )
        lf51RuntimeProbeState = updated
    }
#endif
}

struct CoursePageEditorLoadID: Hashable {
    let courseID: String
    let workspaceID: String?
    let pageID: String
    let reloadGeneration: Int
}

enum CoursePageEditorLoadPolicy {
    static func acceptsCompletion(
        requestID: CoursePageEditorLoadID,
        currentID: CoursePageEditorLoadID,
        taskIsCancelled: Bool
    ) -> Bool {
        !taskIsCancelled && requestID == currentID
    }
}

struct CoursePageLoadFailureView: View {
    let pageID: String
    let error: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                "Couldn’t open this page",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(error)
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("course-page-retry-\(pageID)")
        }
        // This is a structural failure-state marker, not the retry control.
        // Containment preserves it in the AX tree without assigning its
        // identifier to the actionable child button.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-page-load-error-\(pageID)")
    }
}

#if DEBUG
enum CourseEditorCheckpointUITestScenario: String, CaseIterable, Hashable {
    case lf45Loading = "--checkpoint-lf45-loading"
    case lf45Loaded = "--checkpoint-lf45-loaded"
    case lf45Error = "--checkpoint-lf45-error"
    case lf47FileLoaded = "--checkpoint-lf47-file-loaded"
    case lf47FileFallback = "--checkpoint-lf47-file-fallback"
    case lf48Opening = "--checkpoint-lf48-opening"
    case lf48Editable = "--checkpoint-lf48-editable"
    case lf48LoadError = "--checkpoint-lf48-load-error"
    case lf49Formatting = "--checkpoint-lf49-formatting"
    case lf49DocumentToolbar = "--checkpoint-lf49-document-toolbar"
    case lf49Reordered = "--checkpoint-lf49-reordered"
    case lf49LinkedPage = "--checkpoint-lf49-linked-page"
    case lf50Modified = "--checkpoint-lf50-modified"
    case lf50ReopenedPersisted = "--checkpoint-lf50-reopened-persisted"
    case lf50ErrorOverlay = "--checkpoint-lf50-error-overlay"
    case lf51Selection = "--checkpoint-lf51-selection"
    case lf51Annotation = "--checkpoint-lf51-annotation"
    case lf51ReopenedAnnotation = "--checkpoint-lf51-reopened-annotation"

    var requiresFixture: Bool {
        fixtureDependency != .none
    }

    var requiresCourseExperienceStore: Bool {
        false
    }

    var fixtureDependency: CourseEditorCheckpointFixtureDependency {
        switch self {
        case .lf45Loading, .lf48Opening:
            .none
        case .lf45Loaded, .lf45Error, .lf47FileLoaded, .lf47FileFallback:
            .workspaceFiles
        case .lf50ReopenedPersisted:
            .persistedDocumentRepository
        case .lf48Editable, .lf48LoadError,
             .lf49Formatting, .lf49DocumentToolbar, .lf49Reordered, .lf49LinkedPage,
             .lf50Modified, .lf50ErrorOverlay,
             .lf51Selection, .lf51Annotation, .lf51ReopenedAnnotation:
            .documentRepository
        }
    }

    var strictEvidence: CourseEditorCheckpointStrictEvidence? {
        switch self {
        case .lf50ErrorOverlay:
            CourseEditorCheckpointStrictEvidence(
                checkpointID: "LF-50",
                substate: "error-overlay",
                hookIdentifier: "lf-50-fault-hook",
                runtimeProbeIdentifier: "lf-50-runtime-probe"
            )
        default:
            nil
        }
    }
}

enum CourseEditorCheckpointFixtureDependency: String, Equatable {
    case none
    case workspaceFiles = "workspace-files"
    case documentRepository = "document-repository"
    case persistedDocumentRepository = "persisted-document-repository"
}

struct CourseEditorCheckpointStrictEvidence: Equatable {
    let checkpointID: String
    let substate: String
    let hookIdentifier: String
    let runtimeProbeIdentifier: String
}

struct CourseEditorCheckpointUITestConfiguration: Equatable {
    let scenario: CourseEditorCheckpointUITestScenario
    let runToken: String
}

enum CourseEditorCheckpointUITestConfigurationError: Error, Equatable, LocalizedError {
    case missingBaseFlag
    case duplicateBaseFlag
    case missingScenario
    case multipleScenarios([CourseEditorCheckpointUITestScenario])
    case missingRunToken
    case duplicateRunToken
    case invalidRunToken(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseFlag:
            "A checkpoint scenario was supplied without --ui-test-course-editor-checkpoints."
        case .duplicateBaseFlag:
            "--ui-test-course-editor-checkpoints must appear exactly once."
        case .missingScenario:
            "Exactly one recognized course-editor checkpoint scenario is required."
        case let .multipleScenarios(scenarios):
            "Exactly one course-editor checkpoint scenario is required; received \(scenarios.map(\.rawValue).joined(separator: ", "))."
        case .missingRunToken:
            "A canonical UUID must follow --checkpoint-run-token."
        case .duplicateRunToken:
            "--checkpoint-run-token must appear exactly once."
        case let .invalidRunToken(token):
            "The checkpoint run token is not a canonical UUID: \(token)"
        }
    }

    var accessibilityValue: String {
        switch self {
        case .missingBaseFlag: "missing-base-flag"
        case .duplicateBaseFlag: "duplicate-base-flag"
        case .missingScenario: "missing-scenario"
        case .multipleScenarios: "multiple-scenarios"
        case .missingRunToken: "missing-run-token"
        case .duplicateRunToken: "duplicate-run-token"
        case .invalidRunToken: "invalid-run-token"
        }
    }
}

enum CourseEditorCheckpointUITestConfigurationParseResult: Equatable {
    case valid(CourseEditorCheckpointUITestConfiguration)
    case invalid(CourseEditorCheckpointUITestConfigurationError)
}

enum CourseEditorCheckpointUITestConfigurationParser {
    static let baseFlag = "--ui-test-course-editor-checkpoints"
    static let runTokenFlag = "--checkpoint-run-token"

    static func wasRequested(arguments: [String]) -> Bool {
        arguments.contains(baseFlag)
            || arguments.contains(where: { CourseEditorCheckpointUITestScenario(rawValue: $0) != nil })
    }

    static func parse(
        arguments: [String]
    ) -> CourseEditorCheckpointUITestConfigurationParseResult {
        let baseFlagCount = arguments.filter { $0 == baseFlag }.count
        guard baseFlagCount > 0 else { return .invalid(.missingBaseFlag) }
        guard baseFlagCount == 1 else { return .invalid(.duplicateBaseFlag) }

        let scenarios = arguments.compactMap(CourseEditorCheckpointUITestScenario.init(rawValue:))
        guard !scenarios.isEmpty else { return .invalid(.missingScenario) }
        guard scenarios.count == 1, let scenario = scenarios.first else {
            return .invalid(.multipleScenarios(scenarios))
        }

        let tokenFlagIndices = arguments.indices.filter { arguments[$0] == runTokenFlag }
        guard !tokenFlagIndices.isEmpty else { return .invalid(.missingRunToken) }
        guard tokenFlagIndices.count == 1, let tokenFlagIndex = tokenFlagIndices.first else {
            return .invalid(.duplicateRunToken)
        }
        let tokenIndex = arguments.index(after: tokenFlagIndex)
        guard tokenIndex < arguments.endIndex else { return .invalid(.missingRunToken) }
        let suppliedToken = arguments[tokenIndex]
        guard let uuid = UUID(uuidString: suppliedToken) else {
            return .invalid(.invalidRunToken(suppliedToken))
        }
        let canonicalToken = uuid.uuidString.lowercased()
        guard suppliedToken.lowercased() == canonicalToken else {
            return .invalid(.invalidRunToken(suppliedToken))
        }
        return .valid(CourseEditorCheckpointUITestConfiguration(
            scenario: scenario,
            runToken: canonicalToken
        ))
    }
}

private enum CourseEditorCheckpointFixtureLocationError: LocalizedError {
    case unsafeTemporaryRoot

    var errorDescription: String? {
        "The deterministic checkpoint root did not resolve to the exact per-run temporary directory."
    }
}

private struct CourseEditorCheckpointFixtureLocations {
    static let baseDirectoryName = "LearnfoldCourseEditorCheckpointUITest"

    let runToken: String
    let workspaceID: String

    var fixtureBaseURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            Self.baseDirectoryName,
            isDirectory: true
        )
    }

    var fixtureRootURL: URL {
        fixtureBaseURL.appendingPathComponent(runToken, isDirectory: true)
    }

    var coursesRootURL: URL {
        fixtureRootURL.appendingPathComponent("Courses", isDirectory: true)
    }

    var workspaceRootURL: URL {
        coursesRootURL.appendingPathComponent(
            workspaceID,
            isDirectory: true
        )
    }

    var databaseURL: URL {
        workspaceRootURL
            .appendingPathComponent(".course", isDirectory: true)
            .appendingPathComponent("course-library.sqlite")
    }

    var receiptURL: URL {
        fixtureRootURL.appendingPathComponent("lf50-persistence-receipt.json")
    }

    var pendingEditsURL: URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent("pending-user-edits.json")
    }

    var defaultsSuiteName: String {
        "com.chirag.learnfold.course-editor-checkpoints.\(runToken)"
    }

    func removeFixtureRoot() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedBase = fixtureBaseURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedRoot = fixtureRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedBase.deletingLastPathComponent().path == temporaryRoot.path,
              resolvedBase.lastPathComponent == Self.baseDirectoryName,
              resolvedRoot.deletingLastPathComponent().path == resolvedBase.path,
              resolvedRoot.lastPathComponent == runToken else {
            throw CourseEditorCheckpointFixtureLocationError.unsafeTemporaryRoot
        }
        if FileManager.default.fileExists(atPath: resolvedRoot.path) {
            try FileManager.default.removeItem(at: resolvedRoot)
        }
    }
}

private struct CourseEditorCheckpointPersistenceReceipt: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let runToken: String
    let databaseByteCount: Int
    let databaseSHA256: String
    let pageID: String
    let documentSHA256: String
    let documentOrder: String

    var accessibilityValue: String {
        [
            "version=\(version)",
            "token=\(runToken)",
            "bytes=\(databaseByteCount)",
            "database=\(databaseSHA256)",
            "page=\(pageID)",
            "document=\(documentSHA256)",
            "order=\(documentOrder)",
        ].joined(separator: ";")
    }
}

private struct CourseEditorLF50RuntimeProbeReceipt: Equatable {
    enum Phase: String {
        case errorOverlay = "error-overlay"
        case savedAfterRetry = "saved-after-retry"
    }

    let probeID: String
    let hookID: String
    let runToken: String
    let phase: Phase
    let transition: String
    let draftRetained: Bool
    let pendingJournalExists: Bool
    let persistedMatchesDraft: Bool
    let revision: Int64
    let databaseByteCount: Int
    let databaseSHA256: String
    let draftSHA256: String
    let persistedSHA256: String

    var accessibilityValue: String {
        [
            "probe=\(probeID)",
            "hook=\(hookID)",
            "token=\(runToken)",
            "phase=\(phase.rawValue)",
            "transition=\(transition)",
            "draft-retained=\(draftRetained)",
            "pending-journal=\(pendingJournalExists)",
            "persisted-matches-draft=\(persistedMatchesDraft)",
            "revision=\(revision)",
            "bytes=\(databaseByteCount)",
            "database=\(databaseSHA256)",
            "draft=\(draftSHA256)",
            "persisted=\(persistedSHA256)",
        ].joined(separator: ";")
    }
}

struct CourseRetryUITestHarnessView: View {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-retry")
            || isSaveRecoveryEnabled
            || isEditorCheckpointEnabled
    }

    private static var isSaveRecoveryEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-course-save-recovery")
    }

    private static var isEditorCheckpointEnabled: Bool {
        CourseEditorCheckpointUITestConfigurationParser.wasRequested(
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    private let pageID = "retry-page"

    @State private var structureError: String?
    @State private var structureIsLoading = true
    @State private var workspaceStatus = "Source files unavailable"
    @State private var documentStatus = "Course pages unavailable"
    @State private var workspaceAttempts = 0
    @State private var documentAttempts = 0

    @State private var editorError: String?
    @State private var editorContent: String?
    @State private var editorReloadGeneration = 0
    @State private var editorAttempts = 0
    @State private var rejectedStaleEditorCompletion = false
    @State private var staleEditorTask: Task<Void, Never>?

    private var editorLoadID: CoursePageEditorLoadID {
        CoursePageEditorLoadID(
            courseID: "retry-course",
            workspaceID: "retry-workspace",
            pageID: pageID,
            reloadGeneration: editorReloadGeneration
        )
    }

    var body: some View {
        if Self.isEditorCheckpointEnabled {
            CourseEditorCheckpointUITestHarnessView()
        } else if Self.isSaveRecoveryEnabled {
            CoursePageSaveRecoveryUITestHarnessView()
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Course Retry Test")
                            .font(.headline)
                            .accessibilityIdentifier("courseRetryHarness.title")

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Structure retry")
                                .font(.title2.bold())

                            Text("\(workspaceAttempts)")
                                .accessibilityIdentifier("courseRetryHarness.workspaceAttempts")
                            Text("\(documentAttempts)")
                                .accessibilityIdentifier("courseRetryHarness.documentAttempts")

                            if structureIsLoading {
                                ProgressView("Reading course structure…")
                            } else if let structureError {
                                CourseStructureLoadFailureView(error: structureError) {
                                    self.structureError = nil
                                    structureIsLoading = true
                                    Task { await runStructureLoad(shouldSucceed: true) }
                                }
                            } else {
                                Text(workspaceStatus)
                                    .accessibilityIdentifier("courseRetryHarness.workspaceStatus")
                                Text(documentStatus)
                                    .accessibilityIdentifier("courseRetryHarness.documentStatus")
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Same-page editor retry")
                                .font(.title2.bold())

                            Text("\(editorAttempts)")
                                .accessibilityIdentifier("courseRetryHarness.editorAttempts")
                            Text(rejectedStaleEditorCompletion ? "yes" : "no")
                                .accessibilityIdentifier("courseRetryHarness.staleCompletionRejected")

                            if let editorContent {
                                Text(editorContent)
                                    .accessibilityIdentifier("courseRetryHarness.editorContent")
                            } else if let editorError {
                                CoursePageLoadFailureView(pageID: pageID, error: editorError) {
                                    retryEditorLoad()
                                }
                            } else {
                                ProgressView("Opening course page…")
                            }
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("Retry")
            }
            .task {
                await runStructureLoad(shouldSucceed: false)
                beginInitialEditorLoad()
                (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
            }
            .onDisappear {
                staleEditorTask?.cancel()
                staleEditorTask = nil
            }
        }
    }

    @MainActor
    private func runStructureLoad(shouldSucceed: Bool) async {
        let result = await CourseStructureReloadCoordinator.reload(
            loadWorkspaceFiles: {
                workspaceAttempts += 1
                try? await Task.sleep(for: .milliseconds(30))
                return shouldSucceed
                    ? .loaded("Source files ready")
                    : .failed("Simulated source-file failure")
            },
            loadDocumentPages: {
                documentAttempts += 1
                try? await Task.sleep(for: .milliseconds(60))
                return shouldSucceed
                    ? .loaded("Course pages ready")
                    : .failed("Simulated course-page failure")
            }
        )
        guard !Task.isCancelled else { return }
        workspaceStatus = result.workspaceFiles.value ?? "Source files unavailable"
        documentStatus = result.documentPages.value ?? "Course pages unavailable"
        structureError = result.errors.combinedMessage
        structureIsLoading = false
    }

    @MainActor
    private func beginInitialEditorLoad() {
        let requestID = editorLoadID
        editorAttempts += 1
        editorContent = nil
        editorError = "Simulated first-load failure"
        staleEditorTask?.cancel()
        staleEditorTask = Task { @MainActor in
            while !Task.isCancelled, requestID == editorLoadID {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled else { return }
            if CoursePageEditorLoadPolicy.acceptsCompletion(
                requestID: requestID,
                currentID: editorLoadID,
                taskIsCancelled: false
            ) {
                editorContent = "Stale same-page content"
            } else {
                rejectedStaleEditorCompletion = true
            }
        }
    }

    @MainActor
    private func retryEditorLoad() {
        editorContent = nil
        editorError = nil
        editorReloadGeneration &+= 1
        let requestID = editorLoadID
        editorAttempts += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard CoursePageEditorLoadPolicy.acceptsCompletion(
                requestID: requestID,
                currentID: editorLoadID,
                taskIsCancelled: Task.isCancelled
            ) else { return }
            editorContent = "Fresh same-page content"
        }
    }
}

private struct CourseEditorCheckpointFileViewerView: View {
    let course: LearningCourse
    let relativePath: String
    let rootURL: URL
    let onOpenRelativePath: (String) -> Void
    let onOpenCourseStructure: () -> Void
    let onReturnToLibrary: () -> Void

    @State private var loadState: LoadState = .loading
    @State private var fileURL: URL?

    private enum LoadState {
        case loading
        case text(String)
        case image(UIImage)
        case unsupported
        case unavailable
        case failed(String)

        var accessibilityValue: String {
            switch self {
            case .loading: "Opening file"
            case .text: "File loaded as text"
            case .image: "File loaded as image"
            case .unsupported: "Preview unavailable"
            case .unavailable: "File unavailable"
            case .failed: "File preview failed"
            }
        }
    }

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView("Opening file…")
            case .text(let text):
                if isMarkdown {
                    ScrollView {
                        Text(text)
                            .accessibilityIdentifier("course-file-viewer-text")
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 22)
                            .padding(.bottom, 44)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .accessibilityIdentifier("course-file-viewer-text")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                    }
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                }
            case .unsupported:
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "doc",
                    description: Text("You can share this file or open it in another app.")
                )
            case .unavailable:
                CourseRouteUnavailableView(
                    kind: .file,
                    courseTitle: course.title,
                    canOpenCourseStructure: course.workspaceID != nil,
                    onOpenCourseStructure: onOpenCourseStructure,
                    onReturnToLibrary: onReturnToLibrary
                )
            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t preview file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(URL(fileURLWithPath: relativePath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: fileURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share course file")
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.isFileURL,
                  let path = CourseWorkspaceSnapshot.relativePath(for: url, rootURL: rootURL) else {
                return .systemAction
            }
            onOpenRelativePath(path)
            return .handled
        })
        .task(id: relativePath) {
            loadFile()
        }
        .overlay(alignment: .topLeading) {
            CourseEditorRuntimeProbeMarker(
                identifier: "course-file-viewer",
                label: "Course file viewer",
                value: loadState.accessibilityValue
            )
            .allowsHitTesting(false)
        }
    }

    private var isMarkdown: Bool {
        ["md", "markdown"].contains(
            URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        )
    }

    private func loadFile() {
        do {
            let resolved = try CourseWorkspaceSnapshot.validatedFileURL(
                relativePath: relativePath,
                rootURL: rootURL
            )
            fileURL = resolved
            switch resolved.pathExtension.lowercased() {
            case "md", "markdown", "json", "txt", "csv", "yaml", "yml", "toml", "xml",
                 "swift", "py", "js", "ts", "tsx", "jsx", "rs", "kt", "java", "c", "h",
                 "cpp", "sh", "rb":
                loadState = .text(try CourseWorkspaceSnapshot.readText(
                    relativePath: relativePath,
                    rootURL: rootURL
                ))
            case "png", "jpg", "jpeg", "gif", "webp", "heic":
                let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
                guard data.count <= 20_000_000, let image = UIImage(data: data) else {
                    throw CourseWorkspaceError.fileTooLarge
                }
                loadState = .image(image)
            default:
                loadState = .unsupported
            }
        } catch {
            loadState = CourseRouteFallbackPolicy.fileIsUnavailable(after: error)
                ? .unavailable
                : .failed(error.localizedDescription)
        }
    }
}

private struct CoursePageSaveRecoveryUITestHarnessView: View {
    @State private var model: CoursePageEditorModel?
    @State private var setupError: String?
    @State private var temporaryDirectory: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    CoursePageEditorCanvas(
                        model: model,
                        textAnnotations: [],
                        onAskAboutSelection: { _ in nil },
                        onOpenTextAnnotation: { _ in false },
                        onOpenPage: { _ in }
                    )
                } else if let setupError {
                    ContentUnavailableView(
                        "Couldn’t prepare save recovery",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError)
                    )
                } else {
                    ProgressView("Preparing failed save…")
                }
            }
            .navigationTitle("")
        }
        .accessibilityIdentifier("courseSaveRecoveryHarness.title")
        .task {
            await prepareFailedSave()
        }
        .onDisappear {
            if let temporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
            temporaryDirectory = nil
        }
    }

    @MainActor
    private func prepareFailedSave() async {
        guard model == nil, setupError == nil else { return }
        defer {
            (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
        }

        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CoursePageSaveRecoveryUI-\(UUID().uuidString)",
                isDirectory: true
            )
            temporaryDirectory = directory
            let repository = try await CourseDocumentRepository.open(
                workspaceID: "ui-save-recovery-\(UUID().uuidString.lowercased())",
                databaseURL: directory.appendingPathComponent(".course/course-library.sqlite"),
                rootTitle: "Save recovery evidence",
                autosaveDelay: .seconds(60)
            )
            let root = try await repository.rootPageSnapshot()
            let editorModel = CoursePageEditorModel(pageID: root.id, repository: repository)
            await editorModel.load()

            var draft = editorModel.document
            draft.root.children.append(.paragraph("First pending recovery edit"))
            draft.root.children.append(.paragraph("Second pending recovery edit"))
            draft.ensureStableBlockIDs()
            await repository.debugFailNextFlushes()
            editorModel.userChangedDocument(draft)
            await editorModel.flush()
            model = editorModel
        } catch {
            setupError = error.localizedDescription
        }
    }
}

struct CourseEditorCheckpointUITestHarnessView: View {
    private let parseResult: CourseEditorCheckpointUITestConfigurationParseResult

    init(configuration: CourseEditorCheckpointUITestConfiguration) {
        parseResult = .valid(configuration)
    }

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        parseResult = CourseEditorCheckpointUITestConfigurationParser.parse(arguments: arguments)
    }

    @ViewBuilder
    var body: some View {
        switch parseResult {
        case let .valid(configuration):
            CourseEditorCheckpointUITestValidHarnessView(configuration: configuration)
        case let .invalid(error):
            NavigationStack {
                VStack(spacing: 20) {
                    Text("Checkpoint configuration error")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("course-checkpoint-configuration-error")
                        .accessibilityLabel("Course editor checkpoint configuration error")
                        .accessibilityValue(error.accessibilityValue)

                    ContentUnavailableView(
                        "Invalid checkpoint configuration",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                }
                .padding(20)
                .navigationTitle("Checkpoint configuration")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LearnfoldStrictHarnessSentinelBanner(presentation: .courseEditor)
            }
            .task {
                (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
            }
        }
    }
}

private struct CourseEditorCheckpointUITestValidHarnessView: View {
    private enum Presentation {
        case initial
        case lf45Recovered
        case lf47BackToStructure
        case lf48Recovered
        case selectedFile
        case linkedPageOpening
        case linkedPage
        case lf50PersistedForRelaunch
        case awaitingAnnotationReopen
        case reopenedAnnotation
    }

    private enum FixtureError: LocalizedError {
        case editorLoad(String)
        case unexpectedPage(String)
        case unexpectedDocumentOrder(expected: String, actual: String)
        case persistedDocumentMismatch
        case missingPersistenceReceipt
        case invalidPersistenceReceipt(String)
        case databaseFingerprintMismatch
        case documentFingerprintMismatch
        case lf50ExpectedFailedSave(String)
        case lf50DraftNotRetained
        case lf50UnexpectedPersistence(phase: String)
        case lf50RetryDidNotExposeSaving
        case lf50RetryDidNotSave(String)
        case selectionResolution
        case annotationResolution

        var errorDescription: String? {
            switch self {
            case let .editorLoad(message):
                "The deterministic editor fixture did not load: \(message)"
            case let .unexpectedPage(pageID):
                "The deterministic page \(pageID) was not available."
            case let .unexpectedDocumentOrder(expected, actual):
                "Expected document order \(expected), received \(actual)."
            case .persistedDocumentMismatch:
                "The checkpointed SQLite workspace did not exactly match the flushed editor document."
            case .missingPersistenceReceipt:
                "The first LF-50 process did not leave its persistence receipt for this run token."
            case let .invalidPersistenceReceipt(message):
                "The LF-50 persistence receipt was invalid: \(message)"
            case .databaseFingerprintMismatch:
                "The LF-50 database bytes changed between process termination and the fresh reopen."
            case .documentFingerprintMismatch:
                "The LF-50 document content changed between the flushed process and the fresh reopen."
            case let .lf50ExpectedFailedSave(actual):
                "The LF-50 fault hook did not present the failed-save overlay; received \(actual)."
            case .lf50DraftNotRetained:
                "The LF-50 failed-save overlay did not retain the exact pending learner draft."
            case let .lf50UnexpectedPersistence(phase):
                "The LF-50 runtime persistence probe rejected the \(phase) state."
            case .lf50RetryDidNotExposeSaving:
                "The LF-50 retry did not transition through the saving state."
            case let .lf50RetryDidNotSave(actual):
                "The LF-50 retry did not reach the saved state; received \(actual)."
            case .selectionResolution:
                "The deterministic selection could not be resolved through the production anchor resolver."
            case .annotationResolution:
                "The deterministic annotation could not be projected onto the reopened document."
            }
        }
    }

    private static let courseID = "checkpoint-course"
    private static let workspaceID = "checkpoint-workspace"
    private static let rootPageID = "checkpoint-root-page"
    private static let editorPageID = "checkpoint-editor-page"
    private static let linkedPageID = "checkpoint-linked-page"
    private static let selectionBlockID = "checkpoint-selection-block"
    private static let annotationID = "checkpoint-annotation"
    private static let selectionText = "Selection anchor"
    private static let fieldGuidePath = "sources/field-guide.md"
    private static let unavailablePath = "sources/removed-field-guide.md"

    let configuration: CourseEditorCheckpointUITestConfiguration

    private var scenario: CourseEditorCheckpointUITestScenario {
        configuration.scenario
    }

    private var locations: CourseEditorCheckpointFixtureLocations {
        CourseEditorCheckpointFixtureLocations(
            runToken: configuration.runToken,
            workspaceID: Self.workspaceID
        )
    }

    @State private var presentation: Presentation = .initial
    @State private var snapshot: CourseWorkspaceSnapshot?
    @State private var repository: CourseDocumentRepository?
    @State private var model: CoursePageEditorModel?
    @State private var setupError: String?
    @State private var preparationStarted = false
    @State private var isPrepared = false
    @State private var selectedRelativePath = Self.fieldGuidePath
    @State private var selectionReferenceValue: String?
    @State private var annotationWasOpened = false
    @State private var transitionInFlight = false
    @State private var persistenceReceipt: CourseEditorCheckpointPersistenceReceipt?
    @State private var lf50RuntimeProbeReceipt: CourseEditorLF50RuntimeProbeReceipt?

    var body: some View {
        NavigationStack {
            checkpointBody
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LearnfoldStrictHarnessSentinelBanner(presentation: .courseEditor)
        }
        .task {
            if scenario.requiresFixture {
                await prepareFixture()
            } else {
                try? locations.removeFixtureRoot()
                UserDefaults.standard.removePersistentDomain(forName: locations.defaultsSuiteName)
                signalContentReady()
            }
        }
        .onDisappear {
            model = nil
            repository = nil
            let preservesLF50Fixture = scenario == .lf50Modified && persistenceReceipt != nil
            if !preservesLF50Fixture {
                try? locations.removeFixtureRoot()
                UserDefaults.standard.removePersistentDomain(forName: locations.defaultsSuiteName)
            }
        }
    }

    @ViewBuilder
    private var checkpointBody: some View {
        if let setupError {
            ContentUnavailableView(
                "Couldn’t prepare editor checkpoint",
                systemImage: "exclamationmark.triangle",
                description: Text(setupError)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("course-checkpoint-setup-error")
            .accessibilityValue(setupError)
        } else if scenario.requiresFixture, !isPrepared {
            ProgressView("Preparing deterministic course…")
                .accessibilityIdentifier("course-checkpoint-preparing")
        } else {
            switch presentation {
            case .initial:
                initialCheckpoint
            case .lf45Recovered:
                structureScreen(
                    markerID: "course-checkpoint-lf45-loaded",
                    markerLabel: "LF-45 structure recovered"
                )
            case .lf47BackToStructure:
                structureScreen(
                    markerID: "course-checkpoint-lf47-back-to-structure",
                    markerLabel: "LF-47 returned to structure"
                )
            case .lf48Recovered:
                editorScreen(
                    markerID: "course-checkpoint-lf48-editable",
                    markerLabel: "LF-48 editable page recovered"
                )
            case .selectedFile:
                fileScreen(
                    relativePath: selectedRelativePath,
                    markerID: "course-checkpoint-lf47-file-loaded",
                    markerLabel: "LF-47 loaded file"
                )
            case .linkedPageOpening:
                pageOpeningScreen(
                    pageID: Self.linkedPageID,
                    markerID: "course-checkpoint-lf49-linked-page-opening",
                    markerLabel: "LF-49 opening linked page"
                )
            case .linkedPage:
                editorScreen(
                    markerID: "course-checkpoint-lf49-linked-page",
                    markerLabel: "LF-49 linked page opened"
                )
            case .lf50PersistedForRelaunch:
                lf50PersistedForRelaunchScreen
            case .awaitingAnnotationReopen:
                reopenPrompt(
                    markerID: "course-checkpoint-lf51-left-annotation",
                    markerLabel: "LF-51 annotation page left",
                    buttonTitle: "Reopen annotation",
                    buttonID: "course-checkpoint-lf51-reopen-annotation",
                    action: reopenAnnotatedPage
                )
            case .reopenedAnnotation:
                editorScreen(
                    markerID: "course-checkpoint-lf51-reopened-annotation",
                    markerLabel: "LF-51 annotation reopened",
                    showsAnnotation: true
                )
            }
        }
    }

    @ViewBuilder
    private var initialCheckpoint: some View {
        switch scenario {
        case .lf45Loading:
            structureLoadingScreen
        case .lf45Loaded:
            structureScreen(
                markerID: "course-checkpoint-lf45-loaded",
                markerLabel: "LF-45 structure loaded"
            )
        case .lf45Error:
            structureErrorScreen
        case .lf47FileLoaded:
            fileScreen(
                relativePath: Self.fieldGuidePath,
                markerID: "course-checkpoint-lf47-file-loaded",
                markerLabel: "LF-47 loaded file"
            )
        case .lf47FileFallback:
            fileScreen(
                relativePath: Self.unavailablePath,
                markerID: "course-checkpoint-lf47-file-fallback",
                markerLabel: "LF-47 unavailable file fallback"
            )
        case .lf48Opening:
            pageOpeningScreen(
                pageID: Self.editorPageID,
                markerID: "course-checkpoint-lf48-opening",
                markerLabel: "LF-48 page opening"
            )
        case .lf48Editable:
            editorScreen(
                markerID: "course-checkpoint-lf48-editable",
                markerLabel: "LF-48 editable page"
            )
        case .lf48LoadError:
            pageLoadErrorScreen
        case .lf49Formatting:
            editorScreen(
                markerID: "course-checkpoint-lf49-formatting",
                markerLabel: "LF-49 formatting toolbar"
            )
        case .lf49DocumentToolbar:
            editorScreen(
                markerID: "course-checkpoint-lf49-document-toolbar",
                markerLabel: "LF-49 document toolbar",
                showsDocumentOrder: true
            )
        case .lf49Reordered:
            editorScreen(
                markerID: "course-checkpoint-lf49-reordered",
                markerLabel: "LF-49 reordered document",
                showsDocumentOrder: true
            )
        case .lf49LinkedPage:
            editorScreen(
                markerID: "course-checkpoint-lf49-linked-page",
                markerLabel: "LF-49 linked page opened"
            )
        case .lf50Modified:
            editorScreen(
                markerID: "course-checkpoint-lf50-modified",
                markerLabel: "LF-50 modified before leaving",
                showsDocumentOrder: true,
                primaryAction: (
                    title: "Leave editor",
                    identifier: "course-checkpoint-lf50-leave",
                    action: leaveModifiedPage
                )
            )
        case .lf50ReopenedPersisted:
            editorScreen(
                markerID: "course-checkpoint-lf50-reopened-persisted",
                markerLabel: "LF-50 reopened persisted page",
                markerValue: persistenceReceipt?.accessibilityValue,
                showsDocumentOrder: true
            )
        case .lf50ErrorOverlay:
            editorScreen(
                markerID: "course-checkpoint-lf50-error-overlay",
                markerLabel: "LF-50 error overlay",
                markerValue: "error-overlay",
                showsDocumentOrder: true,
                onRetrySave: retryLF50Save
            )
        case .lf51Selection:
            editorScreen(
                markerID: "course-checkpoint-lf51-selection-ready",
                markerLabel: "LF-51 deterministic selection ready",
                showsSelectionAction: true
            )
        case .lf51Annotation:
            editorScreen(
                markerID: "course-checkpoint-lf51-annotation",
                markerLabel: "LF-51 annotation rendered",
                showsAnnotation: true,
                primaryAction: (
                    title: "Leave annotation page",
                    identifier: "course-checkpoint-lf51-leave-annotation",
                    action: leaveAnnotatedPage
                )
            )
        case .lf51ReopenedAnnotation:
            editorScreen(
                markerID: "course-checkpoint-lf51-reopened-annotation",
                markerLabel: "LF-51 annotation reopened",
                showsAnnotation: true
            )
        }
    }

    private var structureLoadingScreen: some View {
        VStack(spacing: 20) {
            checkpointMarker(
                id: "course-checkpoint-lf45-loading",
                label: "LF-45 structure loading",
                value: "Reading source files and course pages"
            )
            Spacer()
            ProgressView("Reading course structure…")
                .accessibilityIdentifier("course-structure-loading")
            Spacer()
        }
        .padding(20)
    }

    private var structureErrorScreen: some View {
        VStack(spacing: 0) {
            checkpointMarker(
                id: "course-checkpoint-lf45-error",
                label: "LF-45 structure error",
                value: "Deterministic source-file and course-page load failure"
            )
            CourseStructureLoadFailureView(
                error: "Source files: Deterministic source-file failure\nCourse pages: Deterministic course-page failure"
            ) {
                presentation = .lf45Recovered
            }
        }
    }

    private var pageLoadErrorScreen: some View {
        VStack(spacing: 0) {
            checkpointMarker(
                id: "course-checkpoint-lf48-load-error",
                label: "LF-48 page load error",
                value: "Deterministic page load failure"
            )
            CoursePageLoadFailureView(
                pageID: Self.editorPageID,
                error: "Deterministic page load failure"
            ) {
                presentation = .lf48Recovered
            }
        }
    }

    private func pageOpeningScreen(
        pageID: String,
        markerID: String,
        markerLabel: String
    ) -> some View {
        VStack(spacing: 20) {
            checkpointMarker(
                id: markerID,
                label: markerLabel,
                value: "Opening \(pageID)"
            )
            Spacer()
            ProgressView("Opening course page…")
                .accessibilityIdentifier("course-page-opening-\(pageID)")
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder
    private func structureScreen(markerID: String, markerLabel: String) -> some View {
        if let snapshot {
            VStack(spacing: 0) {
                checkpointMarker(
                    id: markerID,
                    label: markerLabel,
                    value: "\(snapshot.fileCount) files, \(snapshot.folderCount) folders"
                )
                ScrollView {
                    CourseStructureBrowser(
                        snapshot: snapshot,
                        recommendedFilePath: Self.fieldGuidePath,
                        onOpenFile: { node in
                            guard !node.isDirectory else { return }
                            selectedRelativePath = node.relativePath
                            presentation = .selectedFile
                        }
                    )
                    .padding(20)
                }
            }
        } else {
            ProgressView("Preparing course structure…")
        }
    }

    @ViewBuilder
    private func fileScreen(
        relativePath: String,
        markerID: String,
        markerLabel: String
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                checkpointMarker(
                    id: markerID,
                    label: markerLabel,
                    value: relativePath
                )
                Spacer(minLength: 8)
                Button("Back to Structure") {
                    presentation = .lf47BackToStructure
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("course-checkpoint-lf47-back")
            }
            .padding(.horizontal, 12)

            CourseEditorCheckpointFileViewerView(
                course: fixtureCourse,
                relativePath: relativePath,
                rootURL: locations.workspaceRootURL,
                onOpenRelativePath: { path in
                    selectedRelativePath = path
                    presentation = .selectedFile
                },
                onOpenCourseStructure: {
                    presentation = .lf47BackToStructure
                },
                onReturnToLibrary: {
                    presentation = .lf47BackToStructure
                }
            )
        }
    }

    @ViewBuilder
    private func editorScreen(
        markerID: String,
        markerLabel: String,
        markerValue: String? = nil,
        showsDocumentOrder: Bool = false,
        showsSelectionAction: Bool = false,
        showsAnnotation: Bool = false,
        onRetrySave: (() -> Void)? = nil,
        primaryAction: (title: String, identifier: String, action: () -> Void)? = nil
    ) -> some View {
        if let model {
            VStack(spacing: 0) {
                if let evidence = scenario.strictEvidence {
                    strictEvidenceHeader(evidence)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        checkpointMarker(
                            id: markerID,
                            label: markerLabel,
                            value: markerValue ?? model.pageID
                        )
                        Spacer(minLength: 8)
                        if showsSelectionAction {
                            Button("Resolve selection") {
                                resolveDeterministicSelection(in: model)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Resolve deterministic selection")
                            .accessibilityIdentifier("course-checkpoint-lf51-resolve-selection")
                        }
                        if let primaryAction {
                            Button(primaryAction.title, action: primaryAction.action)
                                .buttonStyle(.bordered)
                                .disabled(transitionInFlight)
                                .accessibilityIdentifier(primaryAction.identifier)
                        }
                        if transitionInFlight {
                            ProgressView()
                                .accessibilityLabel("Completing checkpoint transition")
                        }
                    }
                    if showsDocumentOrder {
                        checkpointMarker(
                            id: "course-checkpoint-document-order",
                            label: "Document order",
                            value: Self.documentOrder(model.document)
                        )
                    }
                    if let selectionReferenceValue {
                        HStack {
                            checkpointMarker(
                                id: "course-checkpoint-lf51-selection",
                                label: "LF-51 selection resolved",
                                value: selectionReferenceValue
                            )
                            Spacer()
                        }
                    }
                    if showsAnnotation, let value = annotationAccessibilityValue(in: model) {
                        HStack {
                            checkpointMarker(
                                id: annotationWasOpened
                                    ? "course-checkpoint-lf51-annotation-opened"
                                    : "course-checkpoint-lf51-annotation-projection",
                                label: annotationWasOpened
                                    ? "LF-51 annotation opened"
                                    : "LF-51 annotation projection",
                                value: value
                            )
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemBackground))

                CoursePageEditorCanvas(
                    model: model,
                    textAnnotations: showsAnnotation ? annotations(in: model) : [],
                    onAskAboutSelection: { selection in
                        resolve(selection, in: model)
                    },
                    onOpenTextAnnotation: { _ in
                        annotationWasOpened = true
                        return true
                    },
                    onOpenPage: { destination in
                        Task { await openLinkedPage(destination.id) }
                    },
                    // Highlights only open in reading mode; editing places the caret.
                    startsInEditingMode: !showsAnnotation,
                    onRetrySave: onRetrySave
                )
            }
        } else {
            ProgressView("Preparing course page…")
        }
    }

    private func strictEvidenceHeader(
        _ evidence: CourseEditorCheckpointStrictEvidence
    ) -> some View {
        VStack(spacing: 3) {
            Text("RUNTIME-INSTRUMENTED PRODUCT · PER-RUN TEMPORARY DATABASE")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.indigo)
                .accessibilityIdentifier("courseEditorCheckpoint.nonLiveBoundary")

            HStack(spacing: 8) {
                Text("Route · \(evidence.checkpointID)")
                    .accessibilityIdentifier("courseEditorCheckpoint.route")
                    .accessibilityValue(
                        CourseEditorCheckpointUITestConfigurationParser.baseFlag
                    )
                Spacer(minLength: 4)
                Text("State · \(evidence.substate)")
                    .accessibilityIdentifier("courseEditorCheckpoint.state")
                    .accessibilityValue(evidence.substate)
            }

            HStack(spacing: 8) {
                Text("Hook · \(evidence.hookIdentifier)")
                    .accessibilityIdentifier("courseEditorCheckpoint.hook")
                    .accessibilityValue(evidence.hookIdentifier)
                Spacer(minLength: 4)
                Text("Probe · \(evidence.runtimeProbeIdentifier)")
                    .accessibilityIdentifier("courseEditorCheckpoint.runtimeProbeID")
                    .accessibilityValue(evidence.runtimeProbeIdentifier)
            }

            if let receipt = lf50RuntimeProbeReceipt {
                Text("Persistence truth · \(receipt.phase.rawValue)")
                    .lineLimit(1)
                    .accessibilityIdentifier("courseEditorCheckpoint.runtimeProbe")
                    .accessibilityValue(receipt.accessibilityValue)
            }
        }
        .font(.caption2.monospaced().weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
        .background(Color(uiColor: .systemBackground))
    }

    private func reopenPrompt(
        markerID: String,
        markerLabel: String,
        buttonTitle: String,
        buttonID: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            checkpointMarker(
                id: markerID,
                label: markerLabel,
                value: "Editor model released"
            )
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(transitionInFlight)
                .accessibilityIdentifier(buttonID)
            if transitionInFlight {
                ProgressView("Reopening course page…")
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private var lf50PersistedForRelaunchScreen: some View {
        if let persistenceReceipt {
            VStack(spacing: 18) {
                checkpointMarker(
                    id: "course-checkpoint-lf50-phase1-persisted",
                    label: "LF-50 first process persisted",
                    value: persistenceReceipt.accessibilityValue
                )
                Text("Terminate this process, then relaunch with the same run token to reopen without deletion or reseeding.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        } else {
            ProgressView("Checkpointing persisted database…")
        }
    }

    private func checkpointMarker(id: String, label: String, value: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(id)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private var navigationTitle: String {
        switch presentation {
        case .linkedPageOpening, .linkedPage:
            "Linked destination"
        case .lf50PersistedForRelaunch:
            "Persistence checkpoint"
        case .awaitingAnnotationReopen, .reopenedAnnotation:
            "Annotation checkpoint"
        default:
            "Course editor checkpoints"
        }
    }

    private var fixtureCourse: LearningCourse {
        LearningCourse(
            id: Self.courseID,
            title: "Editor Checkpoint Course",
            subtitle: "Deterministic structure and editor fixture",
            accentHex: "1F6FEB",
            progress: 0.5,
            lessonCount: 2,
            duration: "10 min",
            status: .ready,
            workspaceID: Self.workspaceID
        )
    }

    @MainActor
    private func prepareFixture() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        defer { signalContentReady() }

        do {
            if scenario.fixtureDependency == .persistedDocumentRepository {
                try await prepareReopenedPersistenceFixture()
                isPrepared = true
                return
            }

            try locations.removeFixtureRoot()
            if scenario.fixtureDependency == .workspaceFiles {
                try Self.writeCourseFiles(to: locations.workspaceRootURL)
                snapshot = try CourseWorkspaceSnapshot.load(from: locations.workspaceRootURL)
                isPrepared = true
                return
            }

            guard scenario.fixtureDependency == .documentRepository else {
                isPrepared = true
                return
            }
            let pageWorkspace: PageWorkspace
            if scenario == .lf50ErrorOverlay {
                pageWorkspace = try Self.makeLF50SaveRecoveryWorkspace()
            } else {
                pageWorkspace = try Self.makePageWorkspace()
            }
            let repository = try await CourseDocumentRepository.openDebugFixture(
                workspaceID: Self.workspaceID,
                databaseURL: locations.databaseURL,
                fixtureRootURL: locations.fixtureRootURL,
                runToken: configuration.runToken,
                workspace: pageWorkspace,
                autosaveDelay: .seconds(60)
            )
            self.repository = repository

            var editorModel = try await Self.loadModel(
                pageID: Self.editorPageID,
                repository: repository
            )

            switch scenario {
            case .lf49Reordered:
                editorModel.userChangedDocument(Self.reorderedDocument(includeModification: false))
                await editorModel.flush()
                try Self.requireSaveSucceeded(editorModel)
                try Self.requireDocumentOrder(
                    editorModel.document,
                    expected: Self.reorderedOrder
                )
            case .lf49LinkedPage:
                editorModel = try await Self.loadModel(
                    pageID: Self.linkedPageID,
                    repository: repository
                )
            case .lf50Modified:
                editorModel.userChangedDocument(Self.reorderedDocument(includeModification: true))
                try Self.requireDocumentOrder(
                    editorModel.document,
                    expected: Self.modifiedOrder
                )
            case .lf50ErrorOverlay:
                let draft = Self.saveRecoveryDocument()
                await repository.debugFailNextFlushes()
                editorModel.userChangedDocument(draft)
                guard editorModel.saveState == .saving else {
                    throw FixtureError.lf50ExpectedFailedSave(
                        editorModel.saveState.accessibilityValue
                    )
                }
                await editorModel.flush()
                guard editorModel.saveState.canRetry else {
                    throw FixtureError.lf50ExpectedFailedSave(
                        editorModel.saveState.accessibilityValue
                    )
                }
                guard Self.documentsMatchPersistedSemantics(editorModel.document, draft) else {
                    throw FixtureError.lf50DraftNotRetained
                }
                try Self.requireDocumentOrder(
                    editorModel.document,
                    expected: Self.saveRecoveryOrder
                )
                lf50RuntimeProbeReceipt = try await Self.makeLF50RuntimeProbeReceipt(
                    phase: .errorOverlay,
                    transition: "saving>failed",
                    model: editorModel,
                    locations: locations,
                    evidence: try Self.requireLF50Evidence(for: scenario)
                )
            case .lf51ReopenedAnnotation:
                editorModel = try await Self.loadModel(
                    pageID: Self.editorPageID,
                    repository: repository
                )
                guard !annotations(in: editorModel).isEmpty else {
                    throw FixtureError.annotationResolution
                }
            default:
                break
            }

            model = editorModel
            isPrepared = true
        } catch {
            setupError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareReopenedPersistenceFixture() async throws {
        guard FileManager.default.fileExists(atPath: locations.receiptURL.path) else {
            throw FixtureError.missingPersistenceReceipt
        }
        let receiptData = try Data(contentsOf: locations.receiptURL)
        let receipt: CourseEditorCheckpointPersistenceReceipt
        do {
            receipt = try JSONDecoder().decode(
                CourseEditorCheckpointPersistenceReceipt.self,
                from: receiptData
            )
        } catch {
            throw FixtureError.invalidPersistenceReceipt(error.localizedDescription)
        }
        guard receipt.version == CourseEditorCheckpointPersistenceReceipt.currentVersion,
              receipt.runToken == configuration.runToken,
              receipt.pageID == Self.editorPageID,
              receipt.documentOrder == Self.modifiedOrder else {
            throw FixtureError.invalidPersistenceReceipt(
                "version, run token, page, or expected order did not match"
            )
        }

        // This byte comparison intentionally happens before any SQLite object is
        // constructed in the second process. A missing database therefore fails
        // as a read instead of falling through to NativeEditorMCP's seed path.
        let databaseData = try Data(contentsOf: locations.databaseURL, options: .mappedIfSafe)
        guard databaseData.count == receipt.databaseByteCount,
              Self.sha256(databaseData) == receipt.databaseSHA256 else {
            throw FixtureError.databaseFingerprintMismatch
        }

        let reopenedRepository = try await CourseDocumentRepository.reopenDebugFixture(
            workspaceID: Self.workspaceID,
            databaseURL: locations.databaseURL,
            fixtureRootURL: locations.fixtureRootURL,
            runToken: configuration.runToken,
            autosaveDelay: .seconds(60)
        )
        let reopenedModel = try await Self.loadModel(
            pageID: Self.editorPageID,
            repository: reopenedRepository
        )
        try Self.requireDocumentOrder(reopenedModel.document, expected: Self.modifiedOrder)
        guard try Self.documentSHA256(reopenedModel.document) == receipt.documentSHA256 else {
            throw FixtureError.documentFingerprintMismatch
        }

        repository = reopenedRepository
        model = reopenedModel
        persistenceReceipt = receipt
    }

    @MainActor
    private func openLinkedPage(_ pageID: String) async {
        guard !transitionInFlight else { return }
        guard pageID == Self.linkedPageID, let repository else {
            setupError = FixtureError.unexpectedPage(pageID).localizedDescription
            return
        }
        transitionInFlight = true
        defer { transitionInFlight = false }
        presentation = .linkedPageOpening
        if let model {
            await model.flush()
            do {
                try Self.requireSaveSucceeded(model)
            } catch {
                setupError = error.localizedDescription
                return
            }
        }
        model = nil
        do {
            model = try await Self.loadModel(pageID: pageID, repository: repository)
            presentation = .linkedPage
        } catch {
            setupError = error.localizedDescription
        }
    }

    private func leaveModifiedPage() {
        guard !transitionInFlight, let model else { return }
        transitionInFlight = true
        Task { @MainActor in
            await model.flush()
            do {
                try Self.requireSaveSucceeded(model)
                try Self.requireDocumentOrder(model.document, expected: Self.modifiedOrder)
                let receipt = try await Self.makePersistenceReceipt(
                    model: model,
                    locations: locations
                )
                persistenceReceipt = receipt
                self.model = nil
                repository = nil
                presentation = .lf50PersistedForRelaunch
            } catch {
                setupError = error.localizedDescription
            }
            transitionInFlight = false
        }
    }

    private func retryLF50Save() {
        guard scenario == .lf50ErrorOverlay,
              !transitionInFlight,
              let model,
              let repository,
              model.saveState.canRetry else { return }
        transitionInFlight = true

        Task { @MainActor in
            do {
                let evidence = try Self.requireLF50Evidence(for: scenario)
                await repository.debugDelayNextSuccessfulFlush(.milliseconds(800))
                let savingObserver = Task { @MainActor in
                    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                    while ContinuousClock.now < deadline {
                        if model.saveState == .saving {
                            return true
                        }
                        await Task.yield()
                    }
                    return false
                }
                let retry = Task { @MainActor in
                    await model.retrySave()
                }
                let observedSaving = await savingObserver.value
                await retry.value

                guard observedSaving else {
                    throw FixtureError.lf50RetryDidNotExposeSaving
                }
                guard model.saveState == .saved else {
                    throw FixtureError.lf50RetryDidNotSave(
                        model.saveState.accessibilityValue
                    )
                }
                guard Self.documentsMatchPersistedSemantics(
                    model.document,
                    Self.saveRecoveryDocument()
                ) else {
                    throw FixtureError.lf50DraftNotRetained
                }
                try Self.requireDocumentOrder(
                    model.document,
                    expected: Self.saveRecoveryOrder
                )
                let receipt = try await Self.makeLF50RuntimeProbeReceipt(
                    phase: .savedAfterRetry,
                    transition: "failed>saving>saved",
                    model: model,
                    locations: locations,
                    evidence: evidence
                )

                lf50RuntimeProbeReceipt = receipt
            } catch {
                setupError = error.localizedDescription
            }
            transitionInFlight = false
        }
    }

    private func leaveAnnotatedPage() {
        guard !transitionInFlight else { return }
        model = nil
        annotationWasOpened = false
        presentation = .awaitingAnnotationReopen
    }

    private func reopenAnnotatedPage() {
        guard !transitionInFlight, let repository else { return }
        transitionInFlight = true
        Task { @MainActor in
            do {
                let reopened = try await Self.loadModel(
                    pageID: Self.editorPageID,
                    repository: repository
                )
                guard !annotations(in: reopened).isEmpty else {
                    throw FixtureError.annotationResolution
                }
                model = reopened
                presentation = .reopenedAnnotation
            } catch {
                setupError = error.localizedDescription
            }
            transitionInFlight = false
        }
    }

    private func resolveDeterministicSelection(in model: CoursePageEditorModel) {
        let selection = NativeBlockEditorSelection(
            blockID: Self.selectionBlockID,
            path: BlockPath([0]),
            range: Self.selectionRange,
            text: Self.selectionText
        )
        resolve(selection, in: model)
    }

    @discardableResult
    private func resolve(
        _ selection: NativeBlockEditorSelection,
        in model: CoursePageEditorModel
    ) -> CourseTextReference? {
        guard let reference = CourseSelectionAnchorResolver.reference(
            courseID: Self.courseID,
            pageID: Self.editorPageID,
            pageTitle: model.title,
            selection: selection,
            document: model.document
        ) else {
            setupError = FixtureError.selectionResolution.localizedDescription
            return nil
        }
        selectionReferenceValue = [
            "course=\(reference.courseID)",
            "page=\(reference.pageID)",
            "block=\(reference.blockID ?? "nil")",
            "path=\(reference.pathIndices.map(String.init).joined(separator: "."))",
            "range=\(reference.rangeLocation):\(reference.rangeLength)",
            "text=\(reference.selectedText)",
        ].joined(separator: ";")
        return reference
    }

    private func annotations(
        in model: CoursePageEditorModel
    ) -> [NativeBlockEditorTextAnnotation] {
        guard model.pageID == Self.editorPageID,
              let node = model.document.node(at: BlockPath([0])),
              node.delta?.plainText.hasPrefix(Self.selectionText) == true else { return [] }
        return [NativeBlockEditorTextAnnotation(
            id: Self.annotationID,
            blockID: node.stableBlockID,
            path: BlockPath([0]),
            range: Self.selectionRange
        )]
    }

    private func annotationAccessibilityValue(
        in model: CoursePageEditorModel
    ) -> String? {
        guard let annotation = annotations(in: model).first else { return nil }
        return [
            "id=\(annotation.id)",
            "page=\(model.pageID)",
            "block=\(annotation.blockID ?? "nil")",
            "path=\(annotation.path.indices.map(String.init).joined(separator: "."))",
            "range=\(annotation.range.location):\(annotation.range.length)",
        ].joined(separator: ";")
    }

    private func signalContentReady() {
        (UIApplication.shared.delegate as? AppDelegate)?.signalContentReady()
    }

    private static var selectionRange: NSRange {
        NSRange(location: 0, length: selectionText.utf16.count)
    }

    private static var reorderedOrder: String {
        [
            "Selection anchor survives reopen.",
            "First persisted block",
            "Second persisted block",
            "Linked destination",
        ].joined(separator: " | ")
    }

    private static var modifiedOrder: String {
        [
            "Selection anchor survives reopen.",
            "First persisted block",
            "Second persisted block",
            "Linked destination",
            "Modified before leaving.",
        ].joined(separator: " | ")
    }

    private static var saveRecoveryOrder: String {
        [
            "paragraph",
            "First pending recovery edit",
            "Second pending recovery edit",
        ].joined(separator: " | ")
    }

    private static func writeCourseFiles(to workspaceRootURL: URL) throws {
        let fieldGuideURL = workspaceRootURL.appendingPathComponent(fieldGuidePath)
        let lessonURL = workspaceRootURL.appendingPathComponent(
            "chapters/chapter-1/lesson.md"
        )
        try FileManager.default.createDirectory(
            at: fieldGuideURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: lessonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            "# Field Guide\n\nDeterministic source content for LF-47.\n".utf8
        ).write(to: fieldGuideURL, options: .atomic)
        try Data(
            "# Lesson One\n\nA deterministic chapter lesson.\n".utf8
        ).write(to: lessonURL, options: .atomic)
    }

    @MainActor
    private static func makeLF50RuntimeProbeReceipt(
        phase: CourseEditorLF50RuntimeProbeReceipt.Phase,
        transition: String,
        model: CoursePageEditorModel,
        locations: CourseEditorCheckpointFixtureLocations,
        evidence: CourseEditorCheckpointStrictEvidence
    ) async throws -> CourseEditorLF50RuntimeProbeReceipt {
        let expectedDraft = saveRecoveryDocument()
        let draftRetained = documentsMatchPersistedSemantics(model.document, expectedDraft)
        guard draftRetained else {
            throw FixtureError.lf50DraftNotRetained
        }

        let library = try SQLiteLibraryStore(url: locations.databaseURL)
        try await library.checkpoint()
        guard let persisted = try await library.load(),
              let persistedPage = persisted.workspace.page(id: editorPageID),
              let revision = try await library.revision(for: editorPageID) else {
            throw FixtureError.lf50UnexpectedPersistence(phase: phase.rawValue)
        }

        let persistedMatchesDraft = documentsMatchPersistedSemantics(
            persistedPage.document,
            model.document
        )
        let pendingJournalExists = FileManager.default.fileExists(
            atPath: locations.pendingEditsURL.path
        )
        switch phase {
        case .errorOverlay:
            guard model.saveState.canRetry,
                  !persistedMatchesDraft,
                  pendingJournalExists else {
                throw FixtureError.lf50UnexpectedPersistence(phase: phase.rawValue)
            }
        case .savedAfterRetry:
            guard model.saveState == .saved,
                  persistedMatchesDraft,
                  !pendingJournalExists else {
                throw FixtureError.lf50UnexpectedPersistence(phase: phase.rawValue)
            }
        }

        let databaseData = try Data(
            contentsOf: locations.databaseURL,
            options: .mappedIfSafe
        )
        return CourseEditorLF50RuntimeProbeReceipt(
            probeID: evidence.runtimeProbeIdentifier,
            hookID: evidence.hookIdentifier,
            runToken: locations.runToken,
            phase: phase,
            transition: transition,
            draftRetained: draftRetained,
            pendingJournalExists: pendingJournalExists,
            persistedMatchesDraft: persistedMatchesDraft,
            revision: revision,
            databaseByteCount: databaseData.count,
            databaseSHA256: sha256(databaseData),
            draftSHA256: try documentSHA256(model.document),
            persistedSHA256: try documentSHA256(persistedPage.document)
        )
    }

    private static func requireLF50Evidence(
        for scenario: CourseEditorCheckpointUITestScenario
    ) throws -> CourseEditorCheckpointStrictEvidence {
        guard let evidence = scenario.strictEvidence,
              evidence.checkpointID == "LF-50",
              evidence.substate == "error-overlay" else {
            throw FixtureError.lf50UnexpectedPersistence(phase: "evidence-metadata")
        }
        return evidence
    }

    @MainActor
    private static func makePersistenceReceipt(
        model: CoursePageEditorModel,
        locations: CourseEditorCheckpointFixtureLocations
    ) async throws -> CourseEditorCheckpointPersistenceReceipt {
        let library = try SQLiteLibraryStore(url: locations.databaseURL)
        try await library.checkpoint()
        guard let persisted = try await library.load(),
              let persistedPage = persisted.workspace.page(id: editorPageID) else {
            throw FixtureError.persistedDocumentMismatch
        }
        try requireDocumentOrder(persistedPage.document, expected: modifiedOrder)
        guard documentsMatchPersistedSemantics(persistedPage.document, model.document) else {
            throw FixtureError.persistedDocumentMismatch
        }

        let databaseData = try Data(contentsOf: locations.databaseURL, options: .mappedIfSafe)
        let receipt = CourseEditorCheckpointPersistenceReceipt(
            version: CourseEditorCheckpointPersistenceReceipt.currentVersion,
            runToken: locations.runToken,
            databaseByteCount: databaseData.count,
            databaseSHA256: sha256(databaseData),
            pageID: editorPageID,
            documentSHA256: try documentSHA256(persistedPage.document),
            documentOrder: documentOrder(persistedPage.document)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipt).write(to: locations.receiptURL, options: .atomic)
        return receipt
    }

    private static func documentSHA256(_ document: BlockDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(document))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makePageWorkspace() throws -> PageWorkspace {
        var workspace = PageWorkspace(rootPage: PageRecord(
            id: rootPageID,
            title: "Editor checkpoint course",
            document: BlockDocument(root: BlockNode(
                type: "page",
                children: [anchored(.heading("Editor checkpoint course"), id: "checkpoint-root-heading")]
            ))
        ))
        _ = try workspace.createPage(
            title: "Editor checkpoint page",
            parentID: rootPageID,
            document: baseDocument(),
            id: editorPageID
        )
        _ = try workspace.createPage(
            title: "Linked destination",
            parentID: rootPageID,
            document: BlockDocument(root: BlockNode(
                type: "page",
                children: [
                    anchored(.heading("Linked destination"), id: "checkpoint-linked-heading"),
                    anchored(
                        .paragraph("This page opened through a real native page reference."),
                        id: "checkpoint-linked-body"
                    ),
                ]
            )),
            id: linkedPageID
        )
        try workspace.validate()
        return workspace
    }

    private static func makeLF50SaveRecoveryWorkspace() throws -> PageWorkspace {
        let workspace = PageWorkspace(rootPage: PageRecord(
            id: editorPageID,
            title: "Save recovery evidence",
            document: saveRecoveryBaseDocument()
        ))
        try workspace.validate()
        return workspace
    }

    private static func baseDocument() -> BlockDocument {
        BlockDocument(root: BlockNode(
            type: "page",
            children: [
                anchored(
                    .paragraph("Selection anchor survives reopen."),
                    id: selectionBlockID
                ),
                anchored(.paragraph("First persisted block"), id: "checkpoint-first-block"),
                anchored(
                    .pageReference(pageID: linkedPageID, title: "Linked destination"),
                    id: "checkpoint-linked-reference"
                ),
                anchored(.paragraph("Second persisted block"), id: "checkpoint-second-block"),
            ]
        ))
    }

    private static func reorderedDocument(includeModification: Bool) -> BlockDocument {
        var document = baseDocument()
        let reference = document.root.children.remove(at: 2)
        document.root.children.append(reference)
        if includeModification {
            document.root.children.append(
                anchored(
                    .paragraph("Modified before leaving."),
                    id: "checkpoint-modified-block"
                )
            )
        }
        return document
    }

    private static func saveRecoveryDocument() -> BlockDocument {
        var document = saveRecoveryBaseDocument()
        document.root.children.append(
            anchored(
                .paragraph("First pending recovery edit"),
                id: "checkpoint-recovery-first"
            )
        )
        document.root.children.append(
            anchored(
                .paragraph("Second pending recovery edit"),
                id: "checkpoint-recovery-second"
            )
        )
        return document
    }

    private static func saveRecoveryBaseDocument() -> BlockDocument {
        BlockDocument(root: BlockNode(
            type: "page",
            children: [
                anchored(.paragraph(), id: "checkpoint-recovery-base"),
            ]
        ))
    }

    private static func anchored(_ node: BlockNode, id: String) -> BlockNode {
        var result = node
        result.data["block_id"] = .string(id)
        return result
    }

    /// SQLite/AppFlowy reloads reconstruct runtime-only `BlockNode.id` UUIDs.
    /// Persisted equality therefore compares the complete serialized semantics:
    /// node type, lossless data (including stable `block_id`), and child order.
    private static func documentsMatchPersistedSemantics(
        _ lhs: BlockDocument,
        _ rhs: BlockDocument
    ) -> Bool {
        nodesMatchPersistedSemantics(lhs.root, rhs.root)
    }

    private static func nodesMatchPersistedSemantics(
        _ lhs: BlockNode,
        _ rhs: BlockNode
    ) -> Bool {
        guard lhs.type == rhs.type,
              lhs.data == rhs.data,
              lhs.children.count == rhs.children.count else {
            return false
        }
        return zip(lhs.children, rhs.children).allSatisfy {
            nodesMatchPersistedSemantics($0, $1)
        }
    }

    @MainActor
    private static func loadModel(
        pageID: String,
        repository: CourseDocumentRepository
    ) async throws -> CoursePageEditorModel {
        let model = CoursePageEditorModel(
            pageID: pageID,
            repository: repository,
            stagingDelay: .zero
        )
        await model.load()
        if let error = model.errorMessage {
            throw FixtureError.editorLoad(error)
        }
        return model
    }

    private static func requireDocumentOrder(
        _ document: BlockDocument,
        expected: String
    ) throws {
        let actual = documentOrder(document)
        guard actual == expected else {
            throw FixtureError.unexpectedDocumentOrder(expected: expected, actual: actual)
        }
    }

    private static func requireSaveSucceeded(_ model: CoursePageEditorModel) throws {
        if case let .failed(message) = model.saveState {
            throw FixtureError.editorLoad(message)
        }
    }

    private static func documentOrder(_ document: BlockDocument) -> String {
        document.root.children.map { node in
            if let text = node.delta?.plainText, !text.isEmpty {
                return text
            }
            if let title = node.data["title"]?.stringValue, !title.isEmpty {
                return title
            }
            return node.type
        }
        .joined(separator: " | ")
    }
}
#endif

/// Shown when a saved selection discussion no longer has a resolvable passage.
/// Its only job is to give the learner a way back out of the full-screen cover.
private struct CourseSelectionDiscussionUnavailableView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "This discussion is unavailable",
                systemImage: "text.badge.xmark",
                description: Text("Its passage is no longer part of this page.")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
        .accessibilityIdentifier("course-selection-discussion-unavailable")
    }
}


/// A selected passage waiting for the learner to say what to explore.
private struct CourseExploreSelectionItem: Identifiable {
    let id = UUID()
    let selection: NativeBlockEditorSelection

    var passage: String {
        selection.text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// What a tap inside a passage's threads asks the reader to do once they close.
enum CoursePassageAction {
    case openExploration(CourseLearningNode)
    case openDiscussion(CourseSelectionDiscussion)
    case exploreAgain(NativeBlockEditorSelection)
    case ask(NativeBlockEditorSelection)
}

/// Explorations that already start on a selected passage.
struct CourseExplorationOverlap {
    var titles: [String] = []
    var usedIntents: Set<CourseExplorePassageIntent> = []
}

/// The reader's exploration status and what its menu can do.
struct CourseExplorationStatusContent {
    let summary: CourseExplorationStatusSummary
    let currentPageID: String
    let onOpen: (CourseExplorationJob) -> Void
    let onRetry: (CourseExplorationJob) -> Void
    let onDismiss: (CourseExplorationJob) -> Void
    let onMarkAllSeen: () -> Void

    func menu(_ placement: CourseExplorationStatusMenu.Placement) -> CourseExplorationStatusMenu {
        CourseExplorationStatusMenu(
            summary: summary,
            currentPageID: currentPageID,
            placement: placement,
            onOpen: onOpen,
            onRetry: onRetry,
            onDismiss: onDismiss,
            onMarkAllSeen: onMarkAllSeen
        )
    }
}

/// A tapped passage whose threads are showing, and where to point at it.
private struct CoursePassagePresentation: Identifiable {
    let hit: NativeBlockEditorAnnotationHit
    /// The tapped words, in the canvas's own coordinates.
    let anchorRect: CGRect
    /// Whether the threads sit below the tapped line.
    let opensBelow: Bool
    /// The reading offset when it opened; scrolling away closes it.
    let readingOffset: CGFloat?
    var id: UUID { hit.id }
}

private struct CoursePageEditorCanvas: View {
    @Bindable var model: CoursePageEditorModel
    @AppStorage("coursePage.wrapsCodeLines") private var wrapsCodeLines = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isEditing: Bool
    @State private var readingSelection: NativeBlockEditorSelection?
    @State private var exploringSelection: CourseExploreSelectionItem?
    @State private var passagePresentation: CoursePassagePresentation?
    @State private var pendingPassageAction: CoursePassageAction?
    @State private var canvasFrame: CGRect = .zero
    @State private var latestReadingOffset: CGFloat?
    let textAnnotations: [NativeBlockEditorTextAnnotation]
    let onAskAboutSelection: (NativeBlockEditorSelection) -> CourseTextReference?
    /// Forks an exploration from the passage, with the learner's optional
    /// question. Returns once the new page exists.
    let onExploreSelection: ((NativeBlockEditorSelection, String?) async throws -> Void)?
    let explorationOverlap: ((NativeBlockEditorSelection) -> CourseExplorationOverlap)?
    /// Every exploration the learner started in this course.
    let explorationStatus: CourseExplorationStatusContent?
    let onOpenTextAnnotation: (NativeBlockEditorTextAnnotation) -> Bool
    /// Decides what a tap on highlighted text does; true shows its threads.
    let onTapTextAnnotations: ((NativeBlockEditorAnnotationHit) -> Bool)?
    let passageThreads: ((NativeBlockEditorAnnotationHit, @escaping (CoursePassageAction) -> Void) -> AnyView)?
    let onPassageAction: ((CoursePassageAction) -> Void)?
    let onOpenPage: (NativeBlockEditorPageDestination) -> Void
    var onRetrySave: (() -> Void)?
    let readingFooter: AnyView?
    let additionalHiddenReadingBlockIDs: Set<UUID>
    let onAskAboutPage: (() -> Void)?
    let initialReadingPosition: NativeBlockEditorReadingPosition?
    let onReadingPositionChange: ((NativeBlockEditorReadingPosition) -> Void)?
    let onToggleOutline: (() -> Void)?
    let isOutlineVisible: Bool

    init(
        model: CoursePageEditorModel,
        textAnnotations: [NativeBlockEditorTextAnnotation],
        onAskAboutSelection: @escaping (NativeBlockEditorSelection) -> CourseTextReference?,
        onExploreSelection: ((NativeBlockEditorSelection, String?) async throws -> Void)? = nil,
        explorationOverlap: ((NativeBlockEditorSelection) -> CourseExplorationOverlap)? = nil,
        explorationStatus: CourseExplorationStatusContent? = nil,
        onOpenTextAnnotation: @escaping (NativeBlockEditorTextAnnotation) -> Bool,
        onTapTextAnnotations: ((NativeBlockEditorAnnotationHit) -> Bool)? = nil,
        passageThreads: ((NativeBlockEditorAnnotationHit, @escaping (CoursePassageAction) -> Void) -> AnyView)? = nil,
        onPassageAction: ((CoursePassageAction) -> Void)? = nil,
        onOpenPage: @escaping (NativeBlockEditorPageDestination) -> Void,
        startsInEditingMode: Bool = false,
        onRetrySave: (() -> Void)? = nil,
        readingFooter: AnyView? = nil,
        additionalHiddenReadingBlockIDs: Set<UUID> = [],
        onAskAboutPage: (() -> Void)? = nil,
        initialReadingPosition: NativeBlockEditorReadingPosition? = nil,
        onReadingPositionChange: ((NativeBlockEditorReadingPosition) -> Void)? = nil,
        onToggleOutline: (() -> Void)? = nil,
        isOutlineVisible: Bool = false
    ) {
        self.model = model
        self.textAnnotations = textAnnotations
        self.onAskAboutSelection = onAskAboutSelection
        self.onExploreSelection = onExploreSelection
        self.explorationOverlap = explorationOverlap
        self.explorationStatus = explorationStatus
        self.onOpenTextAnnotation = onOpenTextAnnotation
        self.onTapTextAnnotations = onTapTextAnnotations
        self.passageThreads = passageThreads
        self.onPassageAction = onPassageAction
        self.onOpenPage = onOpenPage
        _isEditing = State(initialValue: startsInEditingMode)
        self.onRetrySave = onRetrySave
        self.readingFooter = readingFooter
        self.additionalHiddenReadingBlockIDs = additionalHiddenReadingBlockIDs
        self.onAskAboutPage = onAskAboutPage
        self.initialReadingPosition = initialReadingPosition
        self.onReadingPositionChange = onReadingPositionChange
        self.onToggleOutline = onToggleOutline
        self.isOutlineVisible = isOutlineVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
            desktopReaderControls
            Divider()
            #endif
            if displayedSaveState != .idle {
                CoursePageSaveStatusView(state: displayedSaveState) {
                    if let onRetrySave {
                        onRetrySave()
                    } else {
                        Task { await model.retrySave() }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.vertical, 8)
            }

            NativeBlockEditorView(
                document: Binding(
                    get: { model.document },
                    set: { model.userChangedDocument($0) }
                ),
                configuration: NativeBlockEditorConfiguration(
                    accentColor: .blue,
                    contentMaxWidth: 760,
                    horizontalPadding: 20,
                    verticalPadding: 18,
                    showsFormattingToolbar: isEditing,
                    showsDocumentToolbar: isEditing,
                    allowsBlockReordering: isEditing,
                    isEditable: isEditing,
                    showsTrailingAddBlockRow: false,
                    hiddenBlockIDs: hiddenReadingBlockIDs
                ),
                header: AnyView(
                    Text(model.title)
                        .accessibilityIdentifier("course-page-title-\(model.pageID)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
                ),
                footer: isEditing ? nil : readingFooter,
                pageResolver: { pageID in
                    model.pageTitle(id: pageID).map {
                        NativeBlockEditorPageDestination(id: pageID, title: $0)
                    }
                },
                onOpenPage: onOpenPage,
                onOpenURL: { url in
                    guard let pageID = CoursePageLinkResolver.pageID(from: url) else {
                        return false
                    }
                    onOpenPage(
                        NativeBlockEditorPageDestination(
                            id: pageID,
                            title: model.pageTitle(id: pageID) ?? "Course page"
                        )
                    )
                    return true
                },
                onAskAboutSelection: { selection in
                    if onAskAboutSelection(selection) != nil {
                        readingSelection = nil
                    }
                },
                onSelectionChange: { selection in
                    guard !isEditing else { return }
                    if !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        readingSelection = selection
                    } else {
                        // Only one block holds the selection at a time, so an
                        // empty one means nothing is highlighted anywhere.
                        // Matching the path first left a selection from the
                        // previous block armed, and the Ask button then sent
                        // that stale passage as the question's context.
                        readingSelection = nil
                    }
                },
                textAnnotations: textAnnotations,
                onOpenTextAnnotation: { annotation in
                    _ = onOpenTextAnnotation(annotation)
                },
                onTapTextAnnotations: onTapTextAnnotations.map { decide in
                    { hit in
                        // A live selection's Explore and Ask come first.
                        guard readingSelection == nil else { return }
                        if decide(hit) { presentPassage(hit) }
                    }
                },
                textAnnotationActionName: onTapTextAnnotations == nil ? nil : { cluster, passage in
                    let quoted = passage.count > 40 ? String(passage.prefix(40)) + "…" : passage
                    return cluster.contains { $0.style.isBranch }
                        ? "Explorations from “\(quoted)”"
                        : "Discussion about “\(quoted)”"
                },
                wrapsCodeLines: $wrapsCodeLines,
                initialReadingPosition: initialReadingPosition,
                onReadingPositionChange: onReadingPositionChange.map { report in
                    { position in
                        latestReadingOffset = position.offset
                        if let start = passagePresentation?.readingOffset,
                           abs(position.offset - start) > 24 {
                            passagePresentation = nil
                        }
                        report(position)
                    }
                }
            )
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { canvasFrame = $0 }
        .popover(
            item: $passagePresentation,
            attachmentAnchor: .rect(.rect(passagePresentation?.anchorRect ?? .zero)),
            arrowEdge: passagePresentation?.opensBelow == false ? .bottom : .top
        ) { presentation in
            passageThreadsContent(for: presentation)
        }
        .toolbar {
            #if !targetEnvironment(macCatalyst)
            if !isEditing, onAskAboutPage != nil || explorationStatus != nil {
                ToolbarItemGroup(placement: .bottomBar) {
                    // A live selection's Explore and Ask take the bar; the
                    // status comes back as soon as the selection clears.
                    if let explorationStatus, readingSelection == nil {
                        explorationStatus.menu(.toolbar(compact: dynamicTypeSize.isAccessibilitySize))
                    }
                    Spacer()
                    if let readingSelection, onExploreSelection != nil {
                        Button {
                            exploringSelection = CourseExploreSelectionItem(selection: readingSelection)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.branch")
                                Text("Explore")
                                    .font(.callout.weight(.semibold))
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .accessibilityLabel("Explore this passage")
                        .accessibilityHint("Asks what to explore, then writes a new page from the selected passage")
                        .accessibilityIdentifier("course-page-explore-selection")
                    }
                    if let onAskAboutPage {
                        Button {
                            if let readingSelection {
                                if onAskAboutSelection(readingSelection) != nil {
                                    self.readingSelection = nil
                                }
                            } else {
                                onAskAboutPage()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                if readingSelection != nil {
                                    Text("Ask about this")
                                        .font(.callout.weight(.semibold))
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .animation(.snappy(duration: 0.2), value: readingSelection != nil)
                        }
                        .accessibilityLabel(readingSelection == nil ? "Ask AI about this page" : "Ask about this")
                        .accessibilityHint(readingSelection == nil
                            ? "Opens chat with the current page as context"
                            : "Opens chat with the selected passage as context")
                        .accessibilityIdentifier("course-page-ask-ai")
                    }
                }
            }
            #endif
        }
        #if !targetEnvironment(macCatalyst)
        .sheet(item: $exploringSelection) { item in
            explorePrompt(for: item, isCompact: false)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
        .toolbar {
            #if !targetEnvironment(macCatalyst)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    setEditing(!isEditing)
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                }
                .accessibilityLabel(isEditing ? "Finish editing" : "Edit page")
                .accessibilityHint(
                    isEditing
                        ? "Returns to reading mode"
                        : "Shows page editing controls"
                )
                .accessibilityIdentifier("course-page-edit-toggle")
            }
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("course-page-editor-\(model.pageID)")
    }

    private func explorePrompt(for item: CourseExploreSelectionItem, isCompact: Bool) -> some View {
        let overlap = explorationOverlap?(item.selection) ?? CourseExplorationOverlap()
        return CourseExplorePassagePrompt(
            passage: item.passage,
            isCompact: isCompact,
            alreadyExploredTitles: overlap.titles,
            usedIntents: overlap.usedIntents,
            onSubmit: { question in
                try await onExploreSelection?(item.selection, question)
                // Only close what this prompt opened; the learner may have
                // moved on to another passage meanwhile.
                if exploringSelection?.id == item.id { exploringSelection = nil }
                if readingSelection == item.selection { readingSelection = nil }
                UIAccessibility.post(notification: .announcement, argument: "Exploring. You can keep reading.")
            },
            onCancel: { exploringSelection = nil }
        )
    }

    /// Shows the tapped passage's threads, pointing at the tapped words.
    private func presentPassage(_ hit: NativeBlockEditorAnnotationHit) {
        let anchor = hit.anchorRectInWindow.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
        pendingPassageAction = nil
        passagePresentation = CoursePassagePresentation(
            hit: hit,
            anchorRect: anchor,
            opensBelow: canvasFrame.height <= 0 || anchor.midY < canvasFrame.height * 0.6,
            readingOffset: latestReadingOffset
        )
    }

    @ViewBuilder
    private func passageThreadsContent(for presentation: CoursePassagePresentation) -> some View {
        let usesSheet = dynamicTypeSize.isAccessibilitySize || voiceOverEnabled
        if let passageThreads {
            passageThreads(presentation.hit) { action in
                // Navigation and other presentations wait until this closes.
                pendingPassageAction = action
                passagePresentation = nil
            }
            .presentationCompactAdaptation(usesSheet ? .sheet : .popover)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(usesSheet ? .visible : .hidden)
            .onDisappear(perform: runPendingPassageAction)
        }
    }

    private func runPendingPassageAction() {
        guard let action = pendingPassageAction else { return }
        pendingPassageAction = nil
        switch action {
        case .exploreAgain(let selection):
            exploringSelection = CourseExploreSelectionItem(selection: selection)
        case .ask(let selection):
            _ = onAskAboutSelection(selection)
        case .openExploration, .openDiscussion:
            onPassageAction?(action)
        }
    }

    #if targetEnvironment(macCatalyst)
    private var desktopReaderControls: some View {
        HStack(spacing: 10) {
            if let onToggleOutline {
                Button(action: onToggleOutline) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOutlineVisible ? Color.accentColor : Color.secondary)
                .help(isOutlineVisible ? "Hide course outline" : "Show course outline")
                .accessibilityLabel(isOutlineVisible ? "Hide course outline" : "Show course outline")
                .accessibilityIdentifier("mac-course-toggle-outline")
            }
            if isEditing || (readingSelection == nil && explorationStatus == nil) {
                Text(isEditing ? "Editing" : "Reading")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let explorationStatus {
                explorationStatus.menu(.macHeader)
            }
            Spacer(minLength: 0)

            // Stays while the popover is open: focusing its field can clear
            // the reader's selection, which would otherwise dismiss it.
            if !isEditing, onExploreSelection != nil,
               let selection = exploringSelection?.selection ?? readingSelection {
                Button {
                    exploringSelection = CourseExploreSelectionItem(selection: selection)
                } label: {
                    Label("Explore", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("e", modifiers: [.command])
                .help("Explore this passage (⌘E)")
                .accessibilityLabel("Explore this passage")
                .accessibilityHint("Asks what to explore, then writes a new page from the selected passage")
                .accessibilityIdentifier("course-page-explore-selection")
                .popover(item: $exploringSelection, arrowEdge: .bottom) { item in
                    explorePrompt(for: item, isCompact: true)
                }
            }

            if !isEditing, let onAskAboutPage {
                Button {
                    if let readingSelection {
                        if onAskAboutSelection(readingSelection) != nil {
                            self.readingSelection = nil
                        }
                    } else {
                        onAskAboutPage()
                    }
                } label: {
                    Label(
                        readingSelection == nil ? "Ask AI" : "Ask about this",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(readingSelection == nil ? "Ask AI about this page" : "Ask about this")
                .accessibilityIdentifier("course-page-ask-ai")
            }

            Button {
                setEditing(!isEditing)
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)
            .help(isEditing ? "Finish editing" : "Edit page")
            .accessibilityLabel(isEditing ? "Finish editing" : "Edit page")
            .accessibilityIdentifier("course-page-edit-toggle")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-course-reader-toolbar")
    }
    #endif

    private var displayedSaveState: CoursePageEditorModel.SaveState {
        model.saveState
    }

    /// Courses no longer generate a trailing "Keep asking" section, but pages
    /// written before that change still carry one. Keep hiding it while
    /// reading so those pages do not end in a stray list of questions.
    /// Editing still shows it in place so it can be deleted.
    private var hiddenReadingBlockIDs: Set<UUID> {
        guard !isEditing else { return leadingTitleBlockIDs }
        let followUpIDs = CourseFollowUpQuestions.extract(from: model.document)?.hiddenBlockIDs ?? []
        return leadingTitleBlockIDs.union(followUpIDs).union(additionalHiddenReadingBlockIDs)
    }

    private var leadingTitleBlockIDs: Set<UUID> {
        guard let first = model.document.root.children.first,
              first.type == "heading",
              normalizedTitle(first.delta?.plainText) == normalizedTitle(model.title) else {
            return []
        }
        return [first.id]
    }

    private func normalizedTitle(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            ?? ""
    }

    private func setEditing(_ editing: Bool) {
        readingSelection = nil
        isEditing = editing
        UIAccessibility.post(
            notification: .announcement,
            argument: editing ? "Editing mode" : "Reading mode"
        )
    }

}

#if DEBUG
private struct CourseEditorRuntimeProbeMarker: View {
    let identifier: String
    let label: String
    let value: String

    var body: some View {
        Text(label)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value)
    }
}
#endif

private struct CoursePageSaveStatusView: View {
    let state: CoursePageEditorModel.SaveState
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .saving:
                ProgressView("Saving changes…")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Saving changes")
                    .accessibilityIdentifier("course-page-save-status")
                    .accessibilityValue(state.accessibilityValue)
            case .saved:
                Label("Changes saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Changes saved")
                    .accessibilityIdentifier("course-page-save-status")
                    .accessibilityValue(state.accessibilityValue)
            case let .failed(message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Changes not saved", systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Changes not saved")
                        .accessibilityIdentifier("course-page-save-status")
                        .accessibilityValue(state.accessibilityValue)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("course-page-save-error")
                    Button("Retry save", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Retries saving the pending changes without replacing them.")
                        .accessibilityIdentifier("course-page-save-retry")
                }
            }
        }
        .accessibilityValue(state.accessibilityValue)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
    }
}

enum CoursePageLinkResolver {
    static func pageID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "native-editor",
              url.host?.lowercased() == "page" else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 1 else { return nil }
        let pageID = components[0].removingPercentEncoding ?? components[0]
        return pageID.isEmpty ? nil : pageID
    }
}

enum CourseSelectionAnchorResolver {
    static func reference(
        courseID: String,
        pageID: String,
        pageTitle: String,
        selection: NativeBlockEditorSelection,
        document: BlockDocument
    ) -> CourseTextReference? {
        let selectedText = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty,
              let block = matchingBlock(
                blockID: selection.blockID,
                path: selection.path,
                document: document
              ),
              let range = anchoredRange(
                preferred: selection.range,
                selectedText: selectedText,
                blockText: block.node.delta?.plainText ?? ""
              ) else { return nil }

        return CourseTextReference(
            courseID: courseID,
            pageID: pageID,
            pageTitle: pageTitle,
            blockID: block.node.stableBlockID,
            pathIndices: block.path.indices,
            rangeLocation: range.location,
            rangeLength: range.length,
            selectedText: selectedText
        )
    }

    private static let branchIDPrefix = "exploration:"

    static func branchAnnotation(
        nodeID: String,
        anchor: CourseExplorationAnchor,
        style: NativeBlockEditorTextAnnotation.Style = .branch,
        document: BlockDocument
    ) -> NativeBlockEditorTextAnnotation? {
        guard let block = matchingBlock(
            blockID: anchor.blockID,
            path: BlockPath(anchor.pathIndices),
            document: document
        ), let range = anchoredRange(
            preferred: NSRange(location: anchor.rangeLocation, length: anchor.rangeLength),
            selectedText: anchor.selectedText,
            blockText: block.node.delta?.plainText ?? ""
        ) else { return nil }
        return NativeBlockEditorTextAnnotation(
            id: branchIDPrefix + nodeID,
            blockID: block.node.stableBlockID,
            path: block.path,
            range: range,
            style: style
        )
    }

    static func branchNodeID(of annotation: NativeBlockEditorTextAnnotation) -> String? {
        guard annotation.id.hasPrefix(branchIDPrefix) else { return nil }
        return String(annotation.id.dropFirst(branchIDPrefix.count))
    }

    static func annotation(
        for discussion: CourseSelectionDiscussion,
        document: BlockDocument
    ) -> NativeBlockEditorTextAnnotation? {
        let storedPath = BlockPath(discussion.pathIndices)
        guard let block = matchingBlock(
            blockID: discussion.blockID,
            path: storedPath,
            document: document
        ) else { return nil }
        let preferred = NSRange(
            location: discussion.rangeLocation,
            length: discussion.rangeLength
        )
        guard let range = anchoredRange(
            preferred: preferred,
            selectedText: discussion.selectedText,
            blockText: block.node.delta?.plainText ?? "",
            acceptsSelectedTextPrefix: discussion.wasTruncated
        ) else { return nil }
        return NativeBlockEditorTextAnnotation(
            id: discussion.id.uuidString,
            blockID: block.node.stableBlockID,
            path: block.path,
            range: range
        )
    }

    private static func matchingBlock(
        blockID: String?,
        path: BlockPath,
        document: BlockDocument
    ) -> (path: BlockPath, node: BlockNode)? {
        let blocks = document.flattenedNodes()
        if let blockID,
           let stableMatch = blocks.first(where: { $0.node.stableBlockID == blockID }) {
            return stableMatch
        }
        return blocks.first(where: { $0.path == path })
    }

    private static func anchoredRange(
        preferred: NSRange,
        selectedText: String,
        blockText: String,
        acceptsSelectedTextPrefix: Bool = false
    ) -> NSRange? {
        let block = blockText as NSString
        let selected = selectedText as NSString
        guard selected.length > 0 else { return nil }

        if preferred.location >= 0,
           preferred.length > 0,
           NSMaxRange(preferred) <= block.length {
            let preferredText = block.substring(with: preferred)
            let relativeMatch = (preferredText as NSString).range(of: selectedText)
            if relativeMatch.location != NSNotFound {
                if acceptsSelectedTextPrefix {
                    return preferred
                }
                return NSRange(
                    location: preferred.location + relativeMatch.location,
                    length: relativeMatch.length
                )
            }
        }

        let recovered = block.range(of: selectedText)
        guard recovered.location != NSNotFound else { return nil }
        return NSRange(location: recovered.location, length: selected.length)
    }
}
