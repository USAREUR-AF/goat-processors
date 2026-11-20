// The proof of the test registry: a no-op test kind registered here, in test
// code only, behind a pack's `gate noop` / `hold noop` line, with its own
// fixture pack and vector (testdata/noop/). The kind is not in the engine's
// builtin registry, so no pack of packs/ can name it and every existing vector
// is unchanged: a pack naming it does not load without this registration.
const std = @import("std");
const json = std.json;
const tests = @import("tests.zig");
const pack_mod = @import("pack.zig");
const engine = @import("engine.zig");
const compare = @import("../io/compare.zig");
const steps_mod = @import("../io/steps.zig");

// The no-op kind: no parameters; always passes with no value and no limit.
fn runNoop(_: tests.Pair, _: []const tests.Arg) tests.Outcome {
    return .{ .value = .null, .limit = .null, .pass = true };
}

const noop = tests.Kind{ .name = "noop", .params = &.{}, .run = runNoop };

// The one registration: the builtin kinds and the no-op kind.
const registry = tests.Registry{ .kinds = &(tests.builtin ++ [_]tests.Kind{noop}) };

const pack_def = @embedFile("testdata/noop/pack.def");
const vector = @embedFile("testdata/noop/vector.json");

// The same pack without its no-op lines, which the builtin registry loads.
fn withoutNoop(a: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, pack_def, '\n');
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, std.mem.trimRight(u8, line, " "), " noop")) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.items;
}

const Run = struct { events: []json.Value, trace: []json.Value, snapshot: json.Value };

fn run(a: std.mem.Allocator, p: pack_mod.Pack, v: json.Value) !Run {
    const eng = try engine.Engine.create(a, p);
    var events = std.ArrayList(json.Value).init(a);
    var trace = std.ArrayList(json.Value).init(a);
    for (v.object.get("steps").?.array.items) |s| {
        const res = switch (try steps_mod.one(s)) {
            .ingest => |r| try eng.ingest(r),
            .tick => |t| try eng.tick(t),
        };
        try events.append(.{ .array = res.events });
        try trace.append(.{ .array = res.trace });
    }
    return .{ .events = events.items, .trace = trace.items, .snapshot = try eng.snapshot() };
}

test "a pack naming the no-op kind does not load without its registration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownTest, pack_mod.parse(arena.allocator(), pack_def));
    _ = try pack_mod.parse(arena.allocator(), try withoutNoop(arena.allocator()));
}

test "the no-op vector: events, trace and snapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a, vector, .{});
    const got = try run(a, try pack_mod.parseWith(a, pack_def, registry), v);
    for (v.object.get("steps").?.array.items, 0..) |s, i| {
        if (try compare.firstMismatch(a, "expect", got.events[i], s.object.get("expect").?)) |m| {
            std.debug.print("noop vector step {d}: {s}\n", .{ i, m });
            return error.Mismatch;
        }
        if (try compare.firstMismatch(a, "trace", got.trace[i], s.object.get("trace").?)) |m| {
            std.debug.print("noop vector step {d}: {s}\n", .{ i, m });
            return error.Mismatch;
        }
    }
    try std.testing.expect((try compare.firstMismatch(a, "snapshot", got.snapshot, v.object.get("snapshot").?)) == null);
}

test "the no-op kind is invisible: same events and snapshot, the trace less its records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try json.parseFromSliceLeaky(json.Value, a, vector, .{});
    const with = try run(a, try pack_mod.parseWith(a, pack_def, registry), v);
    const without = try run(a, try pack_mod.parse(a, try withoutNoop(a)), v);
    var noop_records: usize = 0;
    for (with.events, without.events, with.trace, without.trace) |ew, eo, tw, to| {
        try std.testing.expect((try compare.firstMismatch(a, "events", ew, eo)) == null);
        var kept = json.Array.init(a);
        for (tw.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("test").?.string, "noop")) {
                noop_records += 1;
                try std.testing.expect(r.object.get("pass").?.bool);
            } else try kept.append(r);
        }
        try std.testing.expect((try compare.firstMismatch(a, "trace", .{ .array = kept }, to)) == null);
    }
    try std.testing.expect(noop_records > 0);
    try std.testing.expect((try compare.firstMismatch(a, "snapshot", with.snapshot, without.snapshot)) == null);
}
