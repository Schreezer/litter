#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

extension Notification.Name {
    static let learnfoldCommandNewCourse = Notification.Name("com.learnfold.command.newCourse")
    static let learnfoldCommandShowLibrary = Notification.Name("com.learnfold.command.showLibrary")
    static let learnfoldCommandShowAppSettings = Notification.Name("com.learnfold.command.showAppSettings")
    static let learnfoldCommandSendCourseMessage = Notification.Name("com.learnfold.command.sendCourseMessage")
    static let learnfoldCommandNavigateBack = Notification.Name("com.learnfold.command.navigateBack")
    static let learnfoldCommandNavigateForward = Notification.Name("com.learnfold.command.navigateForward")
    /// Posted with userInfo `["index": Int]` in the visible course library order.
    static let learnfoldCommandSelectCourse = Notification.Name("com.learnfold.command.selectCourse")

    static let litterCommandNewSession = Notification.Name("com.litter.command.newSession")
    static let litterCommandSendComposer = Notification.Name("com.litter.command.sendComposer")
    static let litterCommandNavigateBack = Notification.Name("com.litter.command.navigateBack")
    static let litterCommandNavigateForward = Notification.Name("com.litter.command.navigateForward")
    /// Posted with userInfo `["index": Int]` where `index` is 0-based.
    static let litterCommandSelectSession = Notification.Name("com.litter.command.selectSession")
    static let litterCommandShowSettings = Notification.Name("com.litter.command.showSettings")
}

private struct LearnfoldCourseStoreFocusedKey: FocusedValueKey {
    typealias Value = CourseExperienceStore
}

extension FocusedValues {
    var learnfoldCourseStore: CourseExperienceStore? {
        get { self[LearnfoldCourseStoreFocusedKey.self] }
        set { self[LearnfoldCourseStoreFocusedKey.self] = newValue }
    }
}

struct LitterCommands: Commands {
    @FocusedValue(\.learnfoldCourseStore) private var courseStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Course") {
                NotificationCenter.default.post(name: .learnfoldCommandNewCourse, object: courseStore)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(courseStore?.setupComplete != true)

            Button("New Window") {
                openNewWindow()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .learnfoldCommandShowAppSettings, object: courseStore)
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(courseStore == nil)
        }

        CommandMenu("Course") {
            Button("Course Library") {
                NotificationCenter.default.post(name: .learnfoldCommandShowLibrary, object: courseStore)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(courseStore?.setupComplete != true)

            Button("Send Message") {
                NotificationCenter.default.post(name: .learnfoldCommandSendCourseMessage, object: courseStore)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(courseStore?.setupComplete != true)

            Button("Back") {
                NotificationCenter.default.post(name: .learnfoldCommandNavigateBack, object: courseStore)
            }
            .keyboardShortcut("[", modifiers: [.command])

            Button("Forward") {
                NotificationCenter.default.post(name: .learnfoldCommandNavigateForward, object: courseStore)
            }
            .keyboardShortcut("]", modifiers: [.command])

            Divider()

            CourseShortcutsMenu(courseStore: courseStore)
        }
    }
}

private struct CourseShortcutsMenu: View {
    let courseStore: CourseExperienceStore?

    var body: some View {
        let courses = courseStore?.courses ?? []
        ForEach(0..<9, id: \.self) { index in
            let shortcutKey = KeyEquivalent(Character("\(index + 1)"))
            let course = courses.indices.contains(index) ? courses[index] : nil
            Button(course.map { "Course \(index + 1): \($0.title)" } ?? "Course \(index + 1)") {
                NotificationCenter.default.post(
                    name: .learnfoldCommandSelectCourse,
                    object: courseStore,
                    userInfo: ["index": index]
                )
            }
            .keyboardShortcut(shortcutKey, modifiers: [.command])
            .disabled(course == nil || courseStore?.setupComplete != true)
        }
    }
}

@MainActor
private func openNewWindow() {
    UIApplication.shared.requestSceneSessionActivation(
        nil,
        userActivity: nil,
        options: nil,
        errorHandler: { error in
            LLog.error("multiwindow", "open failed", error: error)
        }
    )
}

/// Catalyst window setup: keeps the underlying NSWindow opaque (so the
/// desktop can't bleed through sidebar Liquid Glass), installs a
/// compact unified titlebar with an NSToolbar carrying the settings
/// button next to the traffic lights, and declares the window's
/// resize bounds.
struct MacWindowTitleBarStyler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = SceneConfigView()
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class SceneConfigView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Force the Catalyst UIWindow opaque so the desktop can't
            // bleed through NavigationSplitView's sidebar Liquid Glass
            // material. Paint black behind SwiftUI so any remaining
            // translucency still resolves to a dark surface, not the
            // Mac desktop.
            if let window {
                window.isOpaque = true
                window.backgroundColor = .black
            }

            DispatchQueue.main.async { [weak self] in
                guard let windowScene = self?.window?.windowScene else { return }
                if let titlebar = windowScene.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
                let restrictions = windowScene.sizeRestrictions
                restrictions?.minimumSize = CGSize(width: 760, height: 560)
                restrictions?.maximumSize = CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
        }
    }
}
#endif
