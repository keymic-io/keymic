import Foundation

/// What to do the first time a device enables Config Sync, decided from the
/// relationship between local and cloud state. Prevents a second machine from
/// silently clobbering either side.
enum BootstrapDecision: Equatable {
    case silentUpload    // cloud empty → seed it from this Mac
    case silentDownload  // this Mac is factory-default → adopt cloud
    case askUser         // both sides have meaningful, differing state → prompt
    case noop            // already in sync
}

enum ConfigSyncBootstrap {
    /// - Parameters:
    ///   - cloudSectionCount: number of sections the backend already holds.
    ///   - localIsFactoryDefault: true if this Mac has no user-set values in any
    ///     enabled section (nothing worth preserving).
    ///   - localDiffersFromCloud: true if any enabled section's local value
    ///     differs from cloud.
    static func decide(cloudSectionCount: Int,
                       localIsFactoryDefault: Bool,
                       localDiffersFromCloud: Bool) -> BootstrapDecision {
        if cloudSectionCount == 0 { return .silentUpload }
        if localIsFactoryDefault { return .silentDownload }
        if localDiffersFromCloud { return .askUser }
        return .noop
    }
}
