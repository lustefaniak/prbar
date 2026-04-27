import Foundation
import SwiftData
import AppKit

/// "Reset all data" lever — wipes SwiftData + UserDefaults and
/// relaunches the app. Reachable from Settings → Diagnostics. Useful
/// when configs / cache get into a confusing state, since
/// `PRBarModelContainer.live()` already falls back to in-memory on a
/// corrupt store, so the app launches but the user sees empty state
/// and has no in-app way to repair it.
enum AppReset {
    static func wipeEverythingAndRelaunch() {
        wipeSwiftData()
        wipeUserDefaults()
        relaunch()
    }

    /// Delete every row of every `@Model` registered in the schema.
    /// Done via a fresh container so it's idempotent and works even if
    /// the live container is in a weird state.
    static func wipeSwiftData() {
        let url = PRBarModelContainer.appSupportDirectory
            .appendingPathComponent("store.sqlite")
        do {
            // Deleting the SQLite + auxiliary files is the cleanest
            // wipe — opening a container against a partially-deleted
            // store would just re-create rows. Trash the lot, including
            // -shm / -wal sidecars.
            for ext in ["", "-shm", "-wal"] {
                let candidate = URL(fileURLWithPath: url.path + ext)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    try FileManager.default.removeItem(at: candidate)
                }
            }
        } catch {
            NSLog("AppReset.wipeSwiftData: %@", String(describing: error))
        }
    }

    /// Drops every UserDefaults key under the app's bundle id —
    /// covers `@AppStorage` toggles (badge / sequential focus / cost
    /// cap / default provider) without having to enumerate them.
    static func wipeUserDefaults() {
        guard let bundleId = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleId)
        UserDefaults.standard.synchronize()
    }

    /// Relaunch via `open -n` (a fresh instance) and quit immediately.
    /// `-n` forces a new instance even though the current one is still
    /// terminating; the single-instance check in PRBarApp will let the
    /// new one through once we're gone.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", path]
        try? task.run()
        // Give `open` a moment to fork; otherwise we exit before the
        // child process is parented and the relaunch is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }
}
