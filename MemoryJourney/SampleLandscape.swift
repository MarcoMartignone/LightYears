import SwiftUI

/// Original code-drawn placeholder art. No photographs or external assets.
struct SampleLandscape: View {
    let scene: Int
    private var palettes: [[Color]] {
        [
            [Color(red: 0.78, green: 0.55, blue: 0.39), Color(red: 0.29, green: 0.43, blue: 0.47), Color(red: 0.07, green: 0.24, blue: 0.30)],
            [Color(red: 0.51, green: 0.61, blue: 0.67), Color(red: 0.22, green: 0.34, blue: 0.36), Color(red: 0.10, green: 0.22, blue: 0.24)],
            [Color(red: 0.78, green: 0.49, blue: 0.37), Color(red: 0.50, green: 0.34, blue: 0.34), Color(red: 0.19, green: 0.25, blue: 0.30)],
            [Color(red: 0.64, green: 0.68, blue: 0.61), Color(red: 0.28, green: 0.43, blue: 0.40), Color(red: 0.10, green: 0.27, blue: 0.27)]
        ]
    }
    var body: some View {
        GeometryReader { geometry in
            let colors = palettes[scene % palettes.count]
            ZStack {
                LinearGradient(colors: [colors[0], colors[1]], startPoint: .top, endPoint: .bottom)
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    let sun = CGRect(x: w * 0.65, y: h * 0.18, width: w * 0.16, height: w * 0.16)
                    context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.85, blue: 0.62).opacity(0.8)))
                    for layer in 0..<3 {
                        var ridge = Path()
                        let baseline = h * (0.43 + Double(layer) * 0.16)
                        ridge.move(to: CGPoint(x: 0, y: baseline))
                        if scene == 1 {
                            ridge.addLines([
                                CGPoint(x: w * 0.23, y: baseline - h * 0.21),
                                CGPoint(x: w * 0.45, y: baseline + h * 0.03),
                                CGPoint(x: w * 0.70, y: baseline - h * 0.28),
                                CGPoint(x: w, y: baseline + h * 0.02)
                            ])
                        } else {
                            ridge.addCurve(to: CGPoint(x: w, y: baseline + h * 0.12),
                                           control1: CGPoint(x: w * 0.35, y: baseline - h * 0.22),
                                           control2: CGPoint(x: w * 0.60, y: baseline + h * 0.25))
                        }
                        ridge.addLine(to: CGPoint(x: w, y: h))
                        ridge.addLine(to: CGPoint(x: 0, y: h))
                        ridge.closeSubpath()
                        context.fill(ridge, with: .color(colors[min(layer, 2)].opacity(layer == 0 ? 0.5 : 1)))
                    }
                    if scene != 1 {
                        for index in 0..<14 {
                            let y = h * (0.60 + Double(index) * 0.028)
                            let width = w * (0.08 + Double(index) * 0.017)
                            let x = w * 0.70 - width / 2
                            var reflection = Path()
                            reflection.move(to: CGPoint(x: x, y: y))
                            reflection.addLine(to: CGPoint(x: x + width, y: y))
                            context.stroke(reflection, with: .color(.white.opacity(0.10)), lineWidth: 1.5)
                        }
                    }
                }
                LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .center, endPoint: .bottom)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
}
