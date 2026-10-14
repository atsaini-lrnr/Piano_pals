import SwiftUI

/// Shows `content` at `contentSize` inside a `container`, fills it edge to edge, and lets the grown-up pinch to zoom, drag to move
/// and double-tap to reset. Everything inside (picture, hand dots, coaching marks) moves together, so the dots stay on the fingers.
struct PanZoomView<Content: View>: View {
    let contentSize: CGSize
    let container: CGSize
    @ViewBuilder var content: () -> Content

    @State private var scale: CGFloat = 0
    @State private var committedScale: CGFloat = 0
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static var maxZoom: CGFloat { 4 }

    /// Smallest scale that still covers the whole container (no black bars).
    private var minScale: CGFloat { max(1, container.height / max(contentSize.height, 1), container.width / max(contentSize.width, 1)) }
    private var current: CGFloat { min(max(scale == 0 ? minScale : scale, minScale), minScale * Self.maxZoom) }

    private func clamped(_ value: CGSize, scale: CGFloat) -> CGSize {
        let limitX = max(0, (contentSize.width * scale - container.width) / 2)
        let limitY = max(0, (contentSize.height * scale - container.height) / 2)
        return CGSize(width: min(max(value.width, -limitX), limitX), height: min(max(value.height, -limitY), limitY))
    }

    var body: some View {
        let scale = current
        content()
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(scale)
            .offset(clamped(offset, scale: scale))
            .frame(width: container.width, height: container.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { offset = clamped(CGSize(width: committedOffset.width + $0.translation.width, height: committedOffset.height + $0.translation.height), scale: scale) }
                    .onEnded { _ in committedOffset = offset }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { self.scale = min(max((committedScale == 0 ? minScale : committedScale) * $0.magnification, minScale), minScale * Self.maxZoom) }
                        .onEnded { _ in committedScale = self.scale; offset = clamped(offset, scale: self.scale); committedOffset = offset })
            )
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { self.scale = 0; committedScale = 0; offset = .zero; committedOffset = .zero } }
            .accessibilityHint("Pinch to zoom, drag to move, double tap to reset")
    }
}
