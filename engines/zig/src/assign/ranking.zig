// correlate-assign.md "Ranking": the entries of one source (steps 1 and 2 of
// "Assignment of one source" build them), every assignment by brute-force
// enumeration, and the first `k` in ranking order. Pure: no engine state.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Column = struct { id: u64, others: []const []const u8 };

// Steps 1 and 2: the columns, and per row an entry for each column then its own
// `alone` at index `cols.len`; null is a forbidden entry.
pub const Entries = struct {
    cols: []const Column,
    rows: []const []const u8,
    values: []const ?f64, // rows.len by cols.len + 1, row-major

    pub fn at(self: Entries, i: usize, j: usize) ?f64 {
        return self.values[i * (self.cols.len + 1) + j];
    }

    pub fn chosenId(self: Entries, j: usize) ?u64 {
        return if (j < self.cols.len) self.cols[j].id else null;
    }
};

// `choice[i]` is row i's column index, `cols.len` for `alone`: the choice vector.
pub const Assignment = struct { choice: []const usize, total: f64 };

// The total: the chosen entries in ascending order of value, added left to right from 0.
fn totalOf(alloc: Allocator, e: Entries, choice: []const usize) !f64 {
    const vals = try alloc.alloc(f64, choice.len);
    for (choice, 0..) |j, i| vals[i] = e.at(i, j).?;
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    var t: f64 = 0;
    for (vals) |v| t += v;
    return t;
}

// X before Y: smaller total, or equal totals and the smaller choice vector.
fn ranksBefore(_: void, x: Assignment, y: Assignment) bool {
    if (x.total != y.total) return x.total < y.total;
    for (x.choice, y.choice) |a, b| if (a != b) return a < b;
    return false;
}

// Every assignment: each row one column or `alone`, each column at most once,
// no forbidden entry. Brute force, rows in key order.
fn enumerate(alloc: Allocator, e: Entries, row: usize, choice: []usize, used: []bool, out: *std.ArrayList(Assignment)) !void {
    if (row == e.rows.len) {
        const c = try alloc.dupe(usize, choice);
        try out.append(.{ .choice = c, .total = try totalOf(alloc, e, c) });
        return;
    }
    for (0..e.cols.len + 1) |j| {
        if (e.at(row, j) == null) continue;
        const is_col = j < e.cols.len;
        if (is_col and used[j]) continue;
        if (is_col) used[j] = true;
        choice[row] = j;
        try enumerate(alloc, e, row + 1, choice, used, out);
        if (is_col) used[j] = false;
    }
}

// Step 3: the first `k` assignments in Ranking order.
pub fn ranked(alloc: Allocator, e: Entries, k: usize) ![]const Assignment {
    var all = std.ArrayList(Assignment).init(alloc);
    const choice = try alloc.alloc(usize, e.rows.len);
    const used = try alloc.alloc(bool, e.cols.len);
    @memset(used, false);
    try enumerate(alloc, e, 0, choice, used, &all);
    std.mem.sort(Assignment, all.items, {}, ranksBefore);
    return all.items[0..@min(k, all.items.len)];
}

test "ranking: totals ascending, ties to the smaller choice vector, columns used once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two rows, one column; entries [col, alone] per row; row 1 may not take the column.
    const cols = [_]Column{.{ .id = 7, .others = &.{"x"} }};
    const values = [_]?f64{ 1, 5, null, 2 };
    const e = Entries{ .cols = &cols, .rows = &.{ "r0", "r1" }, .values = &values };
    try std.testing.expectEqual(@as(?u64, 7), e.chosenId(0));
    try std.testing.expectEqual(@as(?u64, null), e.chosenId(1));
    const r = try ranked(a, e, 5);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(f64, 3), r[0].total);
    try std.testing.expectEqual(@as(usize, 0), r[0].choice[0]);
    try std.testing.expectEqual(@as(f64, 7), r[1].total);
    const one = try ranked(a, e, 1);
    try std.testing.expectEqual(@as(usize, 1), one.len);
}
