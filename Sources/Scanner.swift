import Foundation
import AppKit

struct FoundItem: Identifiable {
    let id = UUID()
    let url: URL
    let isAppBundle: Bool
    var size: Int64 = 0
    var selected = true

    var name: String {
        isAppBundle ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

struct AppInfo {
    let url: URL
    let name: String
    let bundleID: String?
    /// Lowercased bundle identifiers of the app and its embedded helpers / extensions.
    let identifiers: Set<String>
    /// Lowercased names (display name, bundle name, executable name).
    let names: Set<String>

    var isProtected: Bool {
        url.path.hasPrefix("/System/") || (bundleID?.lowercased().hasPrefix("com.apple.") ?? false)
    }
}

enum Scanner {
    private static let genericNames: Set<String> = [
        "electron", "app", "main", "launcher", "helper", "updater", "update", "applications",
        "library", "preferences", "caches", "logs", "data", "default", "user", "temp", "tmp",
        "cache", "support", "plugins", "frameworks", "resources", "shared", "common", "apple",
    ]

    // MARK: App info

    static func appInfo(for url: URL) -> AppInfo? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let bundleID = bundle.bundleIdentifier

        var ids = Set<String>()
        if let bundleID { ids.insert(bundleID.lowercased()) }

        // Embedded helpers, extensions, login items, privileged helpers.
        let fm = FileManager.default
        let contents = url.appendingPathComponent("Contents")
        let subdirs = ["PlugIns", "Library/LoginItems", "Library/LaunchServices", "Library/SystemExtensions",
                       "Library/QuickLook", "Library/Spotlight", "Helpers", "XPCServices", "Frameworks"]
        for sub in subdirs {
            let dir = contents.appendingPathComponent(sub)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                if ["app", "appex", "xpc", "systemextension", "qlgenerator", "mdimporter"].contains(ext) {
                    // In Frameworks only accept helper apps (Electron style), not shared frameworks.
                    if sub == "Frameworks" && ext != "app" { continue }
                    if let id = Bundle(url: entry)?.bundleIdentifier { ids.insert(id.lowercased()) }
                } else if sub == "Library/LaunchServices", ext.isEmpty {
                    // Privileged helper tools are named after their identifier.
                    ids.insert(entry.lastPathComponent.lowercased())
                }
            }
        }
        // Only keep reasonably specific identifiers.
        ids = ids.filter { $0.contains(".") && $0.count >= 6 && !$0.hasPrefix("com.apple.") }

        let fileName = url.deletingPathExtension().lastPathComponent
        var names = Set<String>()
        for key in ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"] {
            if let v = info[key] as? String { names.insert(v.lowercased()) }
        }
        names.insert(fileName.lowercased())
        names = names.filter { $0.count >= 3 && !genericNames.contains($0) }

        let display = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        return AppInfo(url: url, name: display, bundleID: bundleID, identifiers: ids, names: names)
    }

    // MARK: Search locations

    static func searchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userLib = home.appendingPathComponent("Library")
        let userSubs = [
            "Application Support", "Application Support/CrashReporter", "Application Scripts",
            "Caches", "Containers", "Group Containers", "Preferences", "Preferences/ByHost",
            "Logs", "Logs/DiagnosticReports", "Saved Application State", "WebKit", "HTTPStorages",
            "Cookies", "LaunchAgents", "Internet Plug-Ins", "Services", "Autosave Information",
            "Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments",
        ]
        let sysLib = URL(fileURLWithPath: "/Library")
        let sysSubs = [
            "Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons",
            "PrivilegedHelperTools", "Logs", "Logs/DiagnosticReports", "Internet Plug-Ins",
            "Extensions", "Audio/Plug-Ins/HAL", "Audio/Plug-Ins/Components",
        ]
        var roots = userSubs.map { userLib.appendingPathComponent($0) }
        roots += sysSubs.map { sysLib.appendingPathComponent($0) }
        roots.append(URL(fileURLWithPath: "/private/var/db/receipts"))
        for name in [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR] {
            if let dir = confDir(Int32(name)) { roots.append(dir) }
        }
        return roots
    }

    private static func confDir(_ name: Int32) -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buf, buf.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf))
    }

    // MARK: Matching

    static func matches(_ entryName: String, app: AppInfo) -> Bool {
        let lower = entryName.lowercased()
        let boundaries: Set<Character> = [".", "-", "_", " "]

        for id in app.identifiers {
            if lower == id { return true }
            if lower.hasPrefix(id) {
                let next = lower[lower.index(lower.startIndex, offsetBy: id.count)]
                if boundaries.contains(next) { return true }
            }
            // Group containers: TEAMID.com.vendor.app(.suffix)
            if lower.hasSuffix("." + id) || lower.contains("." + id + ".") { return true }
        }

        let base = (lower as NSString).deletingPathExtension
        for name in app.names {
            if lower == name || base == name { return true }
            // Crash reports: AppName-2026-01-01-....ips / AppName_2026...
            if lower.hasSuffix(".ips") || lower.hasSuffix(".crash") || lower.hasSuffix(".diag") || lower.hasSuffix(".hang") {
                if lower.hasPrefix(name + "-") || lower.hasPrefix(name + "_") { return true }
            }
        }
        return false
    }

    // MARK: Scan

    static func scan(_ apps: [AppInfo]) -> [FoundItem] {
        let fm = FileManager.default
        var urls: [URL] = apps.map(\.url)

        for root in searchRoots() {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries where apps.contains(where: { matches(entry, app: $0) }) {
                urls.append(root.appendingPathComponent(entry))
            }
        }

        // Deduplicate and drop anything nested inside another hit.
        var seen = Set<String>()
        let unique = urls.map { $0.standardizedFileURL }.filter { seen.insert($0.path).inserted }
        let paths = unique.map(\.path)
        let filtered = unique.filter { url in
            !paths.contains { other in other != url.path && url.path.hasPrefix(other + "/") }
        }

        let appPaths = Set(apps.map { $0.url.standardizedFileURL.path })
        return filtered.map { url in
            FoundItem(url: url, isAppBundle: appPaths.contains(url.path), size: allocatedSize(of: url))
        }
    }

    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                        options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        return total
    }

    // MARK: Installed apps

    static func installedApps() -> [URL] {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var result: [URL] = []
        for dir in dirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for e in entries where e.hasSuffix(".app") {
                result.append(URL(fileURLWithPath: dir).appendingPathComponent(e))
            }
        }
        return result.sorted {
            $0.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                $1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }
    }
}
