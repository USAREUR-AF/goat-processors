// fuse.md "Attributes": the candidates of one attribute in a group, the five
// rules, and the `attribute` trace record.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const fuse_pack = @import("pack.zig");
const engine = @import("engine.zig");
const record = @import("../trace/record.zig");
const reports = @import("../model/report.zig");
const Entity = engine.Entity;
const Group = engine.Group;
const Result = record.Result;
const object = record.object;
const isNumber = reports.isNumber;

pub const Won = struct { value: json.Value, from: []const u8 };

// Decides one attribute for a group and writes its trace record.
pub fn decide(a: Allocator, pack: fuse_pack.Pack, res: *Result, g: Group, members: []const Entity, attr: fuse_pack.Attribute) !?Won {

    // Candidates: members in key order whose last report holds the key
    // with a usable value.
    const Candidate = struct { m: Entity, value: json.Value };
    var cands = std.ArrayList(Candidate).init(a);
    for (members) |m| {
        const v = m.report.get(attr.key) orelse continue;
        const usable = switch (attr.rule) {
            .priority, .latest, .majority => v == .string or v == .bool or isNumber(v),
            .max, .min => isNumber(v),
        };
        if (usable) try cands.append(.{ .m = m, .value = v });
    }

    var winner: ?usize = null;
    if (cands.items.len > 0) {
        const c = cands.items;
        var win: usize = 0;
        switch (attr.rule) {
            // Strictly better replaces, so ties go to key order.
            .priority => for (1..c.len) |i| {
                if (pack.rankOrder(c[i].m.source) < pack.rankOrder(c[win].m.source)) win = i;
            },
            .latest => for (1..c.len) |i| {
                if (c[i].m.last_time_ms > c[win].m.last_time_ms) win = i;
            },
            .max => for (1..c.len) |i| {
                if (numberValue(c[i].value) > numberValue(c[win].value)) win = i;
            },
            .min => for (1..c.len) |i| {
                if (numberValue(c[i].value) < numberValue(c[win].value)) win = i;
            },
            // Count each value at its first holder in key order; the most
            // held value wins, ties to the earlier first holder.
            .majority => {
                var best_count: usize = 0;
                for (c, 0..) |ci, i| {
                    const first_holder = for (c[0..i]) |cj| {
                        if (majorityEqual(cj.value, ci.value)) break false;
                    } else true;
                    if (!first_holder) continue;
                    var count: usize = 0;
                    for (c[i..]) |cj| {
                        if (majorityEqual(cj.value, ci.value)) count += 1;
                    }
                    if (count > best_count) {
                        best_count = count;
                        win = i;
                    }
                }
            },
        }
        winner = win;
    }

    var tc = json.Array.init(a);
    for (cands.items) |c| {
        try tc.append(try object(a, .{
            .{ "member", c.m.key },
            .{ "value", c.value },
            .{ "time_ms", c.m.last_time_ms },
            .{ "rank", pack.rank(c.m.source) },
        }));
    }
    const won: ?Won = if (winner) |i| .{ .value = cands.items[i].value, .from = cands.items[i].m.key } else null;
    try res.trace.append(try object(a, .{
        .{ "stage", "attribute" },
        .{ "group", g.name },
        .{ "key", attr.key },
        .{ "rule", @tagName(attr.rule) },
        .{ "candidates", json.Value{ .array = tc } },
        .{ "winner", if (won) |w| w.from else null },
        .{ "value", if (won) |w| w.value else json.Value.null },
    }));
    return won;
}

fn numberValue(v: json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch std.math.nan(f64),
        else => unreachable,
    };
}

// fuse.md "Attributes": equality for `majority`. Strings by bytes, numbers by
// value (`1` equals `1.0`), booleans by value; different kinds are never equal.
fn majorityEqual(x: json.Value, y: json.Value) bool {
    if (isNumber(x) and isNumber(y)) return numberValue(x) == numberValue(y);
    if (x == .string and y == .string) return std.mem.eql(u8, x.string, y.string);
    if (x == .bool and y == .bool) return x.bool == y.bool;
    return false;
}

test "majority equality: numbers by value, kinds never mixed" {
    try std.testing.expect(majorityEqual(.{ .integer = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(!majorityEqual(.{ .integer = 1 }, .{ .string = "1" }));
    try std.testing.expect(majorityEqual(.{ .bool = true }, .{ .bool = true }));
    try std.testing.expectEqual(@as(f64, 2.5), numberValue(.{ .number_string = "2.5" }));
}
