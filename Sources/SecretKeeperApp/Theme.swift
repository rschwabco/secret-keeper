import SwiftUI

/// Compact design tokens for Secret Keeper (macOS utility, not a marketing surface).
enum SKTheme {
    // Brand: deep slate + warm amber — avoids purple AI aesthetic.
    static let brandPrimary = Color(red: 0.18, green: 0.32, blue: 0.36) // deep teal-slate
    static let brandAccent = Color(red: 0.78, green: 0.52, blue: 0.22) // warm amber
    static let brandInk = Color(red: 0.12, green: 0.14, blue: 0.16)
    static let brandMist = Color(red: 0.93, green: 0.94, blue: 0.92)

    static let success = Color(red: 0.22, green: 0.55, blue: 0.42)
    static let danger = Color(red: 0.72, green: 0.28, blue: 0.24)

    static var brandTitleFont: Font {
        .system(size: 34, weight: .bold, design: .rounded)
    }

    static var sectionFont: Font {
        .system(.subheadline, design: .rounded).weight(.semibold)
    }

    static var mono: Font {
        .system(.body, design: .monospaced)
    }

    static var captionMono: Font {
        .system(.caption, design: .monospaced)
    }
}

struct AtmosphereBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.08, green: 0.11, blue: 0.12),
                        Color(red: 0.12, green: 0.16, blue: 0.17),
                        Color(red: 0.10, green: 0.13, blue: 0.14),
                      ]
                    : [
                        Color(red: 0.94, green: 0.95, blue: 0.93),
                        Color(red: 0.90, green: 0.93, blue: 0.92),
                        Color(red: 0.95, green: 0.93, blue: 0.89),
                      ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Soft radial wash for depth without looking like a landing page.
            RadialGradient(
                colors: [
                    SKTheme.brandAccent.opacity(colorScheme == .dark ? 0.10 : 0.12),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    SKTheme.brandPrimary.opacity(colorScheme == .dark ? 0.22 : 0.10),
                    .clear,
                ],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
    }
}

struct LockGlyph: View {
    let unlocked: Bool
    @State private var breathe = false

    var body: some View {
        Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
            .font(.system(size: unlocked ? 44 : 52, weight: .medium, design: .rounded))
            .foregroundStyle(unlocked ? SKTheme.success : SKTheme.brandAccent)
            .symbolEffect(.bounce, value: unlocked)
            .scaleEffect(unlocked ? 1.0 : (breathe ? 1.04 : 0.96))
            .opacity(unlocked ? 1.0 : (breathe ? 1.0 : 0.88))
            .animation(
                .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: breathe
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: unlocked)
            .onAppear {
                guard !unlocked else { return }
                breathe = true
            }
            .onChange(of: unlocked) { _, isUnlocked in
                breathe = !isUnlocked
            }
            .accessibilityHidden(true)
    }
}

struct UnlockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(SKTheme.brandAccent.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct SidebarRowBackground: View {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                selected
                    ? SKTheme.brandPrimary.opacity(colorScheme == .dark ? 0.45 : 0.14)
                    : Color.clear
            )
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: selected)
    }
}
