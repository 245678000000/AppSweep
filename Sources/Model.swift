import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    enum Phase: Equatable {
        case idle, scanning, results, removing
        case done(freed: Int64, removed: Int, failed: [String])
    }

    @Published var phase: Phase = .idle
    @Published var items: [FoundItem] = []
    private(set) var apps: [AppInfo] = []

    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.selected).count }

    // MARK: Open

    func open(_ urls: [URL]) {
        guard phase != .scanning, phase != .removing else { return }
        let infos = urls.compactMap { Scanner.appInfo(for: $0) }
        guard !infos.isEmpty else {
            showAlert("这不是一个应用", "请拖入 .app 应用程序包。")
            return
        }
        if let p = infos.first(where: \.isProtected) {
            showAlert("无法卸载「\(p.name)」", "这是 macOS 系统自带的应用，受系统保护。")
            return
        }
        apps = infos
        items = []
        phase = .scanning
        Sounds.play(.drop)
        Task.detached(priority: .userInitiated) {
            let found = Scanner.scan(infos)
            await MainActor.run {
                // App bundles first, then by size.
                self.items = found.sorted { a, b in
                    if a.isAppBundle != b.isAppBundle { return a.isAppBundle }
                    return a.size > b.size
                }
                self.phase = .results
                Sounds.play(.scanned)
            }
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "选择"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func reset() {
        items = []
        apps = []
        phase = .idle
    }

    // MARK: Remove

    func removeSelected() {
        let targets = items.filter(\.selected)
        guard !targets.isEmpty else { return }

        let running = apps.compactMap(\.bundleID)
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = "「\(apps.map(\.name).joined(separator: "、"))」正在运行"
            alert.informativeText = "需要先退出应用才能删除。"
            alert.addButton(withTitle: "退出并删除")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        phase = .removing
        Task {
            if !running.isEmpty {
                running.forEach { $0.terminate() }
                for _ in 0..<30 where running.contains(where: { !$0.isTerminated }) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            let fm = FileManager.default
            var failed: [FoundItem] = []
            for t in targets {
                do { try fm.trashItem(at: t.url, resultingItemURL: nil) } catch { failed.append(t) }
            }

            if !failed.isEmpty {
                let alert = NSAlert()
                alert.messageText = "有 \(failed.count) 个项目需要管理员权限"
                alert.informativeText = failed.prefix(6).map(\.displayPath).joined(separator: "\n")
                    + (failed.count > 6 ? "\n…" : "")
                alert.addButton(withTitle: "输入密码继续")
                alert.addButton(withTitle: "跳过")
                if alert.runModal() == .alertFirstButtonReturn {
                    Self.trashWithAdmin(failed.map(\.url))
                }
            }

            let stillThere = targets.filter { fm.fileExists(atPath: $0.url.path) }
            let removed = targets.filter { !fm.fileExists(atPath: $0.url.path) }
            if !removed.isEmpty { Sounds.play(.trashed) }
            if removed.isEmpty && !stillThere.isEmpty { Sounds.play(.failed) }
            phase = .done(freed: removed.reduce(0) { $0 + $1.size },
                          removed: removed.count,
                          failed: stillThere.map(\.displayPath))
        }
    }

    /// Moves files into the current user's Trash using an authorized shell.
    private static func trashWithAdmin(_ urls: [URL]) {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let stamp = Int(Date().timeIntervalSince1970)
        let commands = urls.map { url -> String in
            var dest = trash.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                dest = trash.appendingPathComponent("\(url.lastPathComponent) \(stamp)")
            }
            return "mv -f \(q(url.path)) \(q(dest.path))"
        }
        let shell = commands.joined(separator: "; ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
