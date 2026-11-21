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
    // The method's pack ranges and its conditional directives, after its
    // required and refused directives; `seen` holds the directives written.
    check: *const fn (p: pack.Pack, seen: pack.Seen) pack.Error!void,
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
        // `confirm_count` and `hold_failures` unless `sprt` (checkConfirm); one of
        // `stale_ms` and `stale_rate` (pack.zig, both methods).
        .required = &.{ .pack, .version, .filter },
        // correlate-assign.md directives are not directives of correlate.md.
        .refused = &.{ .new_cost, .keep_bonus, .window, .hypotheses, .margin, .bias, .time_offset },
        .check = checkConfirm,
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
        // (and one of `stale_ms` and `stale_rate`, pack.zig).
        .required = &.{ .pack, .version, .filter, .new_cost, .keep_bonus },
        .refused = &.{ .confirm, .hold, .confirm_count, .hold_failures, .same_source, .output, .priority, .sprt },
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

// correlate.md 1.0 "Pack": with `sprt`, `confirm_count`, `hold_failures` and
// `hold` are load errors; without it the first two are required. `sprt`'s
// `false` and `missed` above 0 and below 0.5, the other three above 0.
fn checkConfirm(p: pack.Pack, seen: pack.Seen) pack.Error!void {
    if (p.sprt) |s| {
        for ([_]D{ .confirm_count, .hold_failures, .hold }) |d| if (seen.contains(d)) return error.DirectiveNotForMethod;
        if (!(s.false > 0 and s.false < 0.5 and s.missed > 0 and s.missed < 0.5)) return error.BadValue;
        if (!(s.pos_m > 0 and s.vel_ms > 0 and s.hae_sigma_m > 0)) return error.BadValue;
    } else {
        for ([_]D{ .confirm_count, .hold_failures }) |d| if (!seen.contains(d)) return error.MissingDirective;
    }
}

fn neverReject(_: *Engine, _: []const u8) ?[]const u8 {
    return null;
}

fn nothingAtRestart(_: *Engine, _: []const u8) anyerror!void {}

fn asPredicted(_: *Engine, _: Entity, _: Entity, b_pred: kalman.Filter) anyerror!kalman.Filter {
    return b_pred;
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "methods by name; confirm is the default" {
        try std.testing.expectEqualStrings("confirm", default.name);
        try std.testing.expectEqualStrings("s", find("assign").?.group_prefix);
        try std.testing.expect(find("vote") == null);
    }
};
