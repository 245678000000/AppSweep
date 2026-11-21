import AppKit
import Foundation

/// Checks GitHub Releases for a newer version and can install it in place.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repo = "245678000000/AppSweep"
    private let lastCheckKey = "lastUpdateCheck"
    private let skipKey = "skippedVersion"

    @Published var isChecking = false
    @Published var isDownloading = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    /// Silent check at launch, at most once a day.
    func checkOnLaunchIfNeeded() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            guard Self.compare(release.version, currentVersion) == .orderedDescending else {
                if userInitiated {
                    alert("已是最新版本", "AppSweep \(currentVersion) 是目前最新的版本。")
                }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == release.version { return }
            promptUpdate(release)
        } catch {
            if userInitiated {
                alert("检查更新失败", error.localizedDescription)
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AppSweep/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
            throw NSError(domain: "AppSweep", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "还没有发布任何版本。"])
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "AppSweep", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub 返回了错误（\(http.statusCode)）。"])
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func promptUpdate(_ release: Release) {
        let a = NSAlert()
        a.messageText = "发现新版本 AppSweep \(release.version)"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        a.informativeText = "当前版本 \(currentVersion)。" + (notes.isEmpty ? "" : "\n\n\(notes)")
        let zip = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        a.addButton(withTitle: zip != nil ? "安装并重启" : "前往下载")
        a.addButton(withTitle: "以后再说")
        a.addButton(withTitle: "跳过此版本")

        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let zip {
                Task { await install(from: zip.browser_download_url, fallback: release.html_url) }
            } else {
                NSWorkspace.shared.open(release.html_url)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: skipKey)
        default: break
        }
    }

    // MARK: Install

    private func install(from url: URL, fallback: URL) async {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            alert("无法自动安装", "没有写入 \(parent.path) 的权限，将打开下载页面。")
            NSWorkspace.shared.open(fallback)
            return
        }

        isDownloading = true
        defer { isDownloading = false }
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppSweepUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let (tmp, _) = try await URLSession.shared.download(from: url)
            let zipURL = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmp, to: zipURL)

            try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, work.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier
            else {
                throw NSError(domain: "AppSweep", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "下载的更新包内容不正确。"])
            }
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // Swap the bundle after we quit, then relaunch.
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf \(q(current.path)) && mv \(q(newApp.path)) \(q(current.path)) && open \(q(current.path))
            rm -rf \(q(work.path))
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            alert("更新失败", error.localizedDescription)
        }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "AppSweep", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) 执行失败（\(p.terminationStatus)）。"])
        }
        return p.terminationStatus
    }

    // MARK: Helpers

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
