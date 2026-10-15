import SwiftUI

/// Moving highlight used on loading placeholders.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    /// Only animate while on screen — an off-screen placeholder shouldn't keep the app redrawing.
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .overlay {
                if !reduceMotion && visible {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.12), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
            .accessibilityLabel("Loading")
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

private struct Block: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }
}

/// A placeholder text line: up to `width` wide, narrower when there isn't room.
private struct Line: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        Block(width: nil, height: height)
            .frame(maxWidth: width, alignment: .leading)
    }
}

/// Placeholder song rows. Fits any width: the lines shrink in narrow panels instead of pushing
/// the rows out of line.
struct SkeletonRows: View {
    var count = 8
    var artwork = true
    /// Match the rows they stand in for, so nothing moves when those arrive.
    var artworkSize: CGFloat = 40
    var rowPadding: CGFloat = 8
    /// A section title above the rows.
    var title = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title {
                Line(width: 120, height: 13)
                    .frame(height: 22, alignment: .leading)
                    .padding(.horizontal, 10)
            }
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    if artwork { Block(width: artworkSize, height: artworkSize) }
                    VStack(alignment: .leading, spacing: 6) {
                        Line(width: CGFloat(140 + (i * 37) % 120), height: 11)
                        Line(width: CGFloat(80 + (i * 23) % 60), height: 9)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Block(width: 34, height: 9)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, rowPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmer()
    }
}

/// Placeholder paragraph: lines up to these widths, shrinking to fit.
struct SkeletonText: View {
    var widths: [CGFloat] = [120, 260, 220, 160]
    var height: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in Line(width: width, height: height) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmer()
    }
}

/// Placeholder for one comment: an avatar and a few lines.
struct SkeletonComment: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Block(width: 24, height: 24, radius: 12)
            VStack(alignment: .leading, spacing: 6) {
                Line(width: 90, height: 9)
                Line(width: 260, height: 10)
                Line(width: 180, height: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shimmer()
    }
}

struct SkeletonCarousel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Block(width: 180, height: 18)
            HStack(spacing: 18) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Block(width: 168, height: 168, radius: 8)
                        Block(width: 120, height: 10)
                        Block(width: 80, height: 9)
                    }
                }
            }
            // Never let the placeholder row dictate the window's minimum width.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .shimmer()
    }
}

struct SkeletonHome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(0..<8, id: \.self) { _ in Block(width: nil, height: 56, radius: 6) }
            }
            .shimmer()
            SkeletonCarousel()
            SkeletonCarousel()
        }
    }
}

struct SkeletonCollection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .bottom, spacing: 28) {
                Block(width: 230, height: 230, radius: 10)
                VStack(alignment: .leading, spacing: 12) {
                    Block(width: 70, height: 10)
                    Block(width: 320, height: 34)
                    Block(width: 160, height: 14)
                    HStack { Block(width: 80, height: 34, radius: 17); Block(width: 100, height: 34, radius: 17) }
                }
            }
            .shimmer()
            SkeletonRows(count: 10, artwork: false)
        }
        .padding(28)
        .padding(.top, 12)
    }
}
