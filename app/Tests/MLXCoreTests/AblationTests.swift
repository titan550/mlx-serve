import XCTest
@testable import MLXCore

/// The launch's ablation folder and key: the server exits at start unless the folder opens and the key is a 0600
/// regular file, so the app makes what is missing before every launch and never touches an existing key.
final class AblationFilesTests: XCTestCase {
    private var root = ""
    private var profiles: String { root + "/ablation" }
    private var key: String { root + "/ablation.key" }

    override func setUp() {
        root = NSTemporaryDirectory() + "ablation-files-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func ensure() throws {
        try AblationFiles.ensure(profilesPath: profiles, keyPath: key)
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    func testCreatesTheFolderAndAKeyOnlyTheUserCanRead() throws {
        try ensure()
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try mode(profiles), 0o700)
        XCTAssertEqual(try mode(key), 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key)[.ownerAccountID] as? UInt32, getuid())
        let text = try String(contentsOfFile: key, encoding: .utf8)
        XCTAssertEqual(text.count, 64)
        XCTAssertTrue(text.allSatisfy { "0123456789abcdef".contains($0) }, "the key is not 64 lowercase hex digits")

        let other = root + "/second.key"
        try AblationFiles.ensure(profilesPath: profiles, keyPath: other)
        XCTAssertNotEqual(FileManager.default.contents(atPath: other), FileManager.default.contents(atPath: key))
    }

    func testAnExistingKeyIsLeftByteForByte() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let mine = Data("a key the user wrote, longer than 32 bytes\n".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: key, contents: mine, attributes: [.posixPermissions: 0o600]))
        let written = try FileManager.default.attributesOfItem(atPath: key)[.modificationDate] as? Date
        try ensure()
        try ensure()
        XCTAssertEqual(FileManager.default.contents(atPath: key), mine)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key)[.modificationDate] as? Date, written)

        try FileManager.default.removeItem(atPath: key)
        try ensure()
        let generated = FileManager.default.contents(atPath: key)
        try ensure()
        XCTAssertEqual(FileManager.default.contents(atPath: key), generated, "a second launch rewrote the key")
    }

    func testAKeyPathThatIsASymlinkIsRefusedAndNeverFollowed() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let dangling = root + "/nowhere"
        try FileManager.default.createSymbolicLink(atPath: key, withDestinationPath: dangling)
        XCTAssertThrowsError(try ensure())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dangling), "the link was followed")

        let target = root + "/target"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("x".utf8)))
        try FileManager.default.removeItem(atPath: key)
        try FileManager.default.createSymbolicLink(atPath: key, withDestinationPath: target)
        XCTAssertThrowsError(try ensure())
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("x".utf8))
    }

    func testAKeyPathThatIsAFolderIsRefused() throws {
        try FileManager.default.createDirectory(atPath: key, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ensure())
    }

    func testAnExistingProfilesFolderIsLeftAsItIs() throws {
        try FileManager.default.createDirectory(atPath: profiles + "/refusal", withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profiles)
        try ensure()
        XCTAssertEqual(try mode(profiles), 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles + "/refusal"))
    }

    func testAProfilesPathThatIsAFileIsRefused() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: profiles, contents: Data()))
        XCTAssertThrowsError(try ensure())
    }
}

/// What the server says about ablation: the profiles a row lists, and `/props`'s setting and error for the model
/// the request named.
final class AblationServerReportTests: XCTestCase {
    func testAModelRowListsItsProfiles() {
        let row = APIClient.parseModelInfo(["id": "org/m", "ablation_profiles": [
            ["name": "a", "strength": 4, "max_strength": 4],
            ["name": "b", "strength": 1, "max_strength": 1],
        ]])
        XCTAssertEqual(row.ablationProfiles.map(\.name), ["a", "b"])
        XCTAssertEqual(row.ablationProfiles.map(\.strength), [4, 1])
        XCTAssertEqual(row.ablationProfiles.map(\.maxStrength), [4, 1])
        XCTAssertEqual(APIClient.parseModelInfo(["id": "org/m"]).ablationProfiles, [])
        // A row this app cannot read is dropped, never guessed at.
        XCTAssertEqual(APIClient.parseModelInfo(["id": "org/m", "ablation_profiles": ["a"]]).ablationProfiles, [])
    }

    func testPropsAblationIsFiledUnderTheModelTheRequestNamed() throws {
        let props: [String: Any] = [
            "memory": ["active_bytes": 1],
            "ablation": ["setting": ["profile": "p", "strength": 0.699999988079071, "prefix_cache": "shared"],
                         "error": NSNull()],
        ]
        let status = try XCTUnwrap(APIClient.propsSnapshot(props, model: "org/m")?.ablation)
        XCTAssertEqual(status.modelId, "org/m")
        XCTAssertEqual(status.setting?.profile, "p")
        XCTAssertEqual(status.setting?.prefixCache, "shared")
        XCTAssertNil(status.error)
        XCTAssertNil(APIClient.propsSnapshot(props, model: nil)?.ablation, "the bare route names no model")
    }

    func testPropsCarryTheSentenceEveryRequestFailsWith() {
        let props: [String: Any] = ["ablation": ["setting": NSNull(), "error": "the model's ablation setting is malformed"]]
        let status = AblationStatus.parse(props, modelId: "m")
        XCTAssertNil(status?.setting)
        XCTAssertEqual(status?.error, "the model's ablation setting is malformed")
        XCTAssertNil(AblationStatus.parse(["memory": [:]], modelId: "m"), "an older server reports nothing")
    }
}

/// The Ablation controls' state (menu bar and Model Settings): what shows, and what each edit writes.
final class AblationControlTests: XCTestCase {
    private let profiles = [AblationProfile(name: "alpha", strength: 4, maxStrength: 4),
                            AblationProfile(name: "beta", strength: 1, maxStrength: 1)]

    private func control(_ setting: AblationSetting?) -> AblationControl {
        AblationControl(profiles: profiles, setting: setting)
    }

    func testNoProfilesHidesTheControlsButNotTheError() {
        let status = AblationStatus(modelId: "org/m", setting: nil, error: "unknown ablation profile 'gone'")
        let c = AblationControl(profiles: [], setting: AblationSetting(profile: "gone", strength: 0),
                                status: status, modelId: "org/m")
        XCTAssertFalse(c.showsControls)
        XCTAssertEqual(c.error, "unknown ablation profile 'gone'")
        XCTAssertTrue(c.isVisible, "every request on the model fails with that sentence")
        XCTAssertTrue(control(nil).showsControls)
        XCTAssertTrue(control(nil).isVisible)
        XCTAssertFalse(AblationControl(profiles: [], setting: AblationSetting(profile: "p")).isVisible)
    }

    func testAStatusFiledUnderAnotherModelShowsNothingHere() {
        let status = AblationStatus(modelId: "org/other", setting: nil, error: "boom")
        XCTAssertNil(AblationControl(profiles: profiles, setting: nil, status: status, modelId: "org/m").error)
        XCTAssertNil(AblationControl(profiles: profiles, setting: nil, status: status, modelId: nil).error)
    }

    func testANewSettingStartsOffOnTheFirstProfileWithTheCacheShared() {
        let c = control(nil)
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(c.profile, "alpha")
        XCTAssertEqual(c.strength, 4, "the profile's measured strength, not a guess")
        XCTAssertEqual(c.maxStrength, 4)
        XCTAssertTrue(c.reusesPrefixCache)
        XCTAssertEqual(c.turnedOn(true), AblationSetting(profile: "alpha", strength: 4, prefixCache: "shared"))
    }

    func testOffIsStrengthZeroWithTheProfileKept() {
        let on = AblationSetting(profile: "beta", strength: 0.4, prefixCache: "isolated")
        let off = control(on).turnedOn(false)
        XCTAssertEqual(off, AblationSetting(profile: "beta", strength: 0, prefixCache: "isolated"))
        let c = control(off)
        XCTAssertFalse(c.isOn)
        XCTAssertEqual(c.profile, "beta")
        XCTAssertEqual(c.strength, 1, "off, the box shows what turning on writes")
        XCTAssertEqual(c.turnedOn(true), AblationSetting(profile: "beta", strength: 1, prefixCache: "isolated"))
        XCTAssertEqual(control(on).turnedOn(true), on)
    }

    func testEachEditChangesOnlyItsField() {
        let s = AblationSetting(profile: "alpha", strength: 0.4, prefixCache: "shared")
        // Picking a profile while on seeds that profile's measured strength (beta was measured at 1).
        XCTAssertEqual(control(s).choosing("beta"), AblationSetting(profile: "beta", strength: 1, prefixCache: "shared"))
        XCTAssertEqual(control(s).withStrength(0.75), AblationSetting(profile: "alpha", strength: 0.75, prefixCache: "shared"))
        XCTAssertEqual(control(s).reusingPrefixCache(false), AblationSetting(profile: "alpha", strength: 0.4, prefixCache: "isolated"))
        XCTAssertEqual(control(s).reusingPrefixCache(true).prefixCache, "shared")
        XCTAssertFalse(control(control(s).withStrength(0)).isOn, "strength 0 is off")
        XCTAssertEqual(control(nil).withStrength(0.3), AblationSetting(profile: "alpha", strength: 0.3, prefixCache: "shared"),
                       "typing a strength turns it on")
        XCTAssertEqual(control(nil).choosing("beta").strength, 0, "picking a profile does not turn an off setting on")
    }

    /// No key runs isolated, the server's default; "shared" is the only value that reuses.
    func testTheCacheToggleShowsWhatTheServerDoes() {
        XCTAssertFalse(control(AblationSetting(profile: "alpha")).reusesPrefixCache)
        XCTAssertFalse(control(AblationSetting(profile: "alpha", prefixCache: "isolated")).reusesPrefixCache)
        XCTAssertTrue(control(AblationSetting(profile: "alpha", prefixCache: "shared")).reusesPrefixCache)
        // The memberwise init takes any string; the JSON one is the path a stored setting comes in by.
        XCTAssertNil(AblationSetting(json: ["profile": "alpha", "prefix_cache": "read"]), "the server takes isolated or shared")
    }

    func testAStoredProfileTheServerNoLongerListsStaysAChoice() {
        let c = control(AblationSetting(profile: "gone"))
        XCTAssertEqual(c.choices, ["alpha", "beta", "gone"])
        XCTAssertEqual(c.profile, "gone")
        XCTAssertEqual(control(AblationSetting(profile: "beta")).choices, profiles.map(\.name))
    }

    /// A stored strength above 1 is one the server accepts: reading it must not drop the setting, and a save must
    /// write it back unchanged (`ModelOverride` keeps what the app cannot read only when `init?` refuses it).
    func testAStoredStrengthAboveOneSurvivesARead() {
        XCTAssertEqual(AblationSetting(json: ["profile": "p", "strength": 4]),
                       AblationSetting(profile: "p", strength: 4))
        XCTAssertEqual(AblationSetting(json: ["profile": "p", "strength": 30])?.json["strength"] as? Double, 30)
        XCTAssertNil(AblationSetting(json: ["profile": "p", "strength": 31]), "above the server's cap")
    }

    func testOnlyAStrengthTheServerAcceptsIsWritten() {
        XCTAssertEqual(AblationControl.parseStrength(" 0.5 "), 0.5)
        XCTAssertEqual(AblationControl.parseStrength("1"), 1)
        XCTAssertEqual(AblationControl.parseStrength("0"), 0)
        // Above 1 an ablation overrides a behaviour the model holds strongly (the server accepts up to 30).
        XCTAssertEqual(AblationControl.parseStrength("4"), 4)
        XCTAssertEqual(AblationControl.parseStrength("30"), 30)
        for bad in ["", "abc", "-0.1", "30.01", "nan", "inf"] {
            XCTAssertNil(AblationControl.parseStrength(bad), bad)
        }
        XCTAssertEqual(AblationControl.format(1), "1")
        XCTAssertEqual(AblationControl.format(0.7), "0.7")
    }

    /// The menu bar panel is 340 pt wide: a long folder name must not widen the capsule past it.
    func testALongProfileNameIsCutInTheMiddle() {
        XCTAssertEqual(AblationControl.menuTitle("refusal"), "refusal")
        let title = AblationControl.menuTitle("refusal-direction-qwen4-flash-v2")
        XCTAssertEqual(title.count, 18)
        XCTAssertTrue(title.hasPrefix("refusal-") && title.hasSuffix("-v2") && title.contains("…"), title)
    }

    func testARowsSettingsKeyIsTheCandidatePathEndingInItsId() {
        let row = ModelInfo(name: "org/m", quantBits: 4, layers: 1, hiddenSize: 1, vocabSize: 1,
                            contextLength: 1, modelMaxTokens: 1)
        XCTAssertEqual(AblationControl.modelPath(for: row, candidates: ["", "/x/org/other", "/models/org/m"]), "/models/org/m")
        XCTAssertNil(AblationControl.modelPath(for: row, candidates: ["/x/org/other", "/x/org/mm"]))
    }
}
