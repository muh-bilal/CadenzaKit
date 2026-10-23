import SwiftUI

/// Original, example-owned procedural covers. No artwork is shipped by the SDK.
struct DemoArtwork: View {
    let index: Int
    let title: String
    private var base: Color { [.init(red: 0.025, green: 0.11, blue: 0.14), .init(red: 0.10, green: 0.07, blue: 0.18), .init(red: 0.19, green: 0.06, blue: 0.11), .init(red: 0.025, green: 0.13, blue: 0.08)][index % 4] }
    private var glow: Color { [.init(red: 0.98, green: 0.76, blue: 0.40), .init(red: 0.65, green: 0.91, blue: 0.30), .init(red: 0.35, green: 0.84, blue: 0.82), .init(red: 0.96, green: 0.48, blue: 0.68)][index % 4] }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                base
                RadialGradient(colors: [glow, glow.opacity(0.45), Color(red: 0.28, green: 0.49, blue: 0.43).opacity(0.4), base], center: .init(x: 0.50, y: 0.39), startRadius: 0, endRadius: size * 0.49)
                ForEach(0..<3) { ring in
                    Ellipse().strokeBorder(.white.opacity(0.12 - Double(ring) * 0.025), lineWidth: size * 0.018)
                        .frame(width: size * (0.42 + Double(ring) * 0.07), height: size * (0.66 + Double(ring) * 0.02))
                        .rotationEffect(.degrees(-28)).offset(y: -size * 0.04)
                }
                Text(title.uppercased()).font(.system(size: size * 0.075, weight: .regular))
                    .tracking(size * 0.008).foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(size * 0.08)
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}
