// Fuzzing of the input parsers, with a seeded generator written here (no
// fuzzing framework), bounded so CI runs it in seconds:
//
// - pack.def: every function's parser on mutations of every pack of packs/
//   and every load vector's text; each mutant either loads or gives a load
//   error, never a crash, and the same text gives the same result twice;
// - the JSON reader and the steps reader: mutations of scenario vectors;
// - reports: generated reports, every key of the Reports tables with values
//   of every JSON kind, through the engine of every pack of packs/.
//
// The seed is fixed (0x60a7); FUZZ_SEED overrides it, FUZZ_ITERATIONS
// multiplies the counts.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const paths = @import("paths");
const api = @import("api.zig");
const files = @import("io/vector_files.zig");
const json_read = @import("io/json_read.zig");
const steps_mod = @import("io/steps.zig");
const replay = @import("io/replay.zig");

fn seed() u64 {
    const s = std.process.getEnvVarOwned(std.heap.page_allocator, "FUZZ_SEED") catch return 0x60a7;
    return std.fmt.parseInt(u64, s, 0) catch 0x60a7;
}

fn scale() usize {
    const s = std.process.getEnvVarOwned(std.heap.page_allocator, "FUZZ_ITERATIONS") catch return 1;
    return std.fmt.parseInt(usize, s, 10) catch 1;
}

// Tokens a mutation may insert: the directives, test and condition names,
// parameter names and values the grammars know, and bytes they do not.
const dictionary = [_][]const u8{
    "pack",                 "version",        "method",         "assign",        "confirm",     "filter",         "maneuver",             "restart",
    "bias",                 "time_offset",    "time_default",   "gate",          "hold",        "window",         "hypotheses",           "margin",
    "rule",                 "when",           "not",            "keep",          "drop",        "default",        "forget_ms",            "kinematics",
    "attribute",            "source",         "stale_ms",       "priority",      "latest",      "best",           "mahalanobis",          "same",
    "distance",             "course",         "speed",          "altitude",      "circle",      "polygon",        "near",                 "key",
    "has",                  "interval",       "order",          "env",           "uid",         "scope=entity",   "scope=source",         "measure=age",
    "op=>",                 "op=<=",          "limit=1",        "for=1",         "clear=0",     "action=mark",    "action=downgrade",     "factor=2",
    "gate=9.21",            "max_m=-1",       "key=@env",       "in=a,b",        "eq=1",        "min=1",          "max=0",                "lat=91",
    "vertices=0,0;0,1;1,1", "error_ms=1e309", "state=drifting", "rule=majority", "accel_var=1", "default_ce_m=0", "=",                    "#",
    "\t",                   "\r",             "\x00",           "\x7f",          "1.0.0",       "-0",             "99999999999999999999", "1e-400",
    "NaN",                  "inf",            "",
};

fn mutate(r: std.Random, a: Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(text);
    const n = 1 + r.uintLessThan(usize, 2);
    for (0..n) |_| {
        const len = out.items.len;
        switch (r.uintLessThan(u8, 8)) {
            0 => if (len > 0) {
                _ = out.orderedRemove(r.uintLessThan(usize, len));
            },
            1 => try out.insert(r.uintLessThan(usize, len + 1), r.int(u8)),
            2 => if (len > 0) {
                out.items[r.uintLessThan(usize, len)] ^= @as(u8, 1) << r.int(u3);
            },
            3 => try out.insertSlice(r.uintLessThan(usize, len + 1), dictionary[r.uintLessThan(usize, dictionary.len)]),
            4 => {
                const at = r.uintLessThan(usize, len + 1);
                const tok = dictionary[r.uintLessThan(usize, dictionary.len)];
                try out.insertSlice(at, " ");
                try out.insertSlice(at + 1, tok);
                try out.insertSlice(at + 1 + tok.len, "\n");
            },
            5 => if (len > 0) out.shrinkRetainingCapacity(r.uintLessThan(usize, len)),
            6 => if (len > 1) {
                // Duplicate a slice of lines somewhere else.
                const from = r.uintLessThan(usize, len);
                const to = @min(len, from + r.uintLessThan(usize, 80));
                const piece = try a.dupe(u8, out.items[from..to]);
                try out.insertSlice(r.uintLessThan(usize, len + 1), piece);
            },
            else => if (len > 2) {
                // Swap two bytes.
                const i = r.uintLessThan(usize, len);
                const j = r.uintLessThan(usize, len);
                std.mem.swap(u8, &out.items[i], &out.items[j]);
            },
        }
    }
    return out.items;
}

fn packCorpus(a: Allocator) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (try files.sortedPackNames(a, paths.packs_dir, "")) |pn| {
        const dir = try std.fs.path.join(a, &.{ paths.packs_dir, pn });
        try out.append(try json_read.readPackDef(a, dir));
    }
    for ([_][]const u8{ paths.load_vectors_dir, paths.filter_load_vectors_dir, paths.fuse_load_vectors_dir, paths.quality_load_vectors_dir }) |d| {
        for (try files.sortedJsonFiles(a, d)) |path| {
            try out.append((try json_read.readJson(a, path)).object.get("pack_def").?.string);
        }
    }
    return out.items;
}

const functions = [_]api.Function{ .correlate, .filter, .fuse, .quality };

test "fuzz: pack.def parsers never crash and are deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const corpus = try packCorpus(arena.allocator());
    var prng = std.Random.DefaultPrng.init(seed());
    const r = prng.random();
    var loaded: usize = 0;
    var refused: usize = 0;
    for (0..3000 * scale()) |_| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const text = try mutate(r, a, corpus[r.uintLessThan(usize, corpus.len)]);
        inline for (functions) |f| {
            const M = api.Module(f);
            const first = M.parse(a, text);
            const second = M.parse(a, text);
            if (first) |_| {
                loaded += 1;
                _ = second catch return error.NotDeterministic;
            } else |e1| {
                refused += 1;
                if (second) |_| return error.NotDeterministic else |e2| try std.testing.expectEqual(e1, e2);
            }
        }
    }
    std.debug.print("fuzz pack.def: {d} loaded, {d} refused\n", .{ loaded, refused });
    try std.testing.expect(loaded > 0 and refused > 0);
}

test "fuzz: the JSON and steps readers never crash" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a0 = arena.allocator();
    var corpus = std.ArrayList([]const u8).init(a0);
    for (try files.sortedPackNames(a0, paths.packs_dir, "")) |pn| {
        const vdir = try std.fs.path.join(a0, &.{ paths.packs_dir, pn, "vectors" });
        const list = files.sortedJsonFiles(a0, vdir) catch continue;
        for (list) |path| {
            const text = try json_read.readFile(a0, path);
            if (text.len < 16 * 1024) try corpus.append(text);
        }
    }
    var prng = std.Random.DefaultPrng.init(seed() +% 1);
    const r = prng.random();
    var parsed: usize = 0;
    var steps_ok: usize = 0;
    for (0..1500 * scale()) |_| {
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const text = try mutate(r, a, corpus.items[r.uintLessThan(usize, corpus.items.len)]);
        const v = json_read.parse(a, text) catch continue;
        parsed += 1;
        _ = steps_mod.read(a, v) catch continue;
        steps_ok += 1;
    }
    std.debug.print("fuzz JSON: {d} parsed, {d} steps files\n", .{ parsed, steps_ok });
    try std.testing.expect(parsed > 0);
}

// A JSON value of a random kind, numbers near the edges included.
fn randomValue(r: std.Random, a: Allocator, depth: usize) !json.Value {
    return switch (r.uintLessThan(u8, if (depth > 1) 7 else 9)) {
        0 => .null,
        1 => .{ .bool = r.boolean() },
        2 => .{ .integer = switch (r.uintLessThan(u8, 4)) {
            0 => r.intRangeAtMost(i64, -2000, 200000),
            1 => r.intRangeAtMost(i64, -1, 1),
            2 => r.intRangeAtMost(i64, -(1 << 40), 1 << 40),
            else => r.intRangeAtMost(i64, 0, 400),
        } },
        3 => .{ .float = switch (r.uintLessThan(u8, 4)) {
            0 => (r.float(f64) - 0.5) * 2.0,
            1 => (r.float(f64) - 0.5) * 400.0,
            2 => 0.0,
            else => (r.float(f64) - 0.5) * 1e6,
        } },
        4 => .{ .number_string = "123456789012345678901234567890" },
        5, 6 => .{ .string = ([_][]const u8{ "", "a", "a-f-A", "a-h-G-U", "drifting", "free-running", "coherent", "s1", "g", "x/y" })[r.uintLessThan(usize, 10)] },
        7 => blk: {
            var arr = json.Array.init(a);
            for (0..r.uintLessThan(usize, 3)) |_| try arr.append(try randomValue(r, a, depth + 1));
            break :blk .{ .array = arr };
        },
        else => blk: {
            var m = json.ObjectMap.init(a);
            try m.put("k", try randomValue(r, a, depth + 1));
            break :blk .{ .object = m };
        },
    };
}

// Not `lat` and `lon`: a longitude far outside [-180, 180] makes the Frame's
// wrap loop as long as |lon| / 360 (DISAGREEMENTS.md); they get the wrong
// type or a plausible value below instead.
const report_keys = [_][]const u8{ "ce", "course", "speed_ms", "hae", "type", "stale_ms", "received_ms", "time_error_ms", "time_state", "fuse.group", "track.simulated", "quality.marks", "name", "x" };

// A report: usually with valid required keys near a few places, sometimes not.
fn randomReport(r: std.Random, a: Allocator, now: i64) !json.ObjectMap {
    var m = json.ObjectMap.init(a);
    const sources = [_][]const u8{ "radar-1", "adsb", "beacon", "passive" };
    if (r.uintLessThan(u8, 20) != 0) try m.put("track.source_id", .{ .string = sources[r.uintLessThan(usize, sources.len)] });
    if (r.uintLessThan(u8, 20) != 0) try m.put("uid", .{ .string = ([_][]const u8{ "1", "2", "3" })[r.uintLessThan(usize, 3)] });
    if (r.uintLessThan(u8, 20) != 0) try m.put("time_ms", .{ .integer = now + r.intRangeAtMost(i64, -3000, 1000) });
    try m.put("lat", if (r.uintLessThan(u8, 30) == 0) .{ .string = "50" } else .{ .float = 50.0 + (r.float(f64) - 0.5) * 0.02 });
    try m.put("lon", if (r.uintLessThan(u8, 30) == 0) .null else .{ .float = 8.0 + (r.float(f64) - 0.5) * 0.02 });
    for (report_keys) |k| {
        if (r.uintLessThan(u8, 3) == 0) try m.put(k, try randomValue(r, a, 0));
    }
    // Plausible values for the optional keys, half the time.
    if (r.boolean()) try m.put("ce", .{ .float = 5 + r.float(f64) * 60 });
    if (r.boolean()) {
        try m.put("course", .{ .float = r.float(f64) * 360 });
        try m.put("speed_ms", .{ .float = r.float(f64) * 300 });
    }
    return m;
}

test "fuzz: generated reports through the engine of every pack never crash" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a0 = arena.allocator();
    var prng = std.Random.DefaultPrng.init(seed() +% 2);
    const r = prng.random();
    var runs: usize = 0;
    for (try files.sortedPackNames(a0, paths.packs_dir, "")) |pn| {
        const dir = try std.fs.path.join(a0, &.{ paths.packs_dir, pn });
        inline for (functions) |f| {
            if (std.mem.startsWith(u8, pn, @tagName(f) ++ "-")) {
                const M = api.Module(f);
                for (0..2 * scale()) |_| {
                    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer scratch.deinit();
                    const a = scratch.allocator();
                    const pack = try M.load_pack(a, dir);
                    var steps = std.ArrayList(steps_mod.Step).init(a);
                    var now: i64 = 0;
                    for (0..60) |_| {
                        now += r.intRangeAtMost(i64, 0, 1500);
                        if (r.uintLessThan(u8, 6) == 0) {
                            try steps.append(.{ .tick = now + r.intRangeAtMost(i64, -500, 500) });
                        } else try steps.append(.{ .ingest = try randomReport(r, a, now) });
                    }
                    const first = try replay.bytes(M, a, pack, steps.items);
                    const second = try replay.bytes(M, a, pack, steps.items);
                    try std.testing.expectEqualSlices(u8, first, second);
                    runs += 1;
                }
                if (std.process.hasEnvVarConstant("FUZZ_VERBOSE")) std.debug.print("  {s} done\n", .{pn});
            }
        }
    }
    std.debug.print("fuzz reports: {d} runs\n", .{runs});
    try std.testing.expect(runs > 0);
}
