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

// The total: the chosen entries in ascending order of value, added left to
// right from 0. `vals` is scratch space of `choice.len` values. (The
// enumeration keeps its values sorted as it goes and adds them the same way.)
fn totalOf(vals: []f64, e: Entries, choice: []const usize) f64 {
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

// The best `k` assignments seen so far, in ranking order. Two different
// assignments have different choice vectors, so ranksBefore is a strict total
// order (with no NaN total) and keeping the best k while enumerating gives
// exactly the first k of the full sorted list. A NaN total breaks that order,
// so it is flagged and the full sort is used instead.
const Best = struct {
    k: usize,
    top: std.ArrayList(Assignment),
    nan: bool = false,

    // `sorted` holds the chosen entries in ascending order, equal values in
    // row order: the order totalOf's stable sort gives them.
    fn offer(self: *Best, choice: []const usize, sorted: []const f64) !void {
        var total: f64 = 0;
        for (sorted) |v| total += v;
        if (std.math.isNan(total)) self.nan = true;
        const cand = Assignment{ .choice = choice, .total = total };
        const items = self.top.items;
        if (items.len == self.k and !ranksBefore({}, cand, items[items.len - 1])) return;
        var at: usize = items.len;
        while (at > 0 and ranksBefore({}, cand, items[at - 1])) at -= 1;
        // The new entry's choice vector: the dropped last one's buffer, or a new one.
        var buf: []usize = undefined;
        if (items.len == self.k) {
            buf = @constCast(self.top.pop().choice);
        } else buf = try self.top.allocator.alloc(usize, choice.len);
        @memcpy(buf, choice);
        try self.top.insert(at, .{ .choice = buf, .total = total });
    }
};

// Every assignment: each row one column or `alone`, each column at most once,
// no forbidden entry. Brute force, rows in key order.
// `sorted[0..row]` holds the entries chosen for the rows before `row`, sorted.
fn enumerate(e: Entries, row: usize, choice: []usize, used: []bool, sorted: []f64, best: *Best) !void {
    if (row == e.rows.len) return best.offer(choice, sorted);
    for (0..e.cols.len + 1) |j| {
        const v = e.at(row, j) orelse continue;
        const is_col = j < e.cols.len;
        if (is_col and used[j]) continue;
        if (is_col) used[j] = true;
        choice[row] = j;
        // After every value it is not below: a stable insertion.
        var at: usize = row;
        while (at > 0 and v < sorted[at - 1]) at -= 1;
        std.mem.copyBackwards(f64, sorted[at + 1 .. row + 1], sorted[at..row]);
        sorted[at] = v;
        try enumerate(e, row + 1, choice, used, sorted, best);
        std.mem.copyForwards(f64, sorted[at..row], sorted[at + 1 .. row + 1]);
        if (is_col) used[j] = false;
    }
}

// Step 3: the first `k` assignments in Ranking order.
pub fn ranked(alloc: Allocator, e: Entries, k: usize) ![]const Assignment {
    if (k == 0) return &.{};
    const choice = try alloc.alloc(usize, e.rows.len);
    const used = try alloc.alloc(bool, e.cols.len);
    @memset(used, false);
    var best = Best{ .k = k, .top = std.ArrayList(Assignment).init(alloc) };
    try enumerate(e, 0, choice, used, try alloc.alloc(f64, e.rows.len), &best);
    if (best.nan) return rankedBySort(alloc, e, k);
    return best.top.items;
}

// Every assignment sorted, then the first `k`: the definition, for the case
// of a NaN total.
fn rankedBySort(alloc: Allocator, e: Entries, k: usize) ![]const Assignment {
    var all = std.ArrayList(Assignment).init(alloc);
    const choice = try alloc.alloc(usize, e.rows.len);
    const used = try alloc.alloc(bool, e.cols.len);
    @memset(used, false);
    try enumerateAll(alloc, e, 0, choice, used, &all);
    std.mem.sort(Assignment, all.items, {}, ranksBefore);
    return all.items[0..@min(k, all.items.len)];
}

fn enumerateAll(alloc: Allocator, e: Entries, row: usize, choice: []usize, used: []bool, out: *std.ArrayList(Assignment)) !void {
    if (row == e.rows.len) {
        const c = try alloc.dupe(usize, choice);
        const vals = try alloc.alloc(f64, c.len);
        try out.append(.{ .choice = c, .total = totalOf(vals, e, c) });
        return;
    }
    for (0..e.cols.len + 1) |j| {
        if (e.at(row, j) == null) continue;
        const is_col = j < e.cols.len;
        if (is_col and used[j]) continue;
        if (is_col) used[j] = true;
        choice[row] = j;
        try enumerateAll(alloc, e, row + 1, choice, used, out);
        if (is_col) used[j] = false;
    }
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
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

    test "the best k while enumerating equals the first k of the full sort" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var prng = std.Random.DefaultPrng.init(7);
        const r = prng.random();
        for (0..200) |_| {
            const nrows = 1 + r.uintLessThan(usize, 4);
            const ncols = r.uintLessThan(usize, 4);
            const cols = try a.alloc(Column, ncols);
            for (cols, 0..) |*c, i| c.* = .{ .id = i + 1, .others = &.{} };
            const values = try a.alloc(?f64, nrows * (ncols + 1));
            for (values, 0..) |*v, i| {
                const alone = i % (ncols + 1) == ncols;
                // Few distinct values, so equal totals are common; some entries forbidden.
                v.* = if (!alone and r.uintLessThan(u8, 4) == 0) null else @as(f64, @floatFromInt(r.uintLessThan(u8, 5))) - 1.0;
            }
            const rows = try a.alloc([]const u8, nrows);
            for (rows) |*x| x.* = "r";
            const e = Entries{ .cols = cols, .rows = rows, .values = values };
            const k = 1 + r.uintLessThan(usize, 6);
            const fast = try ranked(a, e, k);
            const slow = try rankedBySort(a, e, k);
            try std.testing.expectEqual(slow.len, fast.len);
            for (fast, slow) |x, y| {
                try std.testing.expectEqual(y.total, x.total);
                try std.testing.expectEqualSlices(usize, y.choice, x.choice);
            }
        }
    }
};
