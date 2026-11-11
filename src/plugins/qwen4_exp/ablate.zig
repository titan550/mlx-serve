//! Directional ablation (`Caps.ablation`, Arditi et al. 2024) on the trunk's residual writes: the embedding, the PLE add
//! and every attention, GatedDeltaNet and MoE output lose their slot's strength times their component along the slot's
//! direction before they reach the streams. A deferred write carries the projection into the fused read
//! (`hc_decode2.Ablate`); every other write projects through `hc_decode2.ablateOut`, so both round once, in f32.

const std = @import("std");
const mlx = @import("../../mlx/ffi.zig");
const abi = @import("../../abi/plugin.zig");
const hc_decode2 = @import("../../sdk/blocks/hc/hc_decode2.zig");
const Request = @import("../../sdk/request/ablation.zig").Request;

/// One forward's ablation, one slot per batch row: `dirs` [slots, hidden] unit directions and `strengths` [slots], f32.
pub const Ablation = struct {
    dirs: mlx.mlx_array,
    strengths: mlx.mlx_array,
    /// `dirs` is ours to free (built here, or a slice), not the host's table.
    owns_dirs: bool,

    /// The forward's table (its directions borrowed: the host's, valid for the call); null when no slot is ablated.
    pub fn fromForward(f: *const abi.Forward) !?Ablation {
        const a = f.ablation orelse return null;
        const st = a.strengths.slice();
        if (a.directions.ctx == null or !anyNonzero(st)) return null;
        const strengths = mlx.mlx_array_new_data(st.ptr, &[_]c_int{@intCast(st.len)}, 1, .float32);
        if (strengths.ctx == null) return error.OutOfMemory;
        return .{ .dirs = .{ .ctx = a.directions.ctx }, .strengths = strengths, .owns_dirs = false };
    }

    /// The engine contexts' requests, on the paths the engine calls the trunk by symbol (the grouped verify and its
    /// per-row fallback); a slot without one gets a zero row at strength 0. Null when none is ablated.
    pub fn fromRequests(a: std.mem.Allocator, reqs: []const ?Request, hidden: usize) !?Ablation {
        var any = false;
        for (reqs) |r| any = any or (r != null and r.?.strength != 0);
        if (!any) return null;
        const rows = try a.alloc(f32, reqs.len * hidden);
        defer a.free(rows);
        const st = try a.alloc(f32, reqs.len);
        defer a.free(st);
        for (reqs, 0..) |r, i| {
            const dst = rows[i * hidden ..][0..hidden];
            if (r) |req| {
                if (req.direction.len != hidden) return error.AblationWidth;
                @memcpy(dst, req.direction);
                st[i] = req.strength;
            } else {
                @memset(dst, 0);
                st[i] = 0;
            }
        }
        const dirs = mlx.mlx_array_new_data(rows.ptr, &[_]c_int{ @intCast(reqs.len), @intCast(hidden) }, 2, .float32);
        if (dirs.ctx == null) return error.OutOfMemory;
        errdefer _ = mlx.mlx_array_free(dirs);
        const strengths = mlx.mlx_array_new_data(st.ptr, &[_]c_int{@intCast(reqs.len)}, 1, .float32);
        if (strengths.ctx == null) return error.OutOfMemory;
        return .{ .dirs = dirs, .strengths = strengths, .owns_dirs = true };
    }

    /// Slot `i` alone, for a forward that runs one slot of the batch.
    pub fn slot(self: *const Ablation, s: mlx.mlx_stream, i: usize) !Ablation {
        const hidden = mlx.getShape(self.dirs)[1];
        const k: c_int = @intCast(i);
        var dirs = mlx.mlx_array_new();
        errdefer _ = mlx.mlx_array_free(dirs);
        try mlx.check(mlx.mlx_slice(&dirs, self.dirs, &[_]c_int{ k, 0 }, 2, &[_]c_int{ k + 1, hidden }, 2, &[_]c_int{ 1, 1 }, 2, s));
        var strengths = mlx.mlx_array_new();
        errdefer _ = mlx.mlx_array_free(strengths);
        try mlx.check(mlx.mlx_slice(&strengths, self.strengths, &[_]c_int{k}, 1, &[_]c_int{k + 1}, 1, &[_]c_int{1}, 1, s));
        return .{ .dirs = dirs, .strengths = strengths, .owns_dirs = true };
    }

    pub fn deinit(self: *Ablation) void {
        if (self.owns_dirs) _ = mlx.mlx_array_free(self.dirs);
        _ = mlx.mlx_array_free(self.strengths);
    }

    /// The deferred write's form: `per` rows per slot (a forward's `seq_len`).
    pub fn pending(self: *const Ablation, per: c_int) hc_decode2.Ablate {
        return .{ .dirs = self.dirs, .strengths = self.strengths, .per = per };
    }

    /// Replaces `x` [B, S, streams * hidden] (B the slots) by its projection, every stream's slice on its own.
    pub fn apply(self: *const Ablation, s: mlx.mlx_stream, x: *mlx.mlx_array, streams: c_int) !void {
        const shape = mlx.getShape(x.*);
        const hidden = @divExact(shape[shape.len - 1], streams);
        var rows = mlx.mlx_array_new();
        defer _ = mlx.mlx_array_free(rows);
        try mlx.check(mlx.mlx_reshape(&rows, x.*, &[_]c_int{ shape[0], -1, hidden }, 3, s));
        const projected = try hc_decode2.ablateOut(s, rows, self.pending(1));
        defer _ = mlx.mlx_array_free(projected);
        var next = mlx.mlx_array_new();
        errdefer _ = mlx.mlx_array_free(next);
        try mlx.check(mlx.mlx_reshape(&next, projected, shape.ptr, @intCast(shape.len), s));
        _ = mlx.mlx_array_free(x.*);
        x.* = next;
    }
};

fn anyNonzero(st: []const f32) bool {
    for (st) |v| if (v != 0) return true;
    return false;
}

/// A cluster pair runs layers or expert halves this forward never sees: an ablated request is refused there.
pub fn servesAcross(pipeline_peer: bool, tensor_peer: bool) bool {
    return !pipeline_peer and !tensor_peer;
}

// ── tests ──

const testing = std.testing;

test "qwen4 ablation: a request set with no nonzero strength runs plain; a slot without one is a zero row" {
    try testing.expect((try Ablation.fromRequests(testing.allocator, &.{ null, null }, 4)) == null);
    const zero: Request = .{ .direction = &.{ 1, 0, 0, 0 }, .strength = 0, .key = 3 };
    try testing.expect((try Ablation.fromRequests(testing.allocator, &.{zero}, 4)) == null);
    if (mlx.noGpuBackend()) return error.SkipZigTest;
    const one: Request = .{ .direction = &.{ 0, 1, 0, 0 }, .strength = 0.5, .key = 7 };
    var got = (try Ablation.fromRequests(testing.allocator, &.{ null, one }, 4)).?;
    defer got.deinit();
    try testing.expectEqualSlices(c_int, &.{ 2, 4 }, mlx.getShape(got.dirs));
    try mlx.check(mlx.mlx_array_eval(got.dirs));
    try mlx.check(mlx.mlx_array_eval(got.strengths));
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0, 1, 0, 0 }, mlx.mlx_array_data_float32(got.dirs).?[0..8]);
    try testing.expectEqualSlices(f32, &.{ 0, 0.5 }, mlx.mlx_array_data_float32(got.strengths).?[0..2]);
    try testing.expectError(error.AblationWidth, Ablation.fromRequests(testing.allocator, &.{one}, 3));
}

test "qwen4 ablation: a Thunderbolt pair of either kind refuses an ablated forward" {
    try testing.expect(servesAcross(false, false));
    try testing.expect(!servesAcross(true, false));
    try testing.expect(!servesAcross(false, true));
}
