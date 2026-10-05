#if os(iOS)
import SwiftUI

/// Host-owned viewport state. This never changes the document or its undo history.
public struct NativeBlockEditorReadingPosition: Equatable, Sendable {
    public var offset: Double
    public var isAtEnd: Bool

    public init(offset: Double = 0, isAtEnd: Bool = false) {
        self.offset = offset.isFinite ? max(0, offset) : 0
        self.isAtEnd = isAtEnd
    }
}

struct NativeBlockEditorReadingModifier: ViewModifier {
    let initialPosition: NativeBlockEditorReadingPosition?
    let onChange: ((NativeBlockEditorReadingPosition) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let onChange {
            content.modifier(ReadingScrollModifier(initialPosition: initialPosition, onChange: onChange))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct ReadingScrollModifier: ViewModifier {
    let initialPosition: NativeBlockEditorReadingPosition?
    let onChange: (NativeBlockEditorReadingPosition) -> Void
    @State private var position = ScrollPosition()
    @State private var restored = false
    @State private var userHasScrolled = false
    /// Latest viewport, held outside view state so scrolling never re-renders.
    @State private var latest = LatestGeometry()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    userHasScrolled = true
                } else if phase == .idle {
                    report()
                }
            }
            .onScrollGeometryChange(for: ReadingGeometry.self) { geometry in
                ReadingGeometry(
                    offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                    extent: max(0, geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom - geometry.containerSize.height),
                    height: geometry.containerSize.height
                )
            } action: { _, geometry in
                guard geometry.height > 0 else { return }
                latest.value = geometry
                if !restored {
                    restored = true
                    if let initialPosition {
                        if initialPosition.isAtEnd {
                            position.scrollTo(edge: .bottom)
                        } else {
                            position.scrollTo(y: min(initialPosition.offset, geometry.extent))
                        }
                    }
                }
            }
            .onDisappear { report() }
    }

    /// Hosts persist the position, so it is reported once a scroll settles
    /// (or the reader leaves) rather than on every frame of the gesture.
    private func report() {
        guard userHasScrolled, let geometry = latest.value else { return }
        onChange(NativeBlockEditorReadingPosition(
            offset: geometry.offset,
            isAtEnd: geometry.offset >= geometry.extent - 24
        ))
    }

    private struct ReadingGeometry: Equatable {
        let offset: Double
        let extent: Double
        let height: Double
    }

    private final class LatestGeometry {
        var value: ReadingGeometry?
    }
}
#endif
