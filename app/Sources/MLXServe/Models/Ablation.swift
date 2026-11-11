import Foundation
import Security

/// A model's `ablation` entry in `model-settings.json`: the directional-ablation profile the server applies to every
/// request for that model. The server reads it per request, so it needs no reload. Off is strength 0 with the
/// profile kept.
struct AblationSetting: Equatable {
    var profile: String
    var strength: Double = 1
    /// "isolated", "read" or "shared"; nil runs the server's default (isolated).
    var prefixCache: String?

    init(profile: String, strength: Double = 1, prefixCache: String? = nil) {
        self.profile = profile
        self.strength = strength
        self.prefixCache = prefixCache
    }

    /// nil unless the server can read it too: a profile, a strength in 0...1, a known `prefix_cache` and no other key.
    /// `ModelOverride` keeps anything else verbatim, so a save never rewrites what the app cannot read.
    init?(json: Any) {
        guard let o = json as? [String: Any],
              Set(o.keys).isSubset(of: ["profile", "strength", "prefix_cache"]),
              let profile = o["profile"] as? String, !profile.isEmpty else { return nil }
        self.profile = profile
        if let s = o["strength"] {
            // A JSON bool bridges to NSNumber too.
            guard let n = s as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue <= 1 else { return nil }
            strength = n.doubleValue
        }
        if let p = o["prefix_cache"] {
            guard let p = p as? String, ["isolated", "read", "shared"].contains(p) else { return nil }
            prefixCache = p
        }
    }

    var json: [String: Any] {
        var out: [String: Any] = ["profile": profile, "strength": strength]
        if let prefixCache { out["prefix_cache"] = prefixCache }
        return out
    }
}

/// `/props` `ablation` for one model: its setting as the server read it, and why it cannot run, when it cannot (every
/// request on that model then fails with that sentence).
struct AblationStatus: Equatable {
    /// The model the `/props` request named.
    let modelId: String
    var setting: AblationSetting?
    var error: String?

    /// nil when the server reports none (an older server).
    static func parse(_ props: [String: Any], modelId: String) -> AblationStatus? {
        guard let o = props["ablation"] as? [String: Any] else { return nil }
        return AblationStatus(modelId: modelId, setting: o["setting"].flatMap { AblationSetting(json: $0) },
                              error: o["error"] as? String)
    }
}

/// The folder and key every launch names (`--ablation-profiles`, `--ablation-key-file`). The server exits at start
/// when the folder cannot be opened or the key is not a 0600 regular file of the user's holding 32 bytes or more.
enum AblationFiles {
    static let profilesPath = NSString(string: "~/.mlx-serve/ablation").expandingTildeInPath
    static let keyPath = NSString(string: "~/.mlx-serve/ablation.key").expandingTildeInPath

    struct Refusal: LocalizedError {
        let errorDescription: String?
    }

    /// Makes what is missing: the folder (0700) and the key (0600, 64 hex digits from 32 random bytes). An existing
    /// key is never rewritten, and a key path that is not a regular file is refused rather than followed.
    static func ensure(profilesPath: String = profilesPath, keyPath: String = keyPath) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (profilesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: profilesPath, isDirectory: &isDir) {
            guard isDir.boolValue else { throw Refusal(errorDescription: "\(profilesPath) is not a folder") }
        } else {
            try fm.createDirectory(atPath: profilesPath, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.createDirectory(atPath: (keyPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try createKey(at: keyPath)
    }

    /// O_EXCL makes "missing" and "create" one step, and with O_NOFOLLOW nothing already at the path is opened.
    private static func createKey(at path: String) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Refusal(errorDescription: "no random bytes for \(path)")
        }
        let key = Array(bytes.map { String(format: "%02x", $0) }.joined().utf8)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            var st = stat()
            if code == EEXIST, lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG { return }
            let why = code == EEXIST ? "not a regular file" : String(cString: strerror(code))
            throw Refusal(errorDescription: "\(path): \(why)")
        }
        defer { close(fd) }
        var written = 0
        while written < key.count {
            let n = key[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else {
                let why = String(cString: strerror(errno))
                unlink(path)
                throw Refusal(errorDescription: "\(path): \(why)")
            }
            written += n
        }
    }
}

/// What the Ablation controls show and what each edit writes; the menu bar and Model Settings share it.
struct AblationControl {
    /// The model row's `ablation_profiles`: the profiles that fit it, loaded when the server started.
    let profiles: [String]
    /// The setting as the file holds it.
    let setting: AblationSetting?
    /// The server's sentence when the setting cannot run.
    let error: String?

    /// `status` counts only when it is about `modelId`.
    init(profiles: [String], setting: AblationSetting?, status: AblationStatus? = nil, modelId: String? = nil) {
        self.profiles = profiles
        self.setting = setting
        error = status.flatMap { $0.modelId == modelId ? $0.error : nil }
    }

    var showsControls: Bool { !profiles.isEmpty }
    /// The error shows even with no profile listed: every request on the model fails with it.
    var isVisible: Bool { showsControls || error != nil }
    var isOn: Bool { (setting?.strength ?? 0) > 0 }
    var profile: String { setting?.profile ?? profiles.first ?? "" }
    /// A stored profile the server no longer lists stays a choice, so it shows and can be replaced.
    var choices: [String] {
        guard let stored = setting?.profile, !profiles.contains(stored) else { return profiles }
        return profiles + [stored]
    }
    /// Off, the strength box shows what turning on writes.
    var strength: Double { isOn ? setting?.strength ?? 1 : 1 }
    /// A new setting shares the cache; a stored one without the key runs isolated, the server's default.
    var reusesPrefixCache: Bool { setting.map { $0.prefixCache == "shared" } ?? true }

    func turnedOn(_ on: Bool) -> AblationSetting { edit { $0.strength = on ? strength : 0 } }
    func choosing(_ profile: String) -> AblationSetting { edit { $0.profile = profile } }
    func withStrength(_ strength: Double) -> AblationSetting { edit { $0.strength = strength } }
    func reusingPrefixCache(_ reuse: Bool) -> AblationSetting { edit { $0.prefixCache = reuse ? "shared" : "isolated" } }

    /// The stored setting, or a new one (off, the shown profile, the cache shared), with one field changed.
    private func edit(_ change: (inout AblationSetting) -> Void) -> AblationSetting {
        var s = setting ?? AblationSetting(profile: profile, strength: 0, prefixCache: "shared")
        change(&s)
        return s
    }

    /// A typed strength the server accepts (0...1), else nil.
    static func parseStrength(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v >= 0, v <= 1 else { return nil }
        return v
    }

    static func format(_ strength: Double) -> String { String(format: "%g", strength) }

    /// The menu bar's profile menu sizes to its title: a long folder name is cut in the middle to fit the panel.
    static func menuTitle(_ profile: String, limit: Int = 18) -> String {
        guard profile.count > limit else { return profile }
        let tail = (limit - 1) / 2
        return profile.prefix(limit - 1 - tail) + "…" + profile.suffix(tail)
    }

    /// The settings key of a resident row: the first candidate path whose tail is the row's id.
    static func modelPath(for row: ModelInfo, candidates: [String]) -> String? {
        candidates.first { !$0.isEmpty && ModelSettingsApply.row(for: $0, in: [row]) != nil }
    }
}
