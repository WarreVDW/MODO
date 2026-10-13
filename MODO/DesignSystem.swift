import SwiftUI
import AppKit

enum ModoBrand {
    static let name = "MODO"
    static let tagline = "Your business. Your way."
    static let legacyName = "FRAMO"
    static let supportURLSlug = "modo"
}

enum StudioTheme {
    private static let paletteKey = "framo.theme.palette"
    private static let contrastKey = "framo.theme.highContrast"
    private static let accentKey = "framo.theme.accent"

    static var sidebar: Color { adaptive(light: light.sidebar, dark: dark.sidebar) }
    static var canvas: Color { adaptive(light: light.canvas, dark: dark.canvas) }
    static var elevated: Color { adaptive(light: light.elevated, dark: dark.elevated) }
    static var selected: Color { adaptive(light: light.selected, dark: dark.selected) }
    static var border: Color { adaptive(light: light.border, dark: dark.border) }
    static var primary: Color { adaptive(light: light.primary, dark: dark.primary) }
    static var onPrimary: Color { adaptive(light: "FFFFFF", dark: "11110F") }
    static var secondary: Color { adaptive(light: light.secondary, dark: dark.secondary) }
    static var tertiary: Color { adaptive(light: light.tertiary, dark: dark.tertiary) }
    static var soft: Color { adaptive(light: light.soft, dark: dark.soft) }
    static var input: Color { adaptive(light: light.input, dark: dark.input) }
    static var icon: Color { adaptive(light: light.secondary, dark: dark.primary) }
    static var accent: Color { Color(hex: UserDefaults.standard.string(forKey: accentKey) ?? "6B6B68") }
    static let red = Color(hex: "E4574F")
    static let green = Color(hex: "5BBC91")

    static func sync(settings: StudioSettings) {
        UserDefaults.standard.set(settings.effectivePalette.rawValue, forKey: paletteKey)
        UserDefaults.standard.set(settings.effectiveHighContrast, forKey: contrastKey)
        UserDefaults.standard.set(settings.effectiveAccentHex, forKey: accentKey)
    }

    private struct PaletteValues {
        let sidebar: String
        let canvas: String
        let elevated: String
        let selected: String
        let border: String
        let primary: String
        let secondary: String
        let tertiary: String
        let soft: String
        let input: String
    }

    private static var selectedPalette: InterfacePalette {
        InterfacePalette(rawValue: UserDefaults.standard.string(forKey: paletteKey) ?? "") ?? .neutral
    }

    private static var highContrast: Bool { UserDefaults.standard.bool(forKey: contrastKey) }

    private static var light: PaletteValues {
        if highContrast {
            return PaletteValues(sidebar: "EEEEEA", canvas: "FFFFFF", elevated: "FFFFFF", selected: "DCDCD7", border: "B8B8B1", primary: "10100F", secondary: "50504C", tertiary: "7C7C76", soft: "E9E9E5", input: "F7F7F4")
        }
        switch selectedPalette {
        case .neutral:
            return PaletteValues(sidebar: "F3F3F0", canvas: "FCFCFB", elevated: "FFFFFF", selected: "E5E5E0", border: "E5E5E0", primary: "181817", secondary: "666662", tertiary: "969690", soft: "F0F0EC", input: "F7F7F5")
        case .graphite:
            return PaletteValues(sidebar: "ECEDEB", canvas: "F8F9F7", elevated: "FFFFFF", selected: "DADDD9", border: "C8CCC7", primary: "171918", secondary: "626762", tertiary: "90958F", soft: "E9ECE8", input: "F3F5F2")
        case .paper:
            return PaletteValues(sidebar: "F4F1EA", canvas: "FBF9F4", elevated: "FFFDF8", selected: "E8E2D7", border: "D8D0C3", primary: "25221D", secondary: "6F695F", tertiary: "9A9388", soft: "F0ECE4", input: "F8F5EF")
        case .warm:
            return PaletteValues(sidebar: "F3EFEC", canvas: "FBF8F6", elevated: "FFFDFC", selected: "E8DED8", border: "D8CCC5", primary: "241F1C", secondary: "70645E", tertiary: "9C8E87", soft: "F0E9E5", input: "F8F3F0")
        case .vibrant:
            return PaletteValues(sidebar: "F0F4FF", canvas: "FAFCFF", elevated: "FFFFFF", selected: "DDE7FF", border: "BBD0FF", primary: "0A1950", secondary: "3D5A99", tertiary: "8FA6D6", soft: "E4EDFF", input: "F2F6FF")
        }
    }

    private static var dark: PaletteValues {
        switch selectedPalette {
        case .neutral:
            return PaletteValues(sidebar: "151515", canvas: "1B1B1A", elevated: "20201F", selected: "2B2B28", border: "2B2B28", primary: "F4F4F0", secondary: "C9C9C3", tertiary: "8E8E88", soft: "242422", input: "20201F")
        case .graphite:
            return PaletteValues(sidebar: "121413", canvas: "181A19", elevated: "1D201E", selected: "29302C", border: "39413C", primary: "F2F5F2", secondary: "C4CBC6", tertiary: "89928C", soft: "222724", input: "1D211F")
        case .paper:
            return PaletteValues(sidebar: "191714", canvas: "1F1D19", elevated: "24211D", selected: "322E27", border: "454038", primary: "F5F1E8", secondary: "CEC7BA", tertiary: "948D81", soft: "292620", input: "25221E")
        case .warm:
            return PaletteValues(sidebar: "181412", canvas: "1F1A18", elevated: "251F1C", selected: "342B27", border: "493C36", primary: "F6EFEA", secondary: "D0C2BA", tertiary: "998A82", soft: "2B2421", input: "251F1C")
        case .vibrant:
            return PaletteValues(sidebar: "0B0D17", canvas: "121424", elevated: "1C1F36", selected: "2D3560", border: "47528C", primary: "EDF1FF", secondary: "A8B5E0", tertiary: "6F7BA8", soft: "202647", input: "1A1E38")
        }
    }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return NSColor(hex: match == .darkAqua ? dark : light)
        })
    }
}

struct FramoLiquidGlassSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(StudioTheme.canvas.opacity(colorScheme == .dark ? 0.34 : 0.20), in: shape)
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.15 : 0.55), Color.white.opacity(0.03), StudioTheme.primary.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
            }
            .overlay(alignment: .topLeading) {
                shape
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.28), lineWidth: 0.5)
                    .blur(radius: 0.25)
                    .padding(0.5)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.26 : 0.12), radius: 22, y: 8)
    }
}

extension View {
    func framoLiquidGlass(radius: CGFloat = 16) -> some View {
        modifier(FramoLiquidGlassSurface(radius: radius))
    }
}

struct StudioScaleContainer<Content: View>: View {
    let scale: CGFloat
    let content: Content

    init(scale: CGFloat, @ViewBuilder content: () -> Content) {
        self.scale = scale
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
        }
    }
}

private struct StudioCursorRegion: NSViewRepresentable {
    enum Kind { case pointingHand, iBeam }
    let kind: Kind

    func makeNSView(context: Context) -> CursorNSView { CursorNSView(kind: kind) }
    func updateNSView(_ nsView: CursorNSView, context: Context) { nsView.kind = kind; nsView.window?.invalidateCursorRects(for: nsView) }

    final class CursorNSView: NSView {
        var kind: Kind
        init(kind: Kind) { self.kind = kind; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: kind == .pointingHand ? .pointingHand : .iBeam)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func studioPointerCursor() -> some View {
        overlay { StudioCursorRegion(kind: .pointingHand).allowsHitTesting(false) }
    }

    func studioTextCursor() -> some View {
        overlay { StudioCursorRegion(kind: .iBeam).allowsHitTesting(false) }
    }

    func studioEditableSurface() -> some View {
        modifier(StudioEditableSurfaceModifier())
    }

    func studioEditableLine() -> some View {
        modifier(StudioEditableLineModifier())
    }
}

private struct StudioEditableLineModifier: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        content
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(hovered ? StudioTheme.input : StudioTheme.input.opacity(0.58), in: shape)
            .overlay {
                shape.stroke(hovered ? StudioTheme.primary.opacity(0.16) : StudioTheme.border.opacity(0.34), lineWidth: 0.7)
            }
            .studioTextCursor()
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct StudioEditableSurfaceModifier: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovered ? StudioTheme.input : StudioTheme.input.opacity(0.70), in: shape)
            .overlay {
                shape.stroke(hovered ? StudioTheme.primary.opacity(0.18) : StudioTheme.border.opacity(0.30), lineWidth: 0.7)
            }
            .studioTextCursor()
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

struct StudioLogoMark: View {
    var size: CGFloat = 28
    var body: some View {
        Group {
            if NSImage(named: NSImage.Name("logo")) != nil {
                Image("logo").resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "film.stack.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(StudioTheme.primary)
    }
}

struct AssetIcon: View {
    let name: String
    let fallback: String
    var size: CGFloat = 17
    var color: Color = StudioTheme.icon

    var body: some View {
        Group {
            if let image = bundledImage(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(color)
    }

    private func bundledImage(named resourceName: String) -> NSImage? {
        let bareName = (resourceName as NSString).deletingPathExtension
        let explicitExtension = (resourceName as NSString).pathExtension
        let candidates = [resourceName, bareName, bareName + ".svg"]

        for candidate in candidates {
            if let image = NSImage(named: NSImage.Name(candidate)) {
                image.isTemplate = true
                return image
            }
        }

        let extensions = explicitExtension.isEmpty ? ["svg", "pdf", "png"] : [explicitExtension]
        let subdirectories: [String?] = ["Media", "media", "Resources", nil]

        for subdirectory in subdirectories {
            for ext in extensions {
                if let url = Bundle.main.url(forResource: bareName, withExtension: ext, subdirectory: subdirectory),
                   let image = NSImage(contentsOf: url) {
                    image.isTemplate = true
                    return image
                }
            }
        }

        if let urls = Bundle.main.urls(forResourcesWithExtension: "svg", subdirectory: nil),
           let url = urls.first(where: { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(bareName) == .orderedSame }),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return image
        }

        return nil
    }
}

struct SectionLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .regular))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(StudioTheme.tertiary)
    }
}

struct StudioCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background(StudioTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct StatusPill: View {
    let status: ProjectStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.rawValue)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(StudioTheme.primary.opacity(0.86))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(status.color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct InitialAvatar: View {
    let initials: String
    var size: CGFloat = 22
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: "3B3A38"))
            .clipShape(Circle())
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(StudioTheme.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioDialogField<Content: View>: View {
    let label: String?
    let content: Content

    init(_ label: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label, !label.isEmpty {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(StudioTheme.tertiary)
            }
            content
                .padding(.horizontal, 11)
                .frame(minHeight: 38)
                .background(StudioTheme.input.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

struct StudioDialogSurface<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(22)
            .background(StudioTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(StudioTheme.onPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(StudioTheme.primary.opacity(configuration.isPressed ? 0.80 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .studioPointerCursor()
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(StudioTheme.primary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? StudioTheme.selected : StudioTheme.soft.opacity(0.82))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.045), lineWidth: 0.6)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .studioPointerCursor()
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(StudioTheme.icon)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? StudioTheme.selected : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .studioPointerCursor()
    }
}

struct LiquidGlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                
                Capsule()
                    .fill(
                        LinearGradient(colors: [StudioTheme.accent.opacity(0.6), StudioTheme.accent], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(0, geometry.size.width * CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))))
                    .shadow(color: StudioTheme.accent.opacity(0.4), radius: 8, x: 0, y: 0)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let percentage = min(max(0, gesture.location.x / geometry.size.width), 1)
                value = range.lowerBound + Double(percentage) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 12)
    }
}

extension Date {
    var shortStudioDate: String { formatted(.dateTime.month(.abbreviated).day()) }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

enum StudioBannerDefaults {
    static let bundled = ["banner", "banner1", "banner3"]

    static func assetName(for id: UUID) -> String? {
        let available = bundled.filter { NSImage(named: NSImage.Name($0)) != nil }
        guard !available.isEmpty else { return nil }
        let value = id.uuidString.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return available[abs(value) % available.count]
    }

    static var firstAvailable: String? { bundled.first { NSImage(named: NSImage.Name($0)) != nil } }
}

struct ProjectBanner: View {
    let path: String?
    var assetName: String? = nil
    let colorHex: String
    var height: CGFloat
    var focusY: CGFloat = 0.5
    var fadeBottom = false

    var body: some View {
        ZStack(alignment: .bottom) {
            bannerContent
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .offset(y: (0.5 - min(max(focusY, 0), 1)) * height * 0.55)
                .clipped()

            if fadeBottom {
                LinearGradient(
                    stops: [
                        .init(color: StudioTheme.canvas.opacity(0), location: 0),
                        .init(color: StudioTheme.canvas.opacity(0.16), location: 0.55),
                        .init(color: StudioTheme.canvas, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: min(74, height * 0.45))
                .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .clipped()
    }

    @ViewBuilder private var bannerContent: some View {
        if let path, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
        } else if let assetName, NSImage(named: NSImage.Name(assetName)) != nil {
            Image(assetName).resizable().interpolation(.high).scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hex: colorHex).opacity(0.92),
                        Color(hex: colorHex).opacity(0.55),
                        StudioTheme.soft
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [.white.opacity(0.12), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(120, height * 1.7)
                )
                .blendMode(.screen)
                Rectangle()
                    .fill(.black.opacity(0.07))
                    .mask(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}
