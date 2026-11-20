// The one entry point of every function of this engine. Each function module
// has the same shape:
//
//   Pack                                  the parsed pack.def
//   load_pack(alloc, dir) !Pack           spec operation `load_pack(dir)`
//   parse(alloc, text) !Pack              the same, from the text of a pack.def
//   Engine.create(backing, pack) !*Engine
//   engine.ingest(report) !Result         one input entity
//   engine.tick(now_ms) !Result           one tick
//   engine.snapshot() !json.Value         the state, as the spec's Snapshot
//   engine.destroy()
//
// and Result is trace/record.zig's: the events, then the trace records.
const std = @import("std");
const json = std.json;

pub const Result = @import("trace/record.zig").Result;

pub const correlate = @import("correlate/engine.zig");
pub const filter = @import("filter/engine.zig");
pub const fuse = @import("fuse/engine.zig");
pub const quality = @import("quality/engine.zig");

pub const Function = enum { correlate, filter, fuse, quality };

// The module of a function.
pub fn Module(comptime f: Function) type {
    const M = switch (f) {
        .correlate => correlate,
        .filter => filter,
        .fuse => fuse,
        .quality => quality,
    };
    checkShape(M);
    return M;
}

// A compile error when a function module does not have the shape above.
fn checkShape(comptime M: type) void {
    const E = M.Engine;
    const A = std.mem.Allocator;
    const want = .{
        .{ "load_pack", fn (A, []const u8) anyerror!M.Pack },
        .{ "parse", fn (A, []const u8) anyerror!M.Pack },
        .{ "create", fn (A, M.Pack) anyerror!*E },
        .{ "ingest", fn (*E, json.ObjectMap) anyerror!Result },
        .{ "tick", fn (*E, i64) anyerror!Result },
        .{ "snapshot", fn (*E) anyerror!json.Value },
        .{ "destroy", fn (*E) void },
    };
    inline for (want) |w| {
        const holder = if (comptime std.mem.eql(u8, w[0], "load_pack") or std.mem.eql(u8, w[0], "parse")) M else E;
        const got = @typeInfo(@TypeOf(@field(holder, w[0]))).Fn;
        const exp = @typeInfo(w[1]).Fn;
        if (got.params.len != exp.params.len) @compileError(@typeName(M) ++ "." ++ w[0] ++ ": wrong parameter count");
        inline for (got.params, exp.params) |g, x| {
            if (g.type.? != x.type.?) @compileError(@typeName(M) ++ "." ++ w[0] ++ ": wrong parameter type");
        }
        const gr = got.return_type.?;
        const xr = exp.return_type.?;
        const gp = switch (@typeInfo(gr)) {
            .ErrorUnion => |eu| eu.payload,
            else => gr,
        };
        const xp = switch (@typeInfo(xr)) {
            .ErrorUnion => |eu| eu.payload,
            else => xr,
        };
        if (gp != xp) @compileError(@typeName(M) ++ "." ++ w[0] ++ ": wrong return type");
    }
}

test "every function has the entry point shape" {
    inline for (std.meta.fields(Function)) |f| _ = Module(@enumFromInt(f.value));
}
