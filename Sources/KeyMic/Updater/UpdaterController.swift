import Sparkle

final class UpdaterController {
    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private static let autoUpdateKey = "automaticallyUpdates"

    var automaticallyUpdates: Bool {
        UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
    }

    private init() {
        // Ensure first-launch default matches the UI default of true.
        UserDefaults.standard.register(defaults: [Self.autoUpdateKey: true])

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        applyUpdatePolicy()
        observeUserDefaults()
        scheduleDailyCheck()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var updater: SPUUpdater {
        controller.updater
    }

    /// Sync SUAutomaticallyUpdate (the UserDefaults key Sparkle reads for silent installs)
    /// with our own automaticallyUpdates preference.
    private func applyUpdatePolicy() {
        let desired = automaticallyUpdates
        let current = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") as? Bool
        guard current != desired else { return }
        UserDefaults.standard.set(desired, forKey: "SUAutomaticallyUpdate")
    }

    /// Re-apply the Sparkle policy whenever the preference changes (e.g. via Settings toggle).
    private func observeUserDefaults() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyUpdatePolicy()
        }
    }

    /// Schedule a daily check at 11:00 AM local time.
    /// SUScheduledCheckInterval in Info.plist is disabled (0) to avoid double-checking.
    private func scheduleDailyCheck() {
        let now = Date()
        let cal = Calendar.current
        let today11 = cal.date(bySettingHour: 11, minute: 0, second: 0, of: now)!
        let next11 = today11 > now ? today11 : cal.date(byAdding: .day, value: 1, to: today11)!
        let delay = next11.timeIntervalSince(now)
        // Ensure at least 1 hour between checks so we catch the next 11 AM window
        // even after a long sleep (>24h).
        let adjustedDelay = max(delay, 3600)

        DispatchQueue.main.asyncAfter(deadline: .now() + adjustedDelay) { [weak self] in
            self?.performScheduledCheck()
            self?.scheduleDailyCheck()
        }
    }

    private func performScheduledCheck() {
        guard updater.canCheckForUpdates else { return }
        // checkForUpdatesInBackground respects SUAutomaticallyUpdate:
        // silent install when true, prompt when false.
        updater.checkForUpdatesInBackground()
    }
}
