import NativeBlockEditorCore
import SwiftUI
import UIKit
import XCTest
@testable import NativeBlockEditorUI

@MainActor
final class RichTextAppearanceTests: XCTestCase {
    func testReadOnlyTextFollowsWindowAppearanceWithoutChangingDocument() async throws {
        let delta = TextDelta([
            .insert("Default text. "),
            .insert("Custom color.", attributes: ["font_color": "#2864DC"]),
        ])
        var edits = 0
        let editor = makeEditor(delta: delta) { _ in edits += 1 }
        let controller = UIHostingController(rootView: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        await Task.yield()
        controller.view.layoutIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        let selection = NSRange(location: 2, length: 5)
        textView.selectedRange = selection

        for appearance in [UIUserInterfaceStyle.dark, .light, .dark] {
            window.overrideUserInterfaceStyle = appearance
            window.layoutIfNeeded()
            await Task.yield()
            textView.layoutIfNeeded()

            XCTAssertEqual(textView.traitCollection.userInterfaceStyle, appearance)
            let color = try XCTUnwrap(textView.attributedText.attribute(
                .foregroundColor, at: 0, effectiveRange: nil
            ) as? UIColor)
            XCTAssertTrue(color.isEqual(UIColor.label.resolvedColor(with: textView.traitCollection)))
            let customColor = try XCTUnwrap(textView.attributedText.attribute(
                .foregroundColor, at: 14, effectiveRange: nil
            ) as? UIColor)
            XCTAssertTrue(customColor.isEqual(UIColor(red: 40 / 255, green: 100 / 255, blue: 220 / 255, alpha: 1)))
            XCTAssertEqual(RichTextCodec.delta(from: textView.attributedText), delta.normalized())
            XCTAssertEqual(textView.selectedRange, selection)
            XCTAssertFalse(textView.isEditable)
            XCTAssertEqual(edits, 0, "Appearance must not persist an edit to the course")
        }
    }

    func testAppearanceRefreshPreservesTextNewerThanSwiftUISnapshot() {
        var edits = 0
        let editor = makeEditor(delta: TextDelta([.insert("Older snapshot")])) { _ in edits += 1 }
        let coordinator = editor.makeCoordinator()
        let textView = UITextView()
        textView.overrideUserInterfaceStyle = .dark
        let current = TextDelta([.insert("My latest note", attributes: ["bold": true])])
        textView.attributedText = RichTextCodec.attributedString(
            from: current, style: .style(for: .paragraph())
        )
        textView.selectedRange = NSRange(location: 3, length: 6)

        coordinator.refreshAppearance(in: textView)

        XCTAssertEqual(RichTextCodec.delta(from: textView.attributedText), current.normalized())
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 6))
        XCTAssertEqual(edits, 0)
    }

    func testReadingSelectionSurvivesRefreshAndExtendsToWholeParagraph() async throws {
        let text = "Imagine learning a short recipe. You could reread the steps with the recipe open. Or close it and describe the steps from memory."
        let delta = TextDelta([.insert(text)])
        var edits = 0
        let controller = UIHostingController(rootView: makeEditor(delta: delta) { _ in edits += 1 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        controller.view.layoutIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: controller.view))
        XCTAssertTrue(textView.becomeFirstResponder())

        for length in [7, 60, text.utf16.count] {
            let range = NSRange(location: 0, length: length)
            textView.selectedRange = range
            var refreshed = makeEditor(delta: delta) { _ in edits += 1 }
            // A changed accessibility label forces updateUIView, as a host's
            // selection-button or reading-bookmark update does in production.
            refreshed = RichTextBlockEditor(
                delta: refreshed.delta, path: refreshed.path, textStyle: refreshed.textStyle,
                accessibilityLabel: "Refresh \(length)", accessibilityIdentifier: "appearance-test",
                session: refreshed.session, isEditable: false, onDeltaChange: refreshed.onDeltaChange,
                splitsOnReturn: true, focusRequestID: nil, focusRequestOffset: 0,
                onFocusRequestHandled: {}, onReturn: { _ in }, onDeleteBackwardAtEmpty: {},
                onCopy: { _ in false }, onCut: { _ in false }, onPaste: { _ in false },
                onOpenURL: { _ in false }, onAskAboutSelection: { _, _ in },
                annotations: [], onTapAnnotations: { _ in }, annotationActionName: nil,
                onSelectionChange: { _ in }
            )
            controller.rootView = refreshed
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(textView.accessibilityLabel, "Refresh \(length)")
            XCTAssertTrue(textView.isFirstResponder, "Reader refresh must preserve selection focus")
            XCTAssertEqual(textView.selectedRange, range)
        }
        XCTAssertEqual(RichTextCodec.delta(from: textView.attributedText), delta.normalized())
        XCTAssertFalse(textView.isEditable)
        XCTAssertEqual(edits, 0)
    }

    private func makeEditor(delta: TextDelta, onChange: @escaping (TextDelta) -> Void) -> RichTextBlockEditor {
        RichTextBlockEditor(
            delta: delta, path: BlockPath([0]), textStyle: .style(for: .paragraph()),
            accessibilityLabel: "Paragraph", accessibilityIdentifier: "appearance-test",
            session: RichTextEditingSession(), isEditable: false, onDeltaChange: onChange,
            splitsOnReturn: true, focusRequestID: nil, focusRequestOffset: 0,
            onFocusRequestHandled: {}, onReturn: { _ in }, onDeleteBackwardAtEmpty: {},
            onCopy: { _ in false }, onCut: { _ in false }, onPaste: { _ in false },
            onOpenURL: { _ in false }, onAskAboutSelection: { _, _ in },
            annotations: [], onTapAnnotations: { _ in }, annotationActionName: nil,
                onSelectionChange: { _ in }
        )
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}
