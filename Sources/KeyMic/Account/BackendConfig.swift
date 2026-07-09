import Foundation

enum BackendConfig {
    static var baseURL: URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "accountBackendURL"),
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://keymic.io")!
        #endif
    }
}
