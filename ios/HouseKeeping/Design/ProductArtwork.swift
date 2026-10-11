import SwiftUI

/// Original vector illustrations for the design prototype; no purchase photos are bundled.
struct ProductArtwork: View {
    let kind: Artwork

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 300, size.height / 220)
            context.translateBy(x: (size.width - 300 * scale) / 2, y: (size.height - 220 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(
                Path(ellipseIn: CGRect(x: 64, y: 184, width: 180, height: 12)), with: .color(.black.opacity(0.07)))
            switch kind {
            case .kettle: drawKettle(in: &context)
            case .lamp: drawLamp(in: &context)
            case .cups: drawCups(in: &context)
            case .plant: drawPlant(in: &context)
            case .none: break
            }
        }
        .background(background.gradient)
        .overlay {
            if kind == .none {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(Palette.secondary)
            }
        }
        .compositingGroup()
        .clipShape(.rect(cornerRadius: 20))
        .accessibilityHidden(true)
    }

    private var background: Color {
        switch kind {
        case .kettle: Color(red: 0.89, green: 0.88, blue: 0.83)
        case .lamp: Color(red: 0.91, green: 0.85, blue: 0.76)
        case .cups: Color(red: 0.87, green: 0.88, blue: 0.82)
        case .plant: Color(red: 0.89, green: 0.85, blue: 0.79)
        case .none: Palette.sage
        }
    }

    private func drawKettle(in context: inout GraphicsContext) {
        let charcoal = Color(red: 0.15, green: 0.18, blue: 0.17)
        var handle = Path()
        handle.move(to: CGPoint(x: 182, y: 73))
        handle.addCurve(
            to: CGPoint(x: 197, y: 157), control1: CGPoint(x: 264, y: 45), control2: CGPoint(x: 257, y: 136))
        context.stroke(
            handle, with: .color(Color(red: 0.57, green: 0.39, blue: 0.24)),
            style: StrokeStyle(lineWidth: 14, lineCap: .round))
        var spout = Path()
        spout.move(to: CGPoint(x: 118, y: 158))
        spout.addCurve(to: CGPoint(x: 54, y: 80), control1: CGPoint(x: 62, y: 155), control2: CGPoint(x: 91, y: 89))
        spout.addLine(to: CGPoint(x: 67, y: 77))
        spout.addCurve(to: CGPoint(x: 126, y: 126), control1: CGPoint(x: 100, y: 115), control2: CGPoint(x: 90, y: 117))
        spout.closeSubpath()
        context.fill(spout, with: .color(charcoal))
        var body = Path()
        body.move(to: CGPoint(x: 120, y: 74))
        body.addQuadCurve(to: CGPoint(x: 104, y: 174), control: CGPoint(x: 100, y: 123))
        body.addQuadCurve(to: CGPoint(x: 199, y: 174), control: CGPoint(x: 150, y: 198))
        body.addQuadCurve(to: CGPoint(x: 184, y: 74), control: CGPoint(x: 210, y: 127))
        body.closeSubpath()
        context.fill(
            body,
            with: .linearGradient(
                Gradient(colors: [charcoal, Color(red: 0.29, green: 0.32, blue: 0.29), charcoal]),
                startPoint: CGPoint(x: 100, y: 100), endPoint: CGPoint(x: 200, y: 130)))
        context.fill(Path(ellipseIn: CGRect(x: 118, y: 65, width: 69, height: 16)), with: .color(charcoal))
        context.fill(
            Path(roundedRect: CGRect(x: 142, y: 54, width: 19, height: 14), cornerRadius: 6),
            with: .color(Color(red: 0.64, green: 0.46, blue: 0.3)))
        context.fill(
            Path(roundedRect: CGRect(x: 103, y: 180, width: 99, height: 9), cornerRadius: 4), with: .color(charcoal))
    }

    private func drawLamp(in context: inout GraphicsContext) {
        let brown = Color(red: 0.42, green: 0.29, blue: 0.2)
        context.fill(
            Path(roundedRect: CGRect(x: 142, y: 93, width: 15, height: 89), cornerRadius: 5), with: .color(brown))
        context.fill(Path(ellipseIn: CGRect(x: 106, y: 175, width: 87, height: 15)), with: .color(brown))
        var shade = Path()
        shade.move(to: CGPoint(x: 112, y: 39))
        shade.addLine(to: CGPoint(x: 187, y: 39))
        shade.addLine(to: CGPoint(x: 216, y: 119))
        shade.addQuadCurve(to: CGPoint(x: 83, y: 119), control: CGPoint(x: 150, y: 132))
        shade.closeSubpath()
        context.fill(
            shade,
            with: .linearGradient(
                Gradient(colors: [.white, Color(red: 0.85, green: 0.8, blue: 0.66)]), startPoint: CGPoint(x: 90, y: 65),
                endPoint: CGPoint(x: 210, y: 110)))
        context.fill(
            Path(ellipseIn: CGRect(x: 112, y: 34, width: 75, height: 10)),
            with: .color(Color(red: 0.79, green: 0.73, blue: 0.6)))
    }

    private func drawCups(in context: inout GraphicsContext) {
        drawCup(in: &context, x: 76, y: 81, color: Color(red: 0.96, green: 0.93, blue: 0.84))
        drawCup(in: &context, x: 153, y: 110, color: Color(red: 0.72, green: 0.77, blue: 0.65))
    }

    private func drawCup(in context: inout GraphicsContext, x: CGFloat, y: CGFloat, color: Color) {
        context.stroke(
            Path(ellipseIn: CGRect(x: x + 48, y: y + 15, width: 39, height: 40)), with: .color(color), lineWidth: 9)
        context.fill(
            Path(roundedRect: CGRect(x: x, y: y, width: 64, height: 76), cornerRadius: 18), with: .color(color))
        context.fill(Path(ellipseIn: CGRect(x: x, y: y - 5, width: 64, height: 18)), with: .color(color))
        context.fill(
            Path(ellipseIn: CGRect(x: x + 6, y: y - 1, width: 52, height: 10)),
            with: .color(Color(red: 0.32, green: 0.25, blue: 0.2)))
    }

    private func drawPlant(in context: inout GraphicsContext) {
        context.stroke(Path(CGRect(x: 148, y: 40, width: 2, height: 106)), with: .color(.brown), lineWidth: 3)
        for point in [CGPoint(x: 120, y: 48), CGPoint(x: 153, y: 65), CGPoint(x: 115, y: 82), CGPoint(x: 152, y: 101)] {
            context.fill(
                Path(ellipseIn: CGRect(origin: point, size: CGSize(width: 33, height: 19))),
                with: .color(Color(red: 0.32, green: 0.43, blue: 0.28)))
        }
        var pot = Path()
        pot.move(to: CGPoint(x: 108, y: 133))
        pot.addLine(to: CGPoint(x: 192, y: 133))
        pot.addLine(to: CGPoint(x: 180, y: 186))
        pot.addQuadCurve(to: CGPoint(x: 120, y: 186), control: CGPoint(x: 150, y: 196))
        pot.closeSubpath()
        context.fill(
            pot,
            with: .linearGradient(
                Gradient(colors: [Color(red: 0.78, green: 0.5, blue: 0.35), Color(red: 0.64, green: 0.36, blue: 0.26)]),
                startPoint: CGPoint(x: 100, y: 130), endPoint: CGPoint(x: 195, y: 180)))
        context.fill(
            Path(ellipseIn: CGRect(x: 105, y: 126, width: 90, height: 16)),
            with: .color(Color(red: 0.48, green: 0.3, blue: 0.21)))
    }
}
