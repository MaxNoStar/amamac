import SwiftUI

/// Ratings (0...10, half stars) as text: "★★★½".
enum RatingText {
    static func stars(_ rating: Int) -> String {
        guard rating > 0 else { return "" }
        return String(repeating: "★", count: rating / 2) + (rating % 2 == 1 ? "½" : "")
    }
}

/// Five clickable stars with half steps (rating 0...10). Clicking the current value clears it.
struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 16
    let onChange: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        let shown = hover ?? rating
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let full = shown >= star * 2
                let half = shown == star * 2 - 1
                Image(systemName: full ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundStyle(shown > 0 && (full || half) ? Color.orange : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = value(at: p.x)
            case .ended: hover = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { e in
            let v = value(at: e.location.x)
            onChange(v == rating ? 0 : v)
        })
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(Double(rating) / 2) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(10, rating + 1))
            case .decrement: onChange(max(0, rating - 1))
            @unknown default: break
            }
        }
    }

    private func value(at x: CGFloat) -> Int {
        let starWidth = size + 2
        return max(1, min(10, Int((x / starWidth * 2).rounded(.up))))
    }
}
