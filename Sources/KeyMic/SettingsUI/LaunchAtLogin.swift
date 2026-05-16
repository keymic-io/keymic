import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        Result {
            try enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}
