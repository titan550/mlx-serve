//! A request's directional ablation (`abi.Ablation`), resolved by the host from a profile the server loaded at launch.

const std = @import("std");

pub const Request = struct {
    /// The profile's unit direction, `[hidden]` f32; owned by the server's profile set, which outlives every request.
    direction: []const f32,
    /// In [0, 30]: 0 never reaches the engine (the request runs as a standard one); above 1 an ablation overrides a
    /// built-in behaviour the model holds strongly (measured: 1 leaves most refusals standing, 3-4 clears them).
    strength: f32,
    /// The profile's content hash with the strength folded in (`abi.Ablation.key`).
    key: u64,
    prefix: Prefix = .isolated,
};

/// How an ablated request shares the prefix cache with unablated ones. `isolated`: it restores and commits nothing
/// beside them (a module-owned cache keys its own entries by `key`). `shared`: it reads and writes the one cache as
/// if unablated, so a later request may restore state computed under the ablation.
pub const Prefix = enum { isolated, shared };

/// The strongest ablation a request or a model setting may ask for. Above 1 the projection removes more than the
/// component along the direction, which is what overriding a strongly held behaviour takes; 30 is far past any
/// measurement and keeps a typo from clearing the whole stream.
pub const max_strength: f32 = 30;

/// A model setting's `ablation` object (`~/.mlx-serve/model-settings.json`), which adds `prefix` to what a request
/// names; a request's own field is parsed in `host/api/ablation.zig`, upstream's shape. `profile` borrows from the JSON.
/// A profile and the strength asked for it; null strength = the profile's own default (its manifest's `strength`).
pub const Field = struct { profile: []const u8, strength: ?f32 = null, prefix: ?Prefix = null };

pub const Parsed = union(enum) { ok: Field, bad: []const u8 };

/// A model setting's `ablation` object (a request's own field is parsed by `host/api/ablation.zig`, upstream's shape):
/// `profile`, `strength`, and `prefix_cache`, which is a setting's to choose.
pub fn parseSetting(v: std.json.Value, msg_buf: []u8) Parsed {
    if (v != .object) return .{ .bad = "ablation must be an object {\"profile\": string, \"strength\": number}" };
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const known = for ([_][]const u8{ "profile", "strength", "prefix_cache" }) |k| {
            if (std.mem.eql(u8, kv.key_ptr.*, k)) break true;
        } else false;
        if (!known) return .{ .bad = std.fmt.bufPrint(msg_buf, "unknown field 'ablation.{s}'", .{kv.key_ptr.*[0..@min(kv.key_ptr.len, 64)]}) catch "unknown field in ablation" };
    }
    const name_v = v.object.get("profile") orelse return .{ .bad = "ablation.profile is required" };
    if (name_v != .string) return .{ .bad = "ablation.profile must be a string" };
    const strength: ?f32 = if (v.object.get("strength")) |sv| switch (sv) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => return .{ .bad = "ablation.strength must be a number in [0, 30]" },
    } else null;
    if (strength) |st| if (!(st >= 0 and st <= max_strength)) return .{ .bad = "ablation.strength must be a number in [0, 30]" };
    const prefix: ?Prefix = if (v.object.get("prefix_cache")) |pv| blk: {
        if (pv == .string) if (std.meta.stringToEnum(Prefix, pv.string)) |p| break :blk p;
        return .{ .bad = "ablation.prefix_cache must be \"isolated\" or \"shared\"" };
    } else null;
    return .{ .ok = .{ .profile = name_v.string, .strength = strength, .prefix = prefix } };
}
