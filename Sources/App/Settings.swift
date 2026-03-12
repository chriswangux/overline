import AppKit

/// Animation style for the session label.
enum AnimationStyle: String {
    case accentBar   // Style A: vertical shimmer bar + badge dot glow
    case borderLoop  // Style B: traveling border segment + full-perimeter glow
}

/// Known target apps with their bundle identifiers.
enum TargetApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iterm2   = "com.googlecode.iterm2"
    case warp     = "dev.warp.Warp-Stable"

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2:   return "iTerm2"
        case .warp:     return "Warp"
        }
    }
}

/// Overline operating mode.
enum OverlineMode: String {
    case singleApp   // Original: watch one target app only
    case multiApp    // Multi-app clustering: terminals + browsers + desktop apps
}

/// Known browser bundle identifiers.
enum BrowserApp: String, CaseIterable {
    case chrome = "com.google.Chrome"
    case arc    = "company.thebrowser.Browser"
    case safari = "com.apple.Safari"

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .arc:    return "Arc"
        case .safari: return "Safari"
        }
    }
}

/// Persisted settings (UserDefaults).
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let kAnimationStyle = "animationStyle"
    private let kTargetBundleId = "targetBundleId"
    private let kOverlineMode = "overlineMode"
    private let kEnabledBrowsersPrefix = "browser_"

    var style: AnimationStyle {
        get {
            guard let raw = defaults.string(forKey: kAnimationStyle),
                  let s = AnimationStyle(rawValue: raw) else { return .accentBar }
            return s
        }
        set { defaults.set(newValue.rawValue, forKey: kAnimationStyle) }
    }

    /// The bundle identifier of the target app to watch.
    var targetBundleId: String {
        get {
            defaults.string(forKey: kTargetBundleId) ?? TargetApp.terminal.rawValue
        }
        set { defaults.set(newValue, forKey: kTargetBundleId) }
    }

    /// Display name for the current target app.
    var targetAppName: String {
        if let known = TargetApp(rawValue: targetBundleId) {
            return known.displayName
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetBundleId) {
            return url.deletingPathExtension().lastPathComponent
        }
        return targetBundleId
    }

    /// Current operating mode.
    var mode: OverlineMode {
        get {
            guard let raw = defaults.string(forKey: kOverlineMode),
                  let m = OverlineMode(rawValue: raw) else { return .singleApp }
            return m
        }
        set { defaults.set(newValue.rawValue, forKey: kOverlineMode) }
    }

    /// Whether a specific browser is enabled for multi-app scanning.
    func isBrowserEnabled(_ browser: BrowserApp) -> Bool {
        let key = kEnabledBrowsersPrefix + browser.rawValue
        if defaults.object(forKey: key) == nil {
            // Default: Chrome and Arc enabled, Safari off
            return browser != .safari
        }
        return defaults.bool(forKey: key)
    }

    func setBrowserEnabled(_ browser: BrowserApp, enabled: Bool) {
        defaults.set(enabled, forKey: kEnabledBrowsersPrefix + browser.rawValue)
    }

    /// All enabled browser bundle IDs.
    var enabledBrowserBundleIds: [String] {
        BrowserApp.allCases.filter { isBrowserEnabled($0) }.map(\.rawValue)
    }

    // MARK: - Bento Grid Constraints

    private let kBentoMinCellWidth  = "bento_minCellWidth"
    private let kBentoMaxCellWidth  = "bento_maxCellWidth"
    private let kBentoMinCellHeight = "bento_minCellHeight"
    private let kBentoMaxCellHeight = "bento_maxCellHeight"

    var bentoMinCellWidth: CGFloat {
        get { let v = defaults.double(forKey: kBentoMinCellWidth); return v > 0 ? v : 600 }
        set { defaults.set(newValue, forKey: kBentoMinCellWidth) }
    }
    var bentoMaxCellWidth: CGFloat {
        get { let v = defaults.double(forKey: kBentoMaxCellWidth); return v > 0 ? v : 1200 }
        set { defaults.set(newValue, forKey: kBentoMaxCellWidth) }
    }
    var bentoMinCellHeight: CGFloat {
        get { let v = defaults.double(forKey: kBentoMinCellHeight); return v > 0 ? v : 400 }
        set { defaults.set(newValue, forKey: kBentoMinCellHeight) }
    }
    var bentoMaxCellHeight: CGFloat {
        get { let v = defaults.double(forKey: kBentoMaxCellHeight); return v > 0 ? v : 900 }
        set { defaults.set(newValue, forKey: kBentoMaxCellHeight) }
    }

    private init() {}
}
