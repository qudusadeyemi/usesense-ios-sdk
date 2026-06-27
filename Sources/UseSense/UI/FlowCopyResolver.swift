#if canImport(UIKit) && canImport(SwiftUI)
import UIKit
import SwiftUI

// MARK: - FlowCopyResolver
//
// Holds the merged FlowCopy for the active Flow run and resolves a copy slot to
// a concrete string, falling back to the screen's built-in default. Because the
// parity screens ask the resolver each time they render a label, setting the
// copy on the resolver re-words every screen automatically — mirroring how
// FlowAppearanceResolver re-themes them.
//
// This is presentation state only. The Flow runner sets it before presenting any
// surface and clears it on teardown. Reads happen on the main thread (SwiftUI
// body), so a plain main-thread-only store is sufficient.

public enum FlowCopyResolver {
    // Presentation state, mutated and read only on the main thread (the runner
    // sets it before presenting; SwiftUI bodies read it on the main thread).
    // `nonisolated(unsafe)` documents that main-thread-only contract while
    // keeping the screens' `text(...)` lookups callable from their existing
    // (non-isolated) static contexts.
    nonisolated(unsafe) private static var _current: FlowCopy?

    /// The merged copy currently driving the runner. `nil` = built-in copy.
    public static var current: FlowCopy? { _current }

    @MainActor public static func set(_ copy: FlowCopy?) {
        _current = copy
    }

    @MainActor public static func reset() {
        _current = nil
    }

    // MARK: Lookup

    /// Resolve a copy slot (by key path into the merged FlowCopy) to a string,
    /// falling back to the screen's built-in default. An empty/whitespace
    /// override is treated as unset, so a cleared dashboard field never blanks
    /// the UI (mirrors the web SDK `txt` helper).
    public static func text(_ keyPath: KeyPath<FlowCopy, String?>, default fallback: String) -> String {
        guard let override = current?[keyPath: keyPath] else { return fallback }
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Look up a free-form help slot by id, or nil if unset/blank.
    public static func help(_ slot: String) -> String? {
        guard let value = current?.help?[slot] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
