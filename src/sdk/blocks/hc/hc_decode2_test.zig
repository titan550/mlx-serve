//! `hc_decode2.zig`'s tests, out of its import graph: a plugin unit that reaches `hc_decode2.zig` never compiles them.

const hc_decode2 = @import("hc_decode2.zig");
const std = @import("std");
const mlx = @import("../../../mlx/ffi.zig");
const upVectorized = hc_decode2.upVectorized;
const testing = std.testing;

fn randBf16(rnd: std.Random, shape: []const c_int, scale: f32, offset: f32, s: mlx.mlx_stream) !mlx.mlx_array {
    var n: usize = 1;
    for (shape) |d| n *= @intCast(d);
    const buf = try testing.allocator.alloc(f32, n);
    defer testing.allocator.free(buf);
    for (buf) |*v| v.* = (rnd.float(f32) - 0.5) * scale + offset;
    const f = mlx.mlx_array_new_data(buf.ptr, shape.ptr, @intCast(shape.len), .float32);
    defer _ = mlx.mlx_array_free(f);
    var out = mlx.mlx_array_new();
    try mlx.check(mlx.mlx_astype(&out, f, .bfloat16, s));
    return out;
}

const Q = struct {
    w: mlx.mlx_array,
    s: mlx.mlx_array,
    b: mlx.mlx_array,
    fn deinit(q: Q) void {
        _ = mlx.mlx_array_free(q.w);
        _ = mlx.mlx_array_free(q.s);
        _ = mlx.mlx_array_free(q.b);
    }
};

fn quantRandom(rnd: std.Random, rows: c_int, cols: c_int, bits: u32, gs: u32, s: mlx.mlx_stream) !Q {
    const w = try randBf16(rnd, &.{ rows, cols }, 0.2, 0.0, s);
    defer _ = mlx.mlx_array_free(w);
    var triple = mlx.mlx_vector_array_new();
    defer _ = mlx.mlx_vector_array_free(triple);
    try mlx.check(mlx.mlx_quantize(&triple, w, mlx.mlx_optional_int.some(@intCast(gs)), mlx.mlx_optional_int.some(@intCast(bits)), "affine", .{}, s));
    var q: Q = .{ .w = mlx.mlx_array_new(), .s = mlx.mlx_array_new(), .b = mlx.mlx_array_new() };
    try mlx.check(mlx.mlx_vector_array_get(&q.w, triple, 0));
    try mlx.check(mlx.mlx_vector_array_get(&q.s, triple, 1));
    try mlx.check(mlx.mlx_vector_array_get(&q.b, triple, 2));
    return q;
}

fn readF32(a: mlx.mlx_array, s: mlx.mlx_stream) ![]f32 {
    var f = mlx.mlx_array_new();
    defer _ = mlx.mlx_array_free(f);
    try mlx.check(mlx.mlx_astype(&f, a, .float32, s));
    try mlx.check(mlx.mlx_array_eval(f));
    const n = mlx.mlx_array_size(f);
    const out = try testing.allocator.alloc(f32, n);
    @memcpy(out, (mlx.mlx_array_data_float32(f) orelse return error.Unreadable)[0..n]);
    return out;
}

/// Per element within a couple of bf16 ulps (the f32 accumulation order is the only difference), on every output.
fn expectClose(ref: mlx.mlx_array, got: mlx.mlx_array, s: mlx.mlx_stream) !void {
    const rh = try readF32(ref, s);
    defer testing.allocator.free(rh);
    const gh = try readF32(got, s);
    defer testing.allocator.free(gh);
    try testing.expectEqual(rh.len, gh.len);
    var dot: f64 = 0;
    var nr: f64 = 0;
    var ng: f64 = 0;
    for (rh, gh) |r, g| {
        try testing.expect(std.math.isFinite(g));
        dot += @as(f64, r) * g;
        nr += @as(f64, r) * r;
        ng += @as(f64, g) * g;
        try testing.expect(@abs(r - g) <= 0.02 * @abs(r) + 0.008);
    }
    try testing.expect(dot / @sqrt(nr * ng) >= 0.9999);
}

/// Row `row` of `a`, whose dim 1 holds the rows (rank 3: [1,rows,n], rank 4: [1,rows,n,1]).
fn sliceRow(a: mlx.mlx_array, row: c_int, s: mlx.mlx_stream) !mlx.mlx_array {
    const shape = mlx.getShape(a);
    var start: [4]c_int = @splat(0);
    var stop: [4]c_int = @splat(1);
    @memcpy(stop[0..shape.len], shape);
    start[1] = row;
    stop[1] = row + 1;
    var out = mlx.mlx_array_new();
    errdefer _ = mlx.mlx_array_free(out);
    try mlx.check(mlx.mlx_slice(&out, a, &start, shape.len, &stop, shape.len, &[_]c_int{ 1, 1, 1, 1 }, shape.len, s));
    return out;
}

/// A `rows`-row read agrees, row by row, with each row read alone through the one-row launches.
/// A row read among others is byte-identical to the same row read alone: a grouped verify must not change a row's output.
fn expectEqualBits(ref: mlx.mlx_array, got: mlx.mlx_array, s: mlx.mlx_stream) !void {
    const rh = try readF32(ref, s);
    defer testing.allocator.free(rh);
    const gh = try readF32(got, s);
    defer testing.allocator.free(gh);
    try testing.expectEqualSlices(f32, rh, gh);
}

fn parityRows(h: c_int, r: c_int, bits: u32, gs: u32, seed: u64, rows: c_int) !void {
    const xfm = @import("../../../engines/mlx/transformer.zig");
    const s = mlx.gpuStream();
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const hcf = @import("../../../plugins/qwen4_exp/hc_fused.zig");
    hcf.hc_fused_override = true;
    defer hcf.hc_fused_override = null;
    hc_decode2.rows_override = rows;
    defer hc_decode2.rows_override = null;
    const hc: c_int = 4;
    const k = hc * h;
    const down = try quantRandom(rnd, r, k, bits, gs, s);
    defer down.deinit();
    const up = try quantRandom(rnd, k, r, bits, gs, s);
    defer up.deinit();
    // The weight stays lazy on purpose: the launch choice must not depend on whether an earlier read evaluated it.
    const x = try randBf16(rnd, &.{ 1, rows, k }, 4.0, 0.0, s);
    defer _ = mlx.mlx_array_free(x);
    const nw = try randBf16(rnd, &.{ hc, h }, 1.0, 1.0, s);
    defer _ = mlx.mlx_array_free(nw);
    const iw = try randBf16(rnd, &.{ k, hc }, 0.1, 0.0, s);
    defer _ = mlx.mlx_array_free(iw);
    const wo = try randBf16(rnd, &.{ 1, rows, h }, 2.0, 0.0, s);
    defer _ = mlx.mlx_array_free(wo);
    const wi = try randBf16(rnd, &.{ 1, rows, hc, 1 }, 1.0, 1.0, s);
    defer _ = mlx.mlx_array_free(wi);

    const cases = [_]struct { inject: bool, pending: bool }{ .{ .inject = true, .pending = false }, .{ .inject = true, .pending = true }, .{ .inject = false, .pending = false } };
    for (cases) |c| {
        const inj_w: mlx.mlx_array = if (c.inject) iw else .{ .ctx = null };
        const pend: ?xfm.HcPending = if (c.pending) .{ .out = wo, .inj = wi } else null;
        const before = hc_decode2.served;
        const before_vec = hc_decode2.served_vec;
        const got = (try xfm.hcReadFused(s, x, 1, rows, nw, down.w, down.s, down.b, up.w, up.s, up.b, inj_w, 1e-6, hc, h, bits, gs, pend)) orelse return error.HcFusedDeclined;
        defer {
            _ = mlx.mlx_array_free(got.mixed);
            if (got.inj.ctx != null) _ = mlx.mlx_array_free(got.inj);
            if (got.stream.ctx != null) _ = mlx.mlx_array_free(got.stream);
        }
        try testing.expectEqual(before + 1, hc_decode2.served);
        try testing.expectEqual(before_vec + @intFromBool(upVectorized(rows, 4, r, bits, @intCast(gs))), hc_decode2.served_vec);
        try testing.expect((got.inj.ctx != null) == c.inject);
        try testing.expect((got.stream.ctx != null) == c.pending);
        var row: c_int = 0;
        while (row < rows) : (row += 1) {
            const xr = try sliceRow(x, row, s);
            defer _ = mlx.mlx_array_free(xr);
            const wor = try sliceRow(wo, row, s);
            defer _ = mlx.mlx_array_free(wor);
            const wir = try sliceRow(wi, row, s);
            defer _ = mlx.mlx_array_free(wir);
            const one_pend: ?xfm.HcPending = if (c.pending) .{ .out = wor, .inj = wir } else null;
            const one = (try xfm.hcReadFused(s, xr, 1, 1, nw, down.w, down.s, down.b, up.w, up.s, up.b, inj_w, 1e-6, hc, h, bits, gs, one_pend)) orelse return error.HcFusedDeclined;
            defer {
                _ = mlx.mlx_array_free(one.mixed);
                if (one.inj.ctx != null) _ = mlx.mlx_array_free(one.inj);
                if (one.stream.ctx != null) _ = mlx.mlx_array_free(one.stream);
            }
            inline for (.{ "mixed", "inj", "stream" }) |name| {
                if (@field(got, name).ctx != null) {
                    const part = try sliceRow(@field(got, name), row, s);
                    defer _ = mlx.mlx_array_free(part);
                    try expectEqualBits(@field(one, name), part, s);
                }
            }
        }
    }
}

test "hc decode2: a multi-row read matches each row read alone (Flash Next geometry, 8-bit, vectorized up launch)" {
    for ([_]c_int{ 2, 6, 9, 16 }) |rows| try parityRows(2560, 320, 8, 64, 0x2D0DE9 + @as(u64, @intCast(rows)), rows);
}

test "hc decode2: a multi-row read matches each row read alone (4/5/6-bit, per-row up launch)" {
    try parityRows(512, 64, 4, 64, 0x2D0DE4, 3);
    for ([_]u32{ 5, 6 }) |bits| try parityRows(2560, 320, bits, 64, 0x2D0DE5 + bits, 5);
}

/// Unit-norm f32 directions, one row of `h` per slot, and the host copy.
fn unitDirections(rnd: std.Random, slots: usize, h: usize) !struct { arr: mlx.mlx_array, host: []f32 } {
    const buf = try testing.allocator.alloc(f32, slots * h);
    errdefer testing.allocator.free(buf);
    for (0..slots) |r| {
        const row = buf[r * h ..][0..h];
        var ss: f64 = 0;
        for (row) |*v| {
            v.* = rnd.float(f32) - 0.5;
            ss += @as(f64, v.*) * v.*;
        }
        const inv: f32 = @floatCast(1 / @sqrt(ss));
        for (row) |*v| v.* *= inv;
    }
    return .{ .arr = mlx.mlx_array_new_data(buf.ptr, &[_]c_int{ @intCast(slots), @intCast(h) }, 2, .float32), .host = buf };
}

/// `v` rounded to bf16, as the kernel's `T(...)` and the chain's final cast round.
fn rtBf16(v: f64) f64 {
    return @import("../../testing/kernel_contract/host.zig").rt(.bfloat16, v);
}

/// `wo` with each row's component along its slot's direction removed, `strengths[slot]` times, in float64 and rounded to
/// bf16 once; `cs` gets each row's coefficient.
fn ablatedRef(woh: []const f32, dh: []const f32, sh: []const f32, h: usize, per: usize, out: []f64, cs: []f64) void {
    for (0..woh.len / h) |row| {
        const slot = row / per;
        var dot: f64 = 0;
        for (0..h) |i| dot += @as(f64, woh[row * h + i]) * dh[slot * h + i];
        cs[row] = dot * sh[slot];
        for (0..h) |i| out[row * h + i] = rtBf16(woh[row * h + i] - cs[row] * dh[slot * h + i]);
    }
}

/// One bf16 ulp of `want`, plus what the device's f32 coefficient can move a value by.
fn withinUlp(want: f64, got: f64, cs: f64, d: f64) bool {
    return @abs(want - got) <= 0x1p-7 * @abs(want) + 0x1p-7 * @abs(cs * d) + 1e-6;
}

test "hc decode2: ablateOut removes each row's component along its slot's direction, rounding once" {
    if (mlx.noGpuBackend() or mlx.virtualGpu()) return error.SkipZigTest;
    const s = mlx.gpuStream();
    var prng = std.Random.DefaultPrng.init(0xAB1A90);
    const rnd = prng.random();
    const h: usize = 256;
    const strengths = [_]f32{ 1.0, 0.0, 0.4 };
    const per: usize = 2;
    const rows = strengths.len * per;
    const wo = try randBf16(rnd, &.{ @intCast(strengths.len), @intCast(per), @intCast(h) }, 2.0, 0.0, s);
    defer _ = mlx.mlx_array_free(wo);
    const dirs = try unitDirections(rnd, strengths.len, h);
    defer {
        _ = mlx.mlx_array_free(dirs.arr);
        testing.allocator.free(dirs.host);
    }
    const sa = mlx.mlx_array_new_data(&strengths, &[_]c_int{strengths.len}, 1, .float32);
    defer _ = mlx.mlx_array_free(sa);
    const got = try hc_decode2.ablateOut(s, wo, .{ .dirs = dirs.arr, .strengths = sa, .per = @intCast(per) });
    defer _ = mlx.mlx_array_free(got);
    try testing.expectEqual(mlx.mlx_dtype.bfloat16, mlx.mlx_array_dtype(got));
    try testing.expectEqualSlices(c_int, mlx.getShape(wo), mlx.getShape(got));
    const woh = try readF32(wo, s);
    defer testing.allocator.free(woh);
    const gh = try readF32(got, s);
    defer testing.allocator.free(gh);
    const want = try testing.allocator.alloc(f64, woh.len);
    defer testing.allocator.free(want);
    var cs: [rows]f64 = undefined;
    ablatedRef(woh, dirs.host, &strengths, h, per, want, &cs);
    for (0..rows) |row| {
        const slot = row / per;
        for (0..h) |i| {
            const at = row * h + i;
            if (strengths[slot] == 0) try testing.expectEqual(woh[at], gh[at]) else try testing.expect(withinUlp(want[at], gh[at], cs[row], dirs.host[slot * h + i]));
        }
    }
}
