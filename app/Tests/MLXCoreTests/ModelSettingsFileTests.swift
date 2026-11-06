import XCTest
@testable import MLXCore

/// `~/.mlx-serve/model-settings.json` is the SERVER's file (`src/host/registry/model_settings.zig`);
/// the app only edits it, so it must write exactly the server's keys and never
/// drop a key it does not know.
final class ModelSettingsFileTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "model-settings-\(UUID().uuidString)/model-settings.json"
    }

    func testRoundTripKeepsOnlySetFieldsAndTrimsTheSlash() throws {
        let path = tempPath()
        var file = ModelSettingsFile.load(path: path)
        XCTAssertTrue(file.isEmpty)
        file.set(ModelOverride(ctxSize: 65_536, kvQuant: .bits8, mtp: false), for: "/m/a/")
        try file.save(path: path)

        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"ctx_size\" : 65536"), text)
        XCTAssertTrue(text.contains("\"kv_quant\" : \"8\""), text)
        XCTAssertTrue(text.contains("\"mtp\" : false"), text)
        XCTAssertTrue(text.contains("\"/m/a\""), "trailing slash must be trimmed: \(text)")

        let back = ModelSettingsFile.load(path: path)
        XCTAssertEqual(back.override(for: "/m/a"), ModelOverride(ctxSize: 65_536, kvQuant: .bits8, mtp: false))
        XCTAssertEqual(back.override(for: "/m/a/"), back.override(for: "/m/a"))
        XCTAssertNil(back.override(for: "/m/b"))
    }

    func testMtpAcceptanceRoundTripsByName() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        file.set(ModelOverride(mtp: true, mtpAcceptance: .typical), for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"mtp_acceptance\" : \"typical\""), text)
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/a")?.mtpAcceptance, .typical)
        XCTAssertEqual(ModelOverride(json: ["mtp_acceptance": "fast"]).mtpAcceptance, nil)
    }

    func testMtpGreedyTailRoundTripsAsABoolean() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        file.set(ModelOverride(mtpGreedyTail: true), for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"mtp_greedy_tail\" : true"), text)
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/a")?.mtpGreedyTail, true)
        XCTAssertNil(ModelOverride(json: ["mtp_greedy_tail": "yes"]).mtpGreedyTail)
    }

    func testInt8PrefillRoundTripsAsABoolean() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        file.set(ModelOverride(int8Prefill: true), for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"int8_prefill\" : true"), text)
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/a")?.int8Prefill, true)
        XCTAssertNil(ModelOverride(json: ["int8_prefill": "yes"]).int8Prefill)
    }

    func testAneRoundTripsAsABoolean() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        var o = ModelOverride()
        o.ane = true
        file.set(o, for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"ane\" : true"), text)
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/a")?.ane, true)
        XCTAssertNil(ModelOverride(json: ["ane": "yes"]).ane)
        XCTAssertTrue(o.changesLoad(from: ModelOverride()), "the engine is chosen at load")
    }

    func testTheEnginePickerWritesEngineAndRetiresTheAneSwitch() throws {
        var o = ModelOverride(json: ["ane": true])
        XCTAssertEqual(o.engineChoice, "ane", "an older file's switch reads as the engine")
        XCTAssertEqual(ModelOverride(json: ["ane": false]).engineChoice, "mlx")
        o.engineChoice = "mlx"
        XCTAssertEqual(o.json["engine"] as? String, "mlx")
        XCTAssertNil(o.json["ane"], "one key decides")
        o.engineChoice = nil
        XCTAssertTrue(o.isEmpty)
        XCTAssertEqual(ModelOverride(json: ["engine": "llama"]).engineChoice, "llama")
        XCTAssertTrue(ModelOverride(json: ["engine": "ds4"]).changesLoad(from: ModelOverride()))
    }

    /// `chat_template_kwargs` round-trips as one object: the rows the sheet
    /// edits are exactly what the server reads, typed values kept.
    func testChatTemplateKwargsRoundTripAsOneObject() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try """
        {"/m/a": {"chat_template_kwargs": {"preserve_thinking": true, "other": 1}}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        var file = ModelSettingsFile.load(path: path)
        var o = file.override(for: "/m/a")!
        XCTAssertEqual(o.templateKwargs["preserve_thinking"] as? Bool, true)
        XCTAssertTrue(o.hasSettings)

        o.templateKwargs["preserve_thinking"] = false
        o.templateKwargs["other"] = nil
        file.set(o, for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"preserve_thinking\" : false"), text)
        XCTAssertFalse(text.contains("other"), text)

        o.templateKwargs = [:]
        file.set(o, for: "/m/a")
        try file.save(path: path)
        XCTAssertTrue(ModelSettingsFile.load(path: path).isEmpty)
    }

    func testAnEmptyOverrideRemovesTheEntry() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        file.set(ModelOverride(ctxSize: 4096), for: "/m/a")
        file.set(ModelOverride(), for: "/m/a")
        try file.save(path: path)
        XCTAssertTrue(ModelSettingsFile.load(path: path).isEmpty)
    }

    /// A future server field must survive an app-side edit of another model.
    func testUnknownKeysSurviveASave() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try """
        {"/m/a": {"ctx_size": 8192, "prefix_cache_mem": 123}, "/m/b": {"mtp": true}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        var file = ModelSettingsFile.load(path: path)
        XCTAssertEqual(file.override(for: "/m/a")?.ctxSize, 8192)
        XCTAssertEqual(file.override(for: "/m/b")?.mtp, true)
        file.set(ModelOverride(ctxSize: 8192, kvQuant: .off), for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"prefix_cache_mem\" : 123"), text)
        XCTAssertTrue(text.contains("\"kv_quant\" : \"off\""), text)
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/b")?.mtp, true)
    }

    func testAMalformedFileLoadsEmptyAndABadValueIsIgnored() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try "{nope".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(ModelSettingsFile.load(path: path).isEmpty)
        try #"{"/m/a": {"kv_quant": "16", "ctx_size": "big"}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(ModelSettingsFile.load(path: path).override(for: "/m/a"))
    }

    /// `alias` is the server's request name for the model: it round-trips,
    /// an alias alone keeps the entry, and a taken or malformed name is refused.
    func testAliasRoundTripsAndIsValidated() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        var o = ModelOverride()
        o.alias = "qwen"
        XCTAssertTrue(o.hasSettings)
        file.set(o, for: "/m/a/")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"alias\" : \"qwen\""), text)
        let back = ModelSettingsFile.load(path: path)
        XCTAssertEqual(back.override(for: "/m/a")?.alias, "qwen")
        XCTAssertEqual(back.pathUsingAlias("qwen", except: "/m/b"), "/m/a")
        XCTAssertNil(back.pathUsingAlias("qwen", except: "/m/a/"))

        for bad in ["", "mlx-serve", "x@peer", "org/x", "two words", "a\"b"] {
            XCTAssertFalse(ModelOverride.isValidAlias(bad), bad)
        }
        XCTAssertTrue(ModelOverride.isValidAlias("qwen3.6-27b:4bit"))
    }

    /// The server reads the alias per request, so an alias-only edit never
    /// reloads the model.
    func testAnAliasOnlyEditNeedsNoReload() {
        var before = ModelOverride(ctxSize: 8192)
        var after = before
        after.alias = "q"
        XCTAssertFalse(after.changesLoad(from: before))
        after.ctxSize = 4096
        XCTAssertTrue(after.changesLoad(from: before))
        before.extra["future"] = 1
        XCTAssertTrue(ModelOverride(ctxSize: 8192).changesLoad(from: before))
    }

    /// `ablation` round-trips by the server's keys, an entry holding only it
    /// is kept, and the server reads it per request, so it never reloads.
    func testAblationRoundTripsAndNeedsNoReload() throws {
        let path = tempPath()
        var file = ModelSettingsFile()
        var o = ModelOverride()
        o.ablation = AblationSetting(profile: "refusal", strength: 0.5, prefixCache: "shared")
        XCTAssertFalse(o.isEmpty)
        file.set(o, for: "/m/a")
        try file.save(path: path)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        let stored = (root?["/m/a"] as? [String: Any])?["ablation"] as? [String: Any]
        XCTAssertEqual(stored?["profile"] as? String, "refusal")
        XCTAssertEqual(stored?["strength"] as? Double, 0.5)
        XCTAssertEqual(stored?["prefix_cache"] as? String, "shared")
        XCTAssertEqual(ModelSettingsFile.load(path: path).override(for: "/m/a")?.ablation, o.ablation)

        var off = o
        off.ablation?.strength = 0
        XCTAssertNotEqual(off, o)
        XCTAssertFalse(off.changesLoad(from: o))
        XCTAssertFalse(ModelOverride().changesLoad(from: o))
        XCTAssertFalse(o.changesLoad(from: ModelOverride()))
        XCTAssertEqual(ModelOverride(json: ["ablation": ["profile": "p"]]).ablation,
                       AblationSetting(profile: "p", strength: 1, prefixCache: nil), "strength defaults to 1")
    }

    /// An `ablation` the app cannot write back whole stays verbatim, like an
    /// unknown key: a save keeps it and the server names what is wrong.
    func testAnUnreadableAblationIsKeptVerbatim() throws {
        let bad: [Any] = ["p", ["profile": 7], ["strength": 1], ["profile": ""], ["profile": "p", "strength": 1.5],
                          ["profile": "p", "strength": true], ["profile": "p", "prefix_cache": 1],
                          ["profile": "p", "prefix_cache": "warm"], ["profile": "p", "layers": [1]]]
        for value in bad {
            let o = ModelOverride(json: ["ablation": value])
            XCTAssertNil(o.ablation, "\(value)")
            XCTAssertNotNil(o.extra["ablation"], "\(value)")
        }

        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #"{"/m/a": {"ctx_size": 4096, "ablation": {"profile": "p", "strength": 2}}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        var file = ModelSettingsFile.load(path: path)
        var o = try XCTUnwrap(file.override(for: "/m/a"))
        o.ctxSize = 8192
        file.set(o, for: "/m/a")
        try file.save(path: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"strength\" : 2"), text)
        XCTAssertTrue(text.contains("\"ctx_size\" : 8192"), text)
    }

    /// The menu bar writes only `ablation`: every other key stays as the file
    /// has it, and nil removes it (an unreadable one too) with an entry it leaves empty.
    func testSetAblationReplacesOnlyThatKey() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try #"{"/m/a": {"ctx_size": 8192, "future": 1, "ablation": {"profile": "p", "strength": 2}}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        var file = ModelSettingsFile.load(path: path)
        let set = AblationSetting(profile: "q", strength: 0.25, prefixCache: "isolated")
        file.setAblation(set, for: "/m/a/")
        try file.save(path: path)
        var back = ModelSettingsFile.load(path: path)
        XCTAssertEqual(back.override(for: "/m/a")?.ablation, set)
        XCTAssertEqual(back.override(for: "/m/a")?.ctxSize, 8192)
        XCTAssertEqual(back.override(for: "/m/a")?.extra["future"] as? Int, 1)

        back.setAblation(nil, for: "/m/a")
        back.setAblation(AblationSetting(profile: "p"), for: "/m/b")
        try back.save(path: path)
        var text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("\"q\""), text)
        XCTAssertTrue(text.contains("\"ctx_size\" : 8192"), text)
        XCTAssertTrue(text.contains("\"/m/b\""), "an entry holding only ablation is kept: \(text)")

        var again = ModelSettingsFile.load(path: path)
        again.setAblation(nil, for: "/m/b")
        try again.save(path: path)
        text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains("/m/b"), text)

        try #"{"/m/c": {"ablation": "p"}}"#.write(toFile: path, atomically: true, encoding: .utf8)
        var unreadable = ModelSettingsFile.load(path: path)
        unreadable.setAblation(nil, for: "/m/c")
        try unreadable.save(path: path)
        XCTAssertTrue(ModelSettingsFile.load(path: path).isEmpty)
    }

    /// The overflow card's button goes to the per-model sheet only when that
    /// model already has overrides; otherwise Settings, as before.
    func testContextIncreaseTarget() {
        XCTAssertEqual(ContextIncreaseTarget.resolve(hasOverride: true), .modelSettings)
        XCTAssertEqual(ContextIncreaseTarget.resolve(hasOverride: false), .appSettings)
    }
}

/// The gauge and the turn budget read the context the SERVER advertises for
/// the live model; it already reflects `--ctx-size` and, now, the per-model
/// override. The slider is only the answer while no server has reported one.
final class EffectiveContextLengthTests: XCTestCase {
    @MainActor func testTheLiveModelOutranksTheGlobalSlider() {
        XCTAssertEqual(AgentEngine.effectiveContextLength(appContextSize: 16_384, modelContextLength: 65_536), 65_536)
        XCTAssertEqual(AgentEngine.effectiveContextLength(appContextSize: 16_384, modelContextLength: nil), 16_384)
        XCTAssertEqual(AgentEngine.effectiveContextLength(appContextSize: 0, modelContextLength: 0), 32_768)
    }
}
