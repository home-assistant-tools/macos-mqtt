import Foundation
import ServiceManagement

/// Register/unregister the app as a macOS login item (SMAppService, macOS 13+).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func toggle() -> Bool {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("LoginItem toggle error: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
