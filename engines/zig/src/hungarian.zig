// Exact minimum-cost assignment (Hungarian method with potentials, O(n² m)),
// for correlate-assign.md "Assignment", step 3.
const std = @import("std");

const inf = std.math.inf(f64);

// `costs` is n rows by m columns (n <= m), row-major; `inf` marks a forbidden
// entry. Every row must have at least one finite entry no other row can take
// (its `alone` entry), so a complete assignment always exists. Returns, for
// each row, its column.
pub fn solve(alloc: std.mem.Allocator, costs: []const f64, n: usize, m: usize) ![]usize {
    std.debug.assert(n <= m);
    // 1-indexed: row 0 and column 0 are the sentinel.
    const u = try alloc.alloc(f64, n + 1);
    const v = try alloc.alloc(f64, m + 1);
    const p = try alloc.alloc(usize, m + 1); // p[j]: row on column j, 0 when free
    const way = try alloc.alloc(usize, m + 1);
    const minv = try alloc.alloc(f64, m + 1);
    const used = try alloc.alloc(bool, m + 1);
    @memset(u, 0);
    @memset(v, 0);
    @memset(p, 0);
    @memset(way, 0);

    for (1..n + 1) |i| {
        p[0] = i;
        var j0: usize = 0;
        @memset(minv, inf);
        @memset(used, false);
        while (true) {
            used[j0] = true;
            const row0 = p[j0];
            var delta = inf;
            var j1: usize = 0;
            for (1..m + 1) |j| {
                if (used[j]) continue;
                const c = costs[(row0 - 1) * m + (j - 1)];
                const cur = if (c == inf) inf else c - u[row0] - v[j];
                if (cur < minv[j]) {
                    minv[j] = cur;
                    way[j] = j0;
                }
                if (minv[j] < delta) {
                    delta = minv[j];
                    j1 = j;
                }
            }
            std.debug.assert(j1 != 0);
            for (0..m + 1) |j| {
                if (used[j]) {
                    u[p[j]] += delta;
                    v[j] -= delta;
                } else if (minv[j] != inf) {
                    minv[j] -= delta;
                }
            }
            j0 = j1;
            if (p[j0] == 0) break;
        }
        while (j0 != 0) {
            const j1 = way[j0];
            p[j0] = p[j1];
            j0 = j1;
        }
    }

    const out = try alloc.alloc(usize, n);
    for (1..m + 1) |j| {
        if (p[j] != 0) out[p[j] - 1] = j - 1;
    }
    return out;
}

test "least total, not nearest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Nearest first gives row 0 column 0 (1) then row 1 column 1 (10): 11.
    // The least total is row 0 column 1, row 1 column 0: 2 + 3 = 5.
    const costs = [_]f64{ 1, 2, 9, inf, 3, 10, inf, 9 };
    const got = try solve(alloc, &costs, 2, 4);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, got);
}
