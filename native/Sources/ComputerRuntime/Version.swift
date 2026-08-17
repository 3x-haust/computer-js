import Foundation

/// Single source of truth for the Computer.js runtime version.
/// Bumped automatically by `scripts/release.sh`.
enum RuntimeVersion {
    static let string = "0.2.0"
    static let tag = "v\(string)"
}
