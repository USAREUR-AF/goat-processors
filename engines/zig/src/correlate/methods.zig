// The registration point of a correlate method: `table` below. A method is
// its name in `method <name>`, the pack directives it requires and refuses
// and its ranges, the prefix of its group names, its state, and the hooks
// the engine calls: before and after an accepted report, at a restart, when
// B's prediction is compared with A, at a tick and at a snapshot. Adding a
// method is one entry here (and the file that implements it).
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const pack = @import("pack.zig");
const engine = @import("engine.zig");
const kalman = @import("../model/kalman.zig");
const confirm = @import("confirm.zig");
const assign = @import("../assign/assign.zig");
const snapshot_correlate = @import("../snapshot/correlate.zig");
const snapshot_assign = @import("../snapshot/assign.zig");
const Engine = engine.Engine;
const Result = engine.Result;
const Entity = @import("entity.zig").Entity;
const D = pack.Directive;

pub const Method = struct {
    name: []const u8,
    // Groups are named `<prefix><n>`.
    group_prefix: []const u8,
    required: []const D,
    refused: []const D,
    // The method's pack ranges, after its required and refused directives.
    check: *const fn (p: pack.Pack) pack.Error!void,
    // The method's state, held by the engine as `method_state`.
    init: *const fn (a: Allocator) anyerror!*anyopaque,
    // A reason to reject a report of entity `key` (after the required keys,
    // before out-of-order), or null.
    reject: *const fn (eng: *Engine, key: []const u8) ?[]const u8,
    // The filter of entity `key` started again (correlate.md "Restart").
    restarted: *const fn (eng: *Engine, key: []const u8) anyerror!void,
    // After an accepted report of entity `key`.
    accepted: *const fn (eng: *Engine, res: *Result, key: []const u8) anyerror!void,
    // B's prediction for a comparison with A, after its timing variance.
    compare: *const fn (eng: *Engine, a: Entity, b: Entity, b_pred: kalman.Filter) anyerror!kalman.Filter,
    tick: *const fn (eng: *Engine, now_ms: i64) anyerror!Result,
    snapshot: *const fn (eng: *Engine) anyerror!json.Value,
};

pub const table = [_]Method{
    .{
        .name = "confirm",
        .group_prefix = "g",
        .required = &.{ .pack, .version, .filter, .confirm_count, .hold_failures, .stale_ms },
        // correlate-assign.md directives are not directives of correlate.md.
        .refused = &.{ .new_cost, .keep_bonus, .window, .hypotheses, .margin, .bias, .time_offset },
        .check = noCheck,
        .init = confirm.initState,
        .reject = neverReject,
        .restarted = nothingAtRestart,
        .accepted = confirm.afterIngest,
        .compare = asPredicted,
        .tick = confirm.tick,
        .snapshot = snapshot_correlate.confirm,
    },
    .{
        .name = "assign",
        .group_prefix = "s",
        // correlate-assign.md "Pack": all but `gate` are required.
        .required = &.{ .pack, .version, .filter, .new_cost, .keep_bonus, .stale_ms },
        .refused = &.{ .confirm, .hold, .confirm_count, .hold_failures, .same_source, .output, .priority },
        .check = assign.checkPack,
        .init = assign.initState,
        .reject = assign.rejectRetiring,
        .restarted = assign.markRestarted,
        .accepted = assign.markReported,
        .compare = assign.moveIntoFrame,
        .tick = assign.tick,
        .snapshot = snapshot_assign.snapshot,
    },
};

// A pack without a `method` line.
pub const default: *const Method = &table[0];

pub fn find(name: []const u8) ?*const Method {
    for (&table) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn noCheck(_: pack.Pack) pack.Error!void {}

fn neverReject(_: *Engine, _: []const u8) ?[]const u8 {
    return null;
}

fn nothingAtRestart(_: *Engine, _: []const u8) anyerror!void {}

fn asPredicted(_: *Engine, _: Entity, _: Entity, b_pred: kalman.Filter) anyerror!kalman.Filter {
    return b_pred;
}

test "methods by name; confirm is the default" {
    try std.testing.expectEqualStrings("confirm", default.name);
    try std.testing.expectEqualStrings("s", find("assign").?.group_prefix);
    try std.testing.expect(find("vote") == null);
}
