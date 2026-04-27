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

    /// Relaunch the app. We can't just `open -n` and `terminate` — the
    /// child fires while we're still alive, the new instance's
    /// `enforceSingleInstance` sees us, and exits. Instead we spawn a
    /// detached shell that waits for our PID to actually die, then
    /// launches a fresh copy. The shell outlives our process tree
    /// because /bin/sh re-parents to launchd once we're gone.
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundlePath
            .replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open '\(path)'"
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            NSLog("AppReset.relaunch: failed to spawn watchdog: %@", String(describing: error))
        }
        // Small delay so the watchdog is definitely up-and-polling
        // before we exit, then quit cleanly. NSApp.terminate gives the
        // app a chance to flush state; if anything blocks termination
        // (a sheet, a confirmation), the watchdog still relaunches us
        // when the user finally dismisses whatever's holding it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
    }
}
