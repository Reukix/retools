import UIKit

public enum FloatingDragAxis: Equatable {
    case undecided, horizontal, vertical
    public mutating func lock(to translation: CGSize) {
        guard self == .undecided, max(abs(translation.width), abs(translation.height)) >= 5 else { return }
        self = abs(translation.width) > abs(translation.height) ? .horizontal : .vertical
    }
}

public enum FloatingControlGeometry {
    public static let diameter: CGFloat = 48
    public static func clamp(_ point: CGPoint, size: CGSize, insets: UIEdgeInsets) -> CGPoint {
        let radius = diameter / 2, margin: CGFloat = 10
        let minX = insets.left + margin + radius, minY = insets.top + margin + 38
        let maxX = max(minX, size.width - insets.right - margin - radius)
        let maxY = max(minY, size.height - insets.bottom - margin - 38)
        return CGPoint(x: min(max(point.x, minX), maxX), y: min(max(point.y, minY), maxY))
    }
    public static func snap(_ point: CGPoint, size: CGSize, insets: UIEdgeInsets) -> CGPoint {
        clamp(CGPoint(x: point.x < size.width / 2 ? 0 : size.width, y: point.y), size: size, insets: insets)
    }
    public static func dockFrame(center: CGPoint, size: CGSize, insets: UIEdgeInsets, appCount: Int) -> CGRect {
        let width: CGFloat = 72, edgeInset: CGFloat = 8
        let available = max(1, size.height - insets.top - insets.bottom - 20)
        let height = min(available, min(5.25, CGFloat(max(1, appCount))) * 60 + 88)
        let x = center.x < size.width / 2 ? insets.left + edgeInset : max(insets.left + edgeInset, size.width - insets.right - width - edgeInset)
        let y = min(max(center.y - height / 2, insets.top + 10), max(insets.top + 10, size.height - insets.bottom - height - 10))
        return CGRect(x: x, y: y, width: width, height: height)
    }
    public static func tabFrame(center: CGPoint, size: CGSize, insets: UIEdgeInsets) -> CGRect {
        CGRect(x: center.x < size.width / 2 ? insets.left : max(insets.left, size.width - insets.right - 44), y: center.y - 38, width: 44, height: 76)
    }
    public static func hit(_ point: CGPoint, center: CGPoint, expanded: Bool, bounds: CGRect, dockFrame: CGRect? = nil) -> Bool {
        expanded ? (dockFrame ?? bounds).contains(point) : CGRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56).contains(point)
    }
}
