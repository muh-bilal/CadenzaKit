import SwiftUI
import CadenzaDomain

/// Pure presentation of measured levels. The host owns sampling and visibility.
/// Reduce Motion displays a static baseline and suppresses changing bar heights.
public struct CadenzaSpectrumView: View {
    public var frame: SpectrumFrame
    public var color: Color
    public var spacing: CGFloat
    public var cornerRadius: CGFloat
    public var minimumBarHeight: CGFloat
    public var reducesMotion: Bool
    public var accessibilityTitle: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(frame: SpectrumFrame, color: Color = .accentColor, spacing: CGFloat = 3,
                cornerRadius: CGFloat = 2, minimumBarHeight: CGFloat = 2,
                reducesMotion: Bool = false, accessibilityTitle: String = PlayerStrings.localized(.spectrum)) {
        self.frame = frame; self.color = color; self.spacing = spacing
        self.cornerRadius = cornerRadius; self.minimumBarHeight = minimumBarHeight
        self.reducesMotion = reducesMotion
        self.accessibilityTitle = accessibilityTitle
    }

    public var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: max(0, spacing)) {
                ForEach(0..<SpectrumFrame.bandCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: max(0, cornerRadius))
                        .fill(color)
                        .frame(height: min(geometry.size.height, max(0, minimumBarHeight,
                            geometry.size.height * CGFloat((reduceMotion || reducesMotion) ? 0 : frame.levels[index]))))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityAddTraits(.isImage)
    }
}
