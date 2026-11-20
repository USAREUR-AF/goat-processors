// Property tests over every scenario vector of every function:
//
// - determinism: the same input gives the same output, byte for byte;
// - order independence where the specifications say order does not matter:
//   the key order of a report (a JSON object), the order of `name=value`
//   parameters on a pack line (parameters are by name), and, in a filter pack,
//   the place of the other directives relative to the rules (filter.md "Pack":
//   "Other directives may appear in any order relative to the rules").
//
// Snapshot then restore: this engine has no restore operation (no spec
// defines one), so that property is not tested; see REFACTOR.md.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const api = @import("api.zig");
const files = @import("io/vector_files.zig");
const json_read = @import("io/json_read.zig");
const steps_mod = @import("io/steps.zig");
const replay = @import("io/replay.zig");
const compare = @import("io/compare.zig");

const Vector = struct { path: []const u8, pack_dir: []const u8, steps: []steps_mod.Step };

fn vectorsOf(a: Allocator, comptime prefix: []const u8) ![]Vector {
    var out = std.ArrayList(Vector).init(a);
    for (try files.sortedPackNames(a, paths.packs_dir, prefix)) |pn| {
        const pack_dir = try std.fs.path.join(a, &.{ paths.packs_dir, pn });
        const vdir = try std.fs.path.join(a, &.{ pack_dir, "vectors" });
        for (try files.sortedJsonFiles(a, vdir)) |path| {
            const v = try json_read.readJson(a, path);
            try out.append(.{ .path = path, .pack_dir = pack_dir, .steps = try steps_mod.read(a, v) });
        }
    }
    return out.items;
}

const functions = [_]api.Function{ .correlate, .filter, .fuse, .quality };

fn prefixOf(comptime f: api.Function) []const u8 {
    return @tagName(f) ++ "-";
}

test "determinism: every vector twice, the same bytes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n: usize = 0;
    inline for (functions) |f| {
        const M = api.Module(f);
        for (try vectorsOf(a, prefixOf(f))) |v| {
            const pack = try M.load_pack(a, v.pack_dir);
            const first = try replay.bytes(M, a, pack, v.steps);
            const second = try replay.bytes(M, a, pack, v.steps);
            if (!std.mem.eql(u8, first, second)) {
                std.debug.print("not deterministic: {s}\n", .{v.path});
                return error.NotDeterministic;
            }
            n += 1;
        }
    }
    try std.testing.expect(n > 100);
}

// A copy of a report with its keys in reverse order.
fn reversedKeys(a: Allocator, m: json.ObjectMap) !json.ObjectMap {
    var out = json.ObjectMap.init(a);
    const keys = m.keys();
    const vals = m.values();
    var i = keys.len;
    while (i > 0) {
        i -= 1;
        try out.put(keys[i], vals[i]);
    }
    return out;
}

test "report key order: reversed keys give the same output" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (functions) |f| {
        const M = api.Module(f);
        for (try vectorsOf(a, prefixOf(f))) |v| {
            const pack = try M.load_pack(a, v.pack_dir);
            const shuffled = try a.alloc(steps_mod.Step, v.steps.len);
            for (v.steps, shuffled) |s, *o| o.* = switch (s) {
                .ingest => |r| .{ .ingest = try reversedKeys(a, r) },
                .tick => s,
            };
            const want = try replay.values(M, a, pack, v.steps);
            const got = try replay.values(M, a, pack, shuffled);
            for (want.events, got.events, want.trace, got.trace) |we, ge, wt, gt| {
                if (try compare.firstMismatch(a, v.path, ge, we)) |m| {
                    std.debug.print("key order changes events: {s}\n", .{m});
                    return error.OrderDependent;
                }
                if (try compare.firstMismatch(a, v.path, gt, wt)) |m| {
                    std.debug.print("key order changes trace: {s}\n", .{m});
                    return error.OrderDependent;
                }
            }
            if (try compare.firstMismatch(a, v.path, got.snapshot, want.snapshot)) |m| {
                std.debug.print("key order changes snapshot: {s}\n", .{m});
                return error.OrderDependent;
            }
        }
    }
}

// The pack.def with the `name=value` tokens of each line in reverse order,
// every other token in its place.
fn reversedParams(a: Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append('\n');
        first = false;
        const hash = std.mem.indexOfScalar(u8, raw, '#');
        const line = std.mem.trimRight(u8, raw[0 .. hash orelse raw.len], "\r");
        var toks = std.ArrayList([]const u8).init(a);
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |t| try toks.append(t);
        var params = std.ArrayList([]const u8).init(a);
        for (toks.items) |t| if (std.mem.indexOfScalar(u8, t, '=') != null) try params.append(t);
        var j = params.items.len;
        for (toks.items, 0..) |t, i| {
            if (i > 0) try out.append(' ');
            if (std.mem.indexOfScalar(u8, t, '=') != null) {
                j -= 1;
                try out.appendSlice(params.items[j]);
            } else try out.appendSlice(t);
        }
    }
    return out.items;
}

fn samePackOutput(comptime M: type, a: Allocator, v: Vector, base: M.Pack, changed_text: []const u8) !void {
    const changed = M.parse(a, changed_text) catch |e| {
        std.debug.print("{s}: the changed pack does not load: {s}\n{s}\n", .{ v.pack_dir, @errorName(e), changed_text });
        return e;
    };
    const want = try replay.bytes(M, a, base, v.steps);
    const got = try replay.bytes(M, a, changed, v.steps);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("pack order changes the output: {s}\n", .{v.path});
        return error.OrderDependent;
    }
}

test "pack parameter order: reversed name=value parameters give the same bytes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (functions) |f| {
        const M = api.Module(f);
        for (try vectorsOf(a, prefixOf(f))) |v| {
            const text = try json_read.readPackDef(a, v.pack_dir);
            try samePackOutput(M, a, v, try M.parse(a, text), try reversedParams(a, text));
        }
    }
}

test "filter pack: the other directives after the rules give the same bytes" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const M = api.Module(.filter);
    for (try vectorsOf(a, "filter-")) |v| {
        const text = try json_read.readPackDef(a, v.pack_dir);
        var rules = std.ArrayList(u8).init(a);
        var others = std.ArrayList(u8).init(a);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trimLeft(u8, line, " \t");
            const to = if (std.mem.startsWith(u8, t, "rule") or std.mem.startsWith(u8, t, "when")) &rules else &others;
            try to.appendSlice(line);
            try to.append('\n');
        }
        try rules.appendSlice(others.items);
        try samePackOutput(M, a, v, try M.parse(a, text), rules.items);
    }
}
