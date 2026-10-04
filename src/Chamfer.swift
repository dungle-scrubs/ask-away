import CoreGraphics

/// One chamfer path builder for the whole panel (design.md section 4).
///
/// 45-degree cuts on the top-left and bottom-right corners only; the other
/// two corners stay square. The same builder produces the content mask, the
/// border stroke, the shadow paths, and the button shapes - one cut language.
enum Chamfer {

    /// Path for `rect` with `cut`-point 45-degree cuts at top-left and
    /// bottom-right. `rect` is in AppKit (bottom-left origin) coordinates.
    static func path(cut: CGFloat, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let w = rect.maxX
        let h = rect.maxY
        let minX = rect.minX
        let minY = rect.minY
        path.move(to: CGPoint(x: minX + cut, y: h))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: minY + cut))
        path.addLine(to: CGPoint(x: w - cut, y: minY))
        path.addLine(to: CGPoint(x: minX, y: minY))
        path.addLine(to: CGPoint(x: minX, y: h - cut))
        path.closeSubpath()
        return path
    }

    /// The panel's border path: the chamfer on a rect inset 0.5pt so the 1px
    /// stroke stays pixel-aligned inside the panel at 1x (section 4).
    static func borderPath(cut: CGFloat, in rect: CGRect) -> CGPath {
        path(cut: cut, in: rect.insetBy(dx: 0.5, dy: 0.5))
    }
}
