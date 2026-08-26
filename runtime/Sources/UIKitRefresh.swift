// `canImport(UIKit)` is not the condition this file needs. UIKit imports on
// watchOS, where `UIView`, `UIApplication`, and the two list classes below are
// all unavailable -- measured as `error: 'UIView' is unavailable in watchOS`,
// and only in Debug, since Release compiles this out entirely. SwiftPM's
// `platforms:` does not prevent it: that is a deployment-target floor, not an
// allow-list, so a watchOS target may link this runtime.
#if SPLICE_ENABLED && canImport(UIKit) && !os(watchOS)

import UIKit

/// Makes a loaded generation visible.
///
/// Replacing a UIKit method body is not the same as seeing it. UIKit dispatches
/// at call time -- through the vtable, or through `objc_msgSend` for an `@objc`
/// member -- so every entry point it calls again reaches the replacement; it
/// simply has no reason to call anything again just because an image was
/// loaded. This sends the reasons.
///
/// SwiftUI is the same problem with a harder answer (DESIGN.md section 13.1).
/// A replaced `body` also runs when SwiftUI evaluates it; what differs is that
/// asking UIKit to lay out again is a supported call, while making SwiftUI
/// re-evaluate a view whose value did not change is not. Here invalidation is
/// sufficient, and the fixtures `uikit-live-instance` and `uikit-data-source`
/// measure both of the tiers below on an instance that is already on screen.
///
/// What is not here is a tier that re-runs `viewDidLoad`; see
/// `Splice.RefreshOptions` for what was measured and why it was dropped.
@MainActor
enum UIKitRefresh {
    /// Returns what it touched, phrased for a developer reading one line of
    /// CLI output. Nil when there was nothing to refresh, which is not a
    /// failure: a process with no window yet is a normal thing to patch.
    static func perform(_ options: Splice.RefreshOptions) -> String? {
        guard let application else { return nil }
        let windows = application.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter(isApplicationOwned)
        guard !windows.isEmpty else { return nil }

        var parts: [String] = []

        var nudged = 0
        var reloadedData = 0
        for window in windows {
            walk(window) { view in
                if options.contains(.layout) {
                    view.setNeedsLayout()
                    view.setNeedsUpdateConstraints()
                    view.setNeedsDisplay()
                    nudged += 1
                }
                if options.contains(.data) {
                    // Asked of the concrete classes rather than of a protocol:
                    // there is no common "reload your content" method, and
                    // these two are what a data source method is attached to.
                    if let table = view as? UITableView {
                        table.reloadData()
                        reloadedData += 1
                    } else if let collection = view as? UICollectionView {
                        collection.reloadData()
                        reloadedData += 1
                    }
                }
            }
        }
        if options.contains(.layout) {
            for window in windows { window.layoutIfNeeded() }
            parts.append("\(nudged) view\(nudged == 1 ? "" : "s") laid out")
        }
        if reloadedData > 0 {
            parts.append("\(reloadedData) list\(reloadedData == 1 ? "" : "s") reloaded")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `UIApplication.shared` by another name.
    ///
    /// Naming it directly makes every app-extension target that links this
    /// runtime fail to compile -- `NS_EXTENSION_UNAVAILABLE_IOS` -- and a
    /// framework shared by an app and its widget is enough to hit that.
    /// Measured: `'shared' is unavailable in application extensions for iOS`.
    ///
    /// Reaching it by selector would be a bad habit in shipping code. It is
    /// not shipping code: the whole file is behind `SPLICE_ENABLED`, which the
    /// package defines for Debug only, so no Release binary contains this.
    ///
    /// In an extension the refresh reports that it touched nothing, which is
    /// true -- an extension has no application to refresh. Which of the two
    /// steps returns nil there is not something this comment should claim:
    /// `NS_EXTENSION_UNAVAILABLE_IOS` is a compile-time annotation, so the
    /// selector very likely still answers and the cast is what fails.
    private static var application: UIApplication? {
        let selector = NSSelectorFromString("sharedApplication")
        let type: AnyObject = UIApplication.self
        guard type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? UIApplication
    }

    /// Whether the application owns this window, or UIKit does.
    ///
    /// A scene carries windows nobody asked for: `UITextEffectsWindow` appears
    /// as soon as a text field becomes first responder, and refreshing it
    /// touches state the application does not own while inflating the count
    /// reported back to `watch`.
    ///
    /// Asked as "did UIKit declare this class", not "is it in the main
    /// bundle". The bundle question looked equivalent and is not: a window
    /// class declared in one of the application's *own* frameworks -- ordinary
    /// in a modular app -- is in neither the main bundle nor `UIWindow`
    /// itself, so it was excluded, `windows` came back empty, and the refresh
    /// became a silent no-op whose only symptom is a missing line of output.
    /// Measured in the example app, whose SwiftUI window is exactly `UIWindow`
    /// and so was saved by the other half of that test by luck.
    private static func isApplicationOwned(_ window: UIWindow) -> Bool {
        let type = type(of: window)
        // The common case, and UIKit's own class: a plain window the
        // application put on screen.
        if type == UIWindow.self { return true }
        // Any other subclass UIKit declares is UIKit's. A subclass from
        // anywhere else belongs to the application, wherever it was linked.
        return Bundle(for: type) != Bundle(for: UIWindow.self)
    }

    private static func walk(_ view: UIView, _ body: (UIView) -> Void) {
        body(view)
        #if !os(tvOS)
        // A picker builds its wheels out of private table views driven by
        // private data sources. Measured on a screen with exactly one list of
        // its own: one `UIPickerView` contributed twelve `UIPickerTableView`s,
        // and `watch` reported "13 lists reloaded". Reloading them also
        // reaches past the public surface -- `reloadAllComponents()` is the
        // supported call -- so the subtree is left alone.
        //
        // Left alone means all of it. A row view of the developer's own,
        // returned from `pickerView(_:viewForRow:forComponent:)`, is inside
        // that subtree and is not refreshed either -- measured, a picker
        // contributes exactly one view to the count and none of its 256
        // descendants. Editing such a view's body reaches the process; seeing
        // it takes a `reloadAllComponents()` the application sends itself.
        if view is UIPickerView || view is UIDatePicker { return }
        #endif
        for subview in view.subviews { walk(subview, body) }
    }
}

#endif
