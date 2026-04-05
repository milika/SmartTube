import SwiftUI

// MARK: - ScrollOffsetPreferenceKey

/// Reports the current vertical scroll offset from inside a `ScrollView`.
/// Use by placing a zero-height `GeometryReader` inside the ScrollView's content and
/// reading changes via `.onPreferenceChange(ScrollOffsetPreferenceKey.self)`.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - ScrollOffsetRestorer

/// A zero-size `UIViewRepresentable` that restores the scrollable offset of the nearest
/// ancestor `UIScrollView` once, then calls `onComplete`.
///
/// Always keep this view in the content (don't add/remove conditionally — that would
/// trigger a layout recalculation that resets `contentOffset`). Pass `nil` when no
/// restore is needed; the view becomes a no-op.
///
/// ```swift
/// // In the ScrollView content (unconditionally):
/// ScrollOffsetRestorer(targetOffset: restoreOffset) { restoreOffset = nil }
///     .frame(width: 0, height: 0)
/// ```
struct ScrollOffsetRestorer: UIViewRepresentable {
    /// Desired `contentOffset.y`. Pass `nil` to do nothing.
    let targetOffset: CGFloat?
    let onComplete: () -> Void

    func makeUIView(context: Context) -> UIView {
        UIView()  // zero-size, hidden
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let offset = targetOffset else { return }
        // Defer past the current SwiftUI layout commit AND any UIKit navigation
        // pop animation, so contentSize is finalised and contentOffset is stable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            var current: UIView? = uiView.superview
            while let view = current {
                if let sv = view as? UIScrollView {
                    // With a VStack (all items rendered) contentSize is already full;
                    // no clamping needed — but guard against negative offset.
                    let y = max(offset, 0)
                    sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    self.onComplete()
                    return
                }
                current = view.superview
            }
        }
    }
}
