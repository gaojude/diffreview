import Foundation

/// Font-size policy for the code viewer. Pure constants + clamping so the range logic is
/// unit-testable without any UI.
public enum FontSizes {
    public static let minimum: CGFloat = 8
    public static let maximum: CGFloat = 40
    public static let `default`: CGFloat = 13
    public static let step: CGFloat = 1

    /// Clamps `size` into `[minimum, maximum]`.
    public static func clamp(_ size: CGFloat) -> CGFloat {
        min(maximum, max(minimum, size))
    }
}
