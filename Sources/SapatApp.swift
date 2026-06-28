import SwiftUI

/// App entry point.
///
/// Šapat is a menu bar agent (`LSUIElement`), so there is no main window and no
/// Dock icon. All UI lives in an `NSPopover` anchored to an `NSStatusItem`, both
/// owned by `AppDelegate`. We deliberately use AppKit for the status item + popover
/// (instead of SwiftUI `MenuBarExtra`) because macOS 14 has no reliable public API
/// to open a `MenuBarExtra` window programmatically — and the global hotkey must be
/// able to pop the window open from any app.
///
/// There is no Settings screen: the popover is the whole app, and the one preference
/// (tone) is chosen inline via `TonePicker`. SwiftUI's `App` still requires a `Scene`,
/// and an empty `Settings` is the only one that never spawns a visible window — and an
/// agent app has no app menu, so it surfaces nothing to the user either. It's an inert
/// placeholder so all real UI stays in the AppKit popover.
@main
struct SapatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
