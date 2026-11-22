import AppKit

/// Plays macOS's built-in sounds at key moments. The files are read from the
/// system at runtime, not bundled with the app.
@MainActor
enum Sounds {
    static let enabledKey = "soundEnabled"
    private static let systemSounds =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"

    enum Effect {
        case drop        // app dropped in
        case scanned     // scan finished
        case trashed     // files moved to Trash (Finder's own sound)
        case failed      // something could not be removed
    }

    private static var cache: [String: NSSound] = [:]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func play(_ effect: Effect) {
        guard isEnabled else { return }
        let sound: NSSound?
        switch effect {
        case .drop:    sound = named("Pop")
        case .scanned: sound = named("Tink")
        case .trashed: sound = file("finder/move to trash.aif") ?? named("Purr")
        case .failed:  sound = named("Basso")
        }
        sound?.stop()
        sound?.play()
    }

    private static func named(_ name: String) -> NSSound? {
        if let s = cache[name] { return s }
        let s = NSSound(named: NSSound.Name(name))
        cache[name] = s
        return s
    }

    private static func file(_ relative: String) -> NSSound? {
        if let s = cache[relative] { return s }
        let s = NSSound(contentsOfFile: "\(systemSounds)/\(relative)", byReference: true)
        cache[relative] = s
        return s
    }
}
