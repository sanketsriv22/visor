import AppKit
import Foundation

/// Self-updates Visor by downloading the latest prebuilt Visor.app from the
/// GitHub release and swapping it into /Applications. A running app can't
/// overwrite its own bundle in place, so the actual swap is done by a tiny
/// detached shell script that waits for the app to quit, replaces the bundle,
/// and relaunches it.
final class Updater {
    static let releaseZipURL = URL(string: "https://github.com/sanketsriv22/visor/releases/latest/download/Visor.zip")!

    /// Reports human-readable progress for the menu item title.
    var onStatus: ((String) -> Void)?
    private var busy = false
    var isBusy: Bool { busy }

    private static let latestAPI = URL(string: "https://api.github.com/repos/sanketsriv22/visor/releases/latest")!

    /// Fetch the latest published version (release tag, "v" stripped). nil on failure.
    func fetchLatestVersion(_ completion: @escaping (String?) -> Void) {
        var req = URLRequest(url: Self.latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let tag = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any]
            let name = tag?["tag_name"] as? String
            completion(name.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 })
        }.resume()
    }

    /// Check the latest version first; only download+install if it differs from
    /// what's running, so the user gets clear feedback either way.
    func checkThenUpdate() {
        guard !busy else { return }
        onStatus?("Checking for updates…")
        fetchLatestVersion { [weak self] latest in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let latest else { self.onStatus?("Couldn't reach update server"); return }
                if latest == AppInfo.version {
                    self.onStatus?("You're on the latest (\(AppInfo.version))")
                } else {
                    self.onStatus?("Updating to \(latest)…")
                    self.update()
                }
            }
        }
    }

    func update() {
        guard !busy else { return }
        busy = true
        onStatus?("Downloading update…")

        var req = URLRequest(url: Self.releaseZipURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.downloadTask(with: req) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let tmp, err == nil,
                      (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    self.fail(err?.localizedDescription ?? "download failed")
                    return
                }
                self.install(downloadedZip: tmp)
            }
        }.resume()
    }

    private func install(downloadedZip zip: URL) {
        onStatus?("Installing update…")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("visor-update-\(UUID().uuidString)")
        let zipPath = work.appendingPathComponent("Visor.zip")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do { try FileManager.default.moveItem(at: zip, to: zipPath) }
        catch { try? FileManager.default.copyItem(at: zip, to: zipPath) }

        guard runSync("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path]) else {
            return fail("could not unzip update")
        }
        let staged = work.appendingPathComponent("Visor.app")
        guard FileManager.default.fileExists(atPath: staged.path) else {
            return fail("update archive looks wrong")
        }

        // Detached swap-and-relaunch: wait for this app to quit, replace the
        // installed bundle with the staged one, clear quarantine, relaunch.
        let dest = "/Applications/Visor.app"
        let script = """
        #!/bin/bash
        while pgrep -x Visor >/dev/null 2>&1; do sleep 0.3; done
        rm -rf "\(dest)"
        /usr/bin/ditto "\(staged.path)" "\(dest)"
        xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null || true
        open "\(dest)"
        rm -rf "\(work.path)"
        """
        let scriptPath = work.appendingPathComponent("swap.sh")
        do { try script.write(to: scriptPath, atomically: true, encoding: .utf8) }
        catch { return fail("could not stage updater") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        // nohup + & detaches it so it outlives this app quitting.
        p.arguments = ["-c", "nohup bash \"\(scriptPath.path)\" >/tmp/visor-update.log 2>&1 &"]
        do { try p.run() } catch { return fail(error.localizedDescription) }

        onStatus?("Restarting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    private func runSync(_ exe: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    private func fail(_ why: String) {
        busy = false
        onStatus?("Update failed: \(why)")
    }
}
