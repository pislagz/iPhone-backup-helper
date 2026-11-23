import Foundation

/// Compact, locale-independent "how long ago" strings for the menu ("2 h ago").
public enum RelativeTime {
    public static func string(for date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3_600) h ago"
        case ..<172_800: return "yesterday"
        case ..<(14 * 86_400): return "\(seconds / 86_400) days ago"
        case ..<(60 * 86_400): return "\(seconds / (7 * 86_400)) weeks ago"
        default: return "\(seconds / (30 * 86_400)) months ago"
        }
    }
}
