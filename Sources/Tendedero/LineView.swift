import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    /// Where the line hangs: across the top of the screen, or down its left
    /// or right edge. The photos stay upright in all three; only the clip
    /// turns, and the rope bends into the screen on the sides.
    enum Position: String, CaseIterable {
        case top, left, right

        var isSide: Bool { self != .top }

        /// How far the clip turns so its mouth faces the photo.
        var clipAngle: Double {
            switch self {
            case .top: 0
            case .left: -90
            case .right: 90
            }
        }

        var label: String {
            switch self {
            case .top: L("Top")
            case .left: L("Left")
            case .right: L("Right")
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    /// Left out of the box: a wide screen has more room along the side than
    /// across the top.
    static var position: Position {
        get {
            Position(rawValue: UserDefaults.standard.string(forKey: "clotheslinePosition") ?? "") ?? .left
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "clotheslinePosition") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    /// Photos hang `spacing` apart along the rope.
    static var spacing: CGFloat { cardWidth + 24 }
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5
    /// The tallest a card gets, clip included, as it hangs.
    static var maxCardHeight: CGFloat { photoMaxHeight + Frame.inset * 2 }
    /// A photo down the side needs less room than one across the top.
    static var sideSpacing: CGFloat { maxCardHeight + 20 }
    /// The strip along a side edge: the rope, the clip and a card.
    static var sideWidth: CGFloat { cardWidth + 24 }
    /// A card down the side starts this far in from the rope, with the clip
    /// overlapping it by the same 12 points as on the top version.
    static let sideCardInset: CGFloat = 14
    /// The clip and the card side by side, without the overlap.
    static var sideViewWidth: CGFloat { cardWidth + sideCardInset }

    /// How thick the panel is, across the rope.
    static var thickness: CGFloat { position.isSide ? sideWidth : panelHeight }

    /// How far apart photos hang, along the rope.
    static var alongSpacing: CGFloat { position.isSide ? sideSpacing : spacing }

    /// The rope hangs as a parabola from edge to edge of the screen, and
    /// down the sides it bends into the screen the same way.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    /// How far the rope is from the edge it starts at, `u` points along it.
    static func ropeOffset(_ u: CGFloat, length: CGFloat) -> CGFloat {
        guard length > 0 else { return ropeTop }
        let f = u / length
        return ropeTop + 4 * sag(width: length) * f * (1 - f)
    }

    /// A point on the rope in the panel's own coordinates. `u` runs along
    /// the rope, from the top of the screen on the sides.
    static func ropePoint(_ u: CGFloat, length: CGFloat) -> CGPoint {
        let offset = ropeOffset(u, length: length)
        switch position {
        case .top: return CGPoint(x: u, y: offset)
        case .left: return CGPoint(x: offset, y: u)
        case .right: return CGPoint(x: sideWidth - offset, y: u)
        }
    }

    /// The control point of the rope's parabola, twice as far out as the
    /// rope dips at its middle.
    static func ropeControlPoint(length: CGFloat) -> CGPoint {
        let offset = ropeTop + 2 * sag(width: length)
        switch position {
        case .top: return CGPoint(x: length / 2, y: offset)
        case .left: return CGPoint(x: offset, y: length / 2)
        case .right: return CGPoint(x: sideWidth - offset, y: length / 2)
        }
    }

    /// Photos hang `alongSpacing` apart, centred. When there are more than
    /// the `visible` that fit: with Keep on line set, they keep their spacing,
    /// the newest stays where the last one would hang on a full line, and
    /// `scroll` brings older ones in from the start. Otherwise (a line hung
    /// along a longer screen) they move closer together so none is past the
    /// edge.
    static func along(index: Int, count: Int, length: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        if Line.keepOnLine != nil && count > visible {
            let newest = length / 2 + CGFloat(visible - 1) * alongSpacing / 2
            return newest - CGFloat(count - 1 - index) * alongSpacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(alongSpacing, max(0, length - 200) / gaps) : alongSpacing
        return length / 2 - gaps * step / 2 + CGFloat(index) * step
    }

    /// Where a card hangs inside the panel, in the panel's own coordinates.
    /// The panel and the views use the same one, so a capture can fly exactly
    /// to its place.
    static func cardRect(index: Int, count: Int, visible: Int, scroll: CGFloat,
                         size: CGSize, panelLength: CGFloat) -> CGRect {
        let u = along(index: index, count: count, length: panelLength, visible: visible, scroll: scroll)
        let rope = ropePoint(u, length: panelLength)
        switch position {
        case .top:
            let top = rope.y - pinAbove + PeggedView.cardOffsetBelowTop
            return CGRect(x: u - size.width / 2, y: top, width: size.width, height: size.height)
        case .left:
            return CGRect(x: rope.x + sideCardInset, y: u - size.height / 2,
                          width: size.width, height: size.height)
        case .right:
            return CGRect(x: rope.x - sideCardInset - size.width, y: u - size.height / 2,
                          width: size.width, height: size.height)
        }
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let position = Layout.position
            let length = position.isSide ? geo.size.height : geo.size.width

            ZStack(alignment: .topLeading) {
                Rope(length: length, position: position)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)

                if line.items.isEmpty {
                    Hint(text: L("Take a screenshot and it will hang here"))
                        .frame(width: position.isSide ? Layout.sideWidth - 28 : nil)
                        .position(x: position.isSide ? geo.size.width / 2 : length / 2,
                                  y: position.isSide ? length / 2
                                     : Layout.ropeOffset(length / 2, length: length) + 34)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let u = Layout.along(index: index, count: line.items.count, length: length,
                                         visible: line.visibleCount, scroll: line.scroll)
                    let rope = Layout.ropePoint(u, length: length)
                    // Photos scrolled towards an end fade out before they reach it.
                    let fade = min(1, max(0, min(u, length - u) / 90))

                    if position.isSide {
                        PeggedView(item: item, line: line)
                            .frame(width: Layout.sideViewWidth, height: Layout.maxCardHeight,
                                   alignment: position == .left ? .leading : .trailing)
                            .opacity(fade)
                            .position(x: position == .left ? rope.x + Layout.sideViewWidth / 2
                                                          : rope.x - Layout.sideViewWidth / 2,
                                      y: u)
                    } else {
                        let height = Layout.panelHeight - rope.y
                        PeggedView(item: item, line: line)
                            .frame(width: Layout.cardWidth, height: height, alignment: .top)
                            .opacity(fade)
                            .position(x: u, y: rope.y - Layout.pinAbove + height / 2)
                    }
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits outside the edge and slides
            // in, the way an auto-hiding Dock does.
            .offset(x: hiddenX(position), y: hiddenY(position))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }

    private func hiddenX(_ position: Layout.Position) -> CGFloat {
        guard !line.revealed, position.isSide else { return 0 }
        return position == .right ? Layout.sideWidth + 12 : -(Layout.sideWidth + 12)
    }

    private func hiddenY(_ position: Layout.Position) -> CGFloat {
        guard !line.revealed, !position.isSide else { return 0 }
        return -(Layout.panelHeight + 12)
    }
}

private struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let length: CGFloat
    let position: Layout.Position

    private var path: Path {
        Path { p in
            p.move(to: Layout.ropePoint(-20, length: length))
            p.addQuadCurve(to: Layout.ropePoint(length + 20, length: length),
                           control: Layout.ropeControlPoint(length: length))
        }
    }

    private var fade: LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.92),
            .init(color: .clear, location: 1),
        ], startPoint: position.isSide ? .top : .leading,
           endPoint: position.isSide ? .bottom : .trailing)
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(fade)
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
