import SwiftUI

// Matches the web app's design tokens exactly
enum Theme {
    // Colors
    static let bg = Color(hex: "F1ECE0")
    static let paper = Color(hex: "FAF6EC")
    static let paper2 = Color(hex: "F5EFE0")
    static let stone = Color(hex: "E7DFCD")
    static let rule = Color(hex: "D8CEB6")
    static let ink = Color(hex: "1F1A14")
    static let ink2 = Color(hex: "3D352A")
    static let inkMid = Color(hex: "7A6E5B")
    static let inkLow = Color(hex: "ADA28C")
    static let accent = Color(hex: "BE5A3F")
    static let accent2 = Color(hex: "E2C28A")
    static let moss = Color(hex: "5B7048")
    static let rose = Color(hex: "C8967D")
    static let success = Color(hex: "5B7048")
    static let warn = Color(hex: "C58B2B")
    static let error = Color(hex: "9C2828")

    // Radii
    static let rSm: CGFloat = 6
    static let rMd: CGFloat = 10
    static let rLg: CGFloat = 16
    static let rXl: CGFloat = 22
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
