import AppKit

/// View menu (panes, layout lock, toolbars) and Window › Amamac.
@MainActor
final class ViewCommands: NSObject, NSMenuItemValidation {
    private unowned let env: AppEnvironment
    private unowned let window: MainWindowController

    init(env: AppEnvironment, window: MainWindowController) {
        self.env = env
        self.window = window
    }

    @objc func togglePaneVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let pane = Pane(rawValue: raw) else { return }
        window.togglePane(pane)
    }

    @objc func toggleLockLayout(_ sender: Any?) {
        let locked = !env.settings.bool(AppSettings.Key.lockLayout)
        env.settings.set(locked, AppSettings.Key.lockLayout)
        window.applyLock(locked)
    }

    @objc func useMainToolbar(_ sender: Any?) {
        env.settings.set(false, AppSettings.Key.slimToolbar)
        window.setSlimToolbar(false)
    }

    @objc func useSlimToolbar(_ sender: Any?) {
        env.settings.set(true, AppSettings.Key.slimToolbar)
        window.setSlimToolbar(true)
    }

    @objc func resetLayout(_ sender: Any?) {
        guard Confirm.ask("Reset the layout?", info: "All panes are shown again at their default widths and the layout is locked.",
                          action: "Reset Layout") else { return }
        window.resetLayout()
    }

    @objc func showMainWindow(_ sender: Any?) { window.showWindow(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(togglePaneVisibility(_:)):
            if let raw = menuItem.representedObject as? String, let pane = Pane(rawValue: raw) {
                menuItem.state = window.isPaneVisible(pane) ? .on : .off
            }
            return true
        case #selector(toggleLockLayout(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.lockLayout) ? .on : .off
            return true
        case #selector(useMainToolbar(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.slimToolbar) ? .off : .on
            return true
        case #selector(useSlimToolbar(_:)):
            menuItem.state = env.settings.bool(AppSettings.Key.slimToolbar) ? .on : .off
            return true
        default:
            return true
        }
    }
}
