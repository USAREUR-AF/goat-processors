// tools/perf/README.md "Runner contract": the command-line runner of the zig
// engine. Reads a steps file, loads the pack, feeds every step to the engine
// of the chosen function, then snapshot(); writes the events file and the
// counters line.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

const correlate = @import("engine.zig");
const filter = @import("filter.zig");
const fuse = @import("fuse.zig");
const quality = @import("quality.zig");

const Args = struct {
    function: []const u8,
    pack: []const u8,
    steps: []const u8,
    events: ?[]const u8 = null,
    trace: bool = false,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig runner: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(alloc: Allocator) !Args {
    const argv = try std.process.argsAlloc(alloc);
    var function: ?[]const u8 = null;
    var pack: ?[]const u8 = null;
    var steps: ?[]const u8 = null;
    var out = Args{ .function = "", .pack = "", .steps = "" };
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--trace")) {
            out.trace = true;
            continue;
        }
        if (i + 1 >= argv.len) fail("missing value for {s}", .{a});
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--function")) {
            function = v;
        } else if (std.mem.eql(u8, a, "--pack")) {
            pack = v;
        } else if (std.mem.eql(u8, a, "--steps")) {
            steps = v;
        } else if (std.mem.eql(u8, a, "--events")) {
            out.events = v;
        } else fail("unknown argument {s}", .{a});
    }
    out.function = function orelse fail("--function is required", .{});
    out.pack = pack orelse fail("--pack is required", .{});
    out.steps = steps orelse fail("--steps is required", .{});
    return out;
}

// ---- JSON writing ------------------------------------------------------------

fn writeValue(w: anytype, v: json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) {
                try w.writeAll("NaN");
            } else if (std.math.isInf(f)) {
                try w.writeAll(if (f > 0) "Infinity" else "-Infinity");
            } else try w.print("{}", .{f});
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| try json.encodeJsonString(s, .{}, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(w, x);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |e| {
                if (!first) try w.writeByte(',');
                first = false;
                try json.encodeJsonString(e.key_ptr.*, .{}, w);
                try w.writeByte(':');
                try writeValue(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

const StepOut = struct { events: json.Array, trace: json.Array };

const Counters = struct {
    steps: usize = 0,
    ingest: usize = 0,
    tick: usize = 0,
    events: usize = 0,
    trace_records: usize = 0,
    load_ns: u64 = 0,
    run_ns: u64 = 0,
};

const Step = union(enum) { ingest: json.ObjectMap, tick: i64 };

// The steps of a steps file; any key other than `ingest` and `tick` is ignored.
fn readSteps(alloc: Allocator, root: json.Value) ![]Step {
    if (root != .object) return error.NotAnObject;
    const list = root.object.get("steps") orelse return error.NoSteps;
    if (list != .array) return error.StepsNotAList;
    const out = try alloc.alloc(Step, list.array.items.len);
    for (list.array.items, out) |s, *o| {
        if (s != .object) return error.StepNotAnObject;
        if (s.object.get("ingest")) |r| {
            if (r != .object) return error.IngestNotAnObject;
            o.* = .{ .ingest = r.object };
        } else if (s.object.get("tick")) |t| {
            if (t != .integer) return error.TickNotAnInteger;
            o.* = .{ .tick = t.integer };
        } else return error.StepWithoutIngestOrTick;
    }
    return out;
}

fn runFunction(comptime M: type, alloc: Allocator, pack_dir: []const u8, steps: []const Step, outs: []StepOut, c: *Counters) !json.Value {
    var timer = try std.time.Timer.start();
    const pack = M.load_pack(alloc, pack_dir) catch |e| fail("pack {s} does not load: {s}", .{ pack_dir, @errorName(e) });
    const eng = try M.Engine.create(std.heap.page_allocator, pack);
    c.load_ns = timer.read();
    timer.reset();
    for (steps, outs) |s, *o| {
        const res = switch (s) {
            .ingest => |r| try eng.ingest(r),
            .tick => |t| try eng.tick(t),
        };
        o.* = .{ .events = res.events, .trace = res.trace };
    }
    const snap = try eng.snapshot();
    c.run_ns = timer.read();
    // The engine is not destroyed: its arena holds the output, and the process ends.
    return snap;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const args = try parseArgs(alloc);

    const Fn = enum { correlate, filter, fuse, quality };
    const function = std.meta.stringToEnum(Fn, args.function) orelse fail("unknown function {s}", .{args.function});

    // Reading and parsing the steps file.
    var timer = try std.time.Timer.start();
    const text = std.fs.cwd().readFileAlloc(alloc, args.steps, std.math.maxInt(usize)) catch |e| fail("cannot read {s}: {s}", .{ args.steps, @errorName(e) });
    const root = json.parseFromSliceLeaky(json.Value, alloc, text, .{}) catch |e| fail("{s} does not parse: {s}", .{ args.steps, @errorName(e) });
    const steps = readSteps(alloc, root) catch |e| fail("{s} is not a steps file: {s}", .{ args.steps, @errorName(e) });
    const parse_ns = timer.read();

    var c = Counters{ .steps = steps.len };
    for (steps) |s| switch (s) {
        .ingest => c.ingest += 1,
        .tick => c.tick += 1,
    };
    const outs = try alloc.alloc(StepOut, steps.len);
    const snap = switch (function) {
        .correlate => try runFunction(correlate, alloc, args.pack, steps, outs, &c),
        .filter => try runFunction(filter, alloc, args.pack, steps, outs, &c),
        .fuse => try runFunction(fuse, alloc, args.pack, steps, outs, &c),
        .quality => try runFunction(quality, alloc, args.pack, steps, outs, &c),
    };
    for (outs) |o| {
        c.events += o.events.items.len;
        c.trace_records += o.trace.items.len;
    }

    if (args.events) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();
        for (outs, 0..) |o, i| {
            try w.print("{{\"step\":{d},\"events\":", .{i});
            try writeValue(w, .{ .array = o.events });
            if (args.trace) {
                try w.writeAll(",\"trace\":");
                try writeValue(w, .{ .array = o.trace });
            }
            try w.writeAll("}\n");
        }
        try w.writeAll("{\"snapshot\":");
        try writeValue(w, snap);
        try w.writeAll("}\n");
        try bw.flush();
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("{\"engine\":\"zig\",\"function\":");
    try json.encodeJsonString(args.function, .{}, stdout);
    try stdout.writeAll(",\"pack\":");
    try json.encodeJsonString(std.fs.path.basename(args.pack), .{}, stdout);
    try stdout.print(",\"steps\":{d},\"ingest\":{d},\"tick\":{d},\"events\":{d},\"trace_records\":{d},\"parse_ns\":{d},\"load_ns\":{d},\"run_ns\":{d}}}\n", .{
        c.steps, c.ingest, c.tick, c.events, c.trace_records, parse_ns, c.load_ns, c.run_ns,
    });
}
