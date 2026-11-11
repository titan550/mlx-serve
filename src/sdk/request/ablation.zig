//! A request's directional ablation (`abi.Ablation`), resolved by the host from a profile the server loaded at launch.

const std = @import("std");

pub const Request = struct {
    /// The profile's unit direction, `[hidden]` f32; owned by the server's profile set, which outlives every request.
    direction: []const f32,
    /// In (0, 1]: a strength of 0 never reaches the engine (the request runs as a standard one).
    strength: f32,
    /// The profile's content hash with the strength folded in (`abi.Ablation.key`).
    key: u64,
    prefix: Prefix = .isolated,
};

/// How an ablated request shares the prefix cache with unablated ones. `isolated`: it restores and commits nothing
/// beside them (a module-owned cache keys its own entries by `key`). `read`: it restores unablated KV prefix-cache
/// entries, by copy, and commits none (a module-owned cache keeps `isolated`). `shared`: it reads and writes the one
/// cache as if unablated, so a later request may restore state computed under the ablation.
pub const Prefix = enum { isolated, read, shared };

/// An `ablation` object as a request body or a model setting spells it; `profile` borrows from the JSON.
pub const Field = struct { profile: []const u8, strength: f32 = 1, prefix: ?Prefix = null };

pub const Parsed = union(enum) { ok: Field, bad: []const u8 };

/// `v` read as an `ablation` object, or the message naming what is wrong (static, or in `msg_buf`).
pub fn parseField(v: std.json.Value, msg_buf: []u8) Parsed {
    if (v != .object) return .{ .bad = "ablation must be an object {\"profile\": string, \"strength\": number, \"prefix_cache\": string}" };
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const known = for ([_][]const u8{ "profile", "strength", "prefix_cache" }) |k| {
            if (std.mem.eql(u8, kv.key_ptr.*, k)) break true;
        } else false;
        const name = kv.key_ptr.*[0..@min(kv.key_ptr.len, 64)];
        if (!known) return .{ .bad = std.fmt.bufPrint(msg_buf, "unknown field 'ablation.{s}'", .{name}) catch "unknown field in ablation" };
    }
    const name_v = v.object.get("profile") orelse return .{ .bad = "ablation.profile is required" };
    if (name_v != .string) return .{ .bad = "ablation.profile must be a string" };
    const strength: f32 = if (v.object.get("strength")) |sv| switch (sv) {
        .float => |f| @floatCast(f),
        .integer => |i| if (i >= 0 and i <= 1) @floatFromInt(i) else -1,
        else => return .{ .bad = "ablation.strength must be a number in [0, 1]" },
    } else 1.0;
    if (!(strength >= 0 and strength <= 1)) return .{ .bad = "ablation.strength must be a number in [0, 1]" };
    const prefix: ?Prefix = if (v.object.get("prefix_cache")) |pv| blk: {
        if (pv == .string) if (std.meta.stringToEnum(Prefix, pv.string)) |p| break :blk p;
        return .{ .bad = "ablation.prefix_cache must be \"isolated\", \"read\" or \"shared\"" };
    } else null;
    return .{ .ok = .{ .profile = name_v.string, .strength = strength, .prefix = prefix } };
}

test "ablation field: the three keys, their defaults, and each malformed value named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [128]u8 = undefined;
    const full = parseField(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"profile\":\"p\",\"strength\":0.5,\"prefix_cache\":\"read\"}", .{}), &buf);
    try std.testing.expectEqualStrings("p", full.ok.profile);
    try std.testing.expectEqual(@as(f32, 0.5), full.ok.strength);
    try std.testing.expectEqual(@as(?Prefix, .read), full.ok.prefix);
    const bare = parseField(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"profile\":\"p\"}", .{}), &buf);
    try std.testing.expect(bare.ok.strength == 1 and bare.ok.prefix == null);
    const cases = [_][2][]const u8{
        .{ "7", "must be an object" },
        .{ "{\"profile\":\"p\",\"strenght\":1}", "unknown field 'ablation.strenght'" },
        .{ "{\"strength\":1}", "profile is required" },
        .{ "{\"profile\":1}", "must be a string" },
        .{ "{\"profile\":\"p\",\"strength\":2}", "[0, 1]" },
        .{ "{\"profile\":\"p\",\"prefix_cache\":\"warm\"}", "prefix_cache must be" },
    };
    for (cases) |c| {
        const got = parseField(try std.json.parseFromSliceLeaky(std.json.Value, a, c[0], .{}), &buf);
        try std.testing.expect(std.mem.indexOf(u8, got.bad, c[1]) != null);
    }
}
