import Foundation
import ServiceManagement

/// Registers the app to start when the user logs in.
///
/// A background reminder app is close to useless if the user has to remember to
/// launch it, so this matters more here than in a typical app.
enum LaunchAtLogin {
    static func set(enabled: Bool) {
        // SMAppService needs the app to be a real bundle; when running from a
        // plain build directory there is nothing to register.
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // Registration can fail if the app is unsigned or quarantined.
            // The preference stays as the user set it; nothing else to do.
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
