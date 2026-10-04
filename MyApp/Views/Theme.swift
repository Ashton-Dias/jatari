import SwiftUI
import UIKit

// MARK: Font

/// The app font is Helvetica Neue, built into iOS (no bundling or licensing needed).
/// If a weight can't be found, SwiftUI falls back to the system font rather than drawing nothing.
enum AppFont {
    static func name(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: "HelveticaNeue-UltraLight"
        case .thin: "HelveticaNeue-Thin"
        case .light: "HelveticaNeue-Light"
        case .medium: "HelveticaNeue-Medium"
        case .semibold, .bold, .heavy, .black: "HelveticaNeue-Bold"
        default: "HelveticaNeue"
        }
    }

    static func uiFont(size: CGFloat, weight: Font.Weight, style: UIFont.TextStyle) -> UIFont {
        let base = UIFont(name: name(for: weight), size: size) ?? .systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// Default point sizes of the system text styles, so `.app(.body)` matches `.body` in size.
    static func pointSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        default: 17
        }
    }
}

extension Font {
    /// Helvetica Neue at a system text style's size; scales with Dynamic Type.
    static func app(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
        .custom(AppFont.name(for: weight), size: AppFont.pointSize(for: style), relativeTo: style)
    }

    /// Helvetica Neue at a fixed base size that still scales with Dynamic Type.
    static func appSize(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(AppFont.name(for: weight), size: size, relativeTo: style)
    }
}

/// Navigation bar and bar-button text can't take a SwiftUI font, so set them through UIKit appearance.
enum AppAppearance {
    @MainActor static func apply() {
        let bar = UINavigationBarAppearance()
        bar.configureWithTransparentBackground()
        bar.titleTextAttributes = [.font: AppFont.uiFont(size: 17, weight: .medium, style: .headline), .foregroundColor: UIColor.white]
        bar.largeTitleTextAttributes = [.font: AppFont.uiFont(size: 34, weight: .bold, style: .largeTitle), .foregroundColor: UIColor.white]
        let nav = UINavigationBar.appearance()
        nav.standardAppearance = bar
        nav.scrollEdgeAppearance = bar
        nav.compactAppearance = bar
        UIBarButtonItem.appearance().setTitleTextAttributes(
            [.font: AppFont.uiFont(size: 17, weight: .regular, style: .body)], for: .normal)
    }
}

// MARK: Background and surfaces

enum Theme {
    /// How much dark tint sits behind alarm rows on the list. Lower = more of the artwork shows through.
    static let cardOpacity = 0.28
    /// Edge of a transparent card, so it stays visible against the bright artwork.
    static let cardBorderOpacity = 0.28
    /// Darkening of the artwork itself (top is stronger so the title and toolbar stay legible).
    static let backgroundDim = 0.22

    /// Secondary text, brighter than `.secondary` so it stays readable over the artwork.
    static let secondaryText = Color.white.opacity(0.95)
}

/// The illustration, filled edge to edge and darkened by a soft gradient so white text stays legible.
struct AppBackground: View {
    var dim: Double = Theme.backgroundDim

    var body: some View {
        GeometryReader { geo in
            Image("AppBackground")
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(
                    LinearGradient(colors: [.black.opacity(dim + 0.25), .black.opacity(dim * 0.6), .black.opacity(dim + 0.1)],
                                   startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// Soft dark halo so text that sits directly on the artwork (section headers/footers) stays readable.
    func legibleOverArt() -> some View {
        self.foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, -8)
    }

    func appBackground(dim: Double = Theme.backgroundDim) -> some View {
        background { AppBackground(dim: dim) }
    }
}

/// A rounded card for rows and panels. By default it is a see-through tint with a thin border, so the artwork
/// shows behind it. Pass `blurred: true` for panels that need more separation (adds a frosted blur and the
/// heavier `opacity`). It becomes nearly solid with Reduce Transparency or Increase Contrast.
struct Card: View {
    var radius: CGFloat = 18
    var opacity: Double = Theme.cardOpacity
    var blurred = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            shape.fill(Color(white: 0.1)).overlay(shape.strokeBorder(.white.opacity(0.4), lineWidth: 1))
        } else if blurred {
            shape.fill(Color.black.opacity(opacity)).background(.ultraThinMaterial, in: shape)
        } else {
            shape.fill(Color.black.opacity(opacity))
                .overlay(shape.strokeBorder(.white.opacity(Theme.cardBorderOpacity), lineWidth: 1))
        }
    }
}

/// Square version of `Card`, used as the row background inside Forms (the Form clips it to its rounded section).
struct RowFill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            Rectangle().fill(Color(white: 0.1))
        } else {
            Rectangle().fill(Color.black.opacity(0.5)).background(.ultraThinMaterial)
        }
    }
}
