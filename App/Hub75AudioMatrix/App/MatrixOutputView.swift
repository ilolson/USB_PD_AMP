import SwiftUI

struct MatrixOutputView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas(opaque: true, colorMode: .linear) { context, size in
                let pixels = model.makeDisplayFrame(now: timeline.date.timeIntervalSinceReferenceDate)
                drawMatrix(pixels: pixels, context: &context, size: size)
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(24)
            .background(Color.black)
        }
    }

    private func drawMatrix(pixels: [RGBPixel], context: inout GraphicsContext, size: CGSize) {
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) * 0.5, y: (size.height - side) * 0.5)
        let pitch = side / 64.0
        let ledSide = max(1.0, pitch * 0.76)
        let inset = (pitch - ledSide) * 0.5

        context.fill(Path(CGRect(origin: origin, size: CGSize(width: side, height: side))),
                     with: .color(Color(red: 0.006, green: 0.007, blue: 0.009)))

        for y in 0..<64 {
            for x in 0..<64 {
                let pixel = pixels[y * 64 + x]
                let rect = CGRect(x: origin.x + CGFloat(x) * pitch + inset,
                                  y: origin.y + CGFloat(y) * pitch + inset,
                                  width: ledSide,
                                  height: ledSide)
                let color = Color(red: Double(clamp(pixel.r)),
                                  green: Double(clamp(pixel.g)),
                                  blue: Double(clamp(pixel.b)))
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }

        let gridColor = Color.white.opacity(0.10)
        for i in 0...64 where i % 8 == 0 {
            let p = origin.x + CGFloat(i) * pitch
            var vertical = Path()
            vertical.move(to: CGPoint(x: p, y: origin.y))
            vertical.addLine(to: CGPoint(x: p, y: origin.y + side))
            context.stroke(vertical, with: .color(gridColor), lineWidth: 1)

            let q = origin.y + CGFloat(i) * pitch
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: origin.x, y: q))
            horizontal.addLine(to: CGPoint(x: origin.x + side, y: q))
            context.stroke(horizontal, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func clamp(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
