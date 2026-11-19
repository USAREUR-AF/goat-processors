// spec/correlate-assign.md (version 0.6): system tracks, per-source ranked
// assignments at each tick, a window of `n` ticks over the best `k` histories
// (kept within `margin` of the best), the inverse-variance fused estimate, the
// leave of a restarted entity (correlate.md 0.7 "Restart") and the update of
// the sensor bias offsets with their clock offsets (`bias.zig`), and the
// timing variance of correlate.md 0.8 in the Cost.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const frame = @import("frame.zig");
const kalman = @import("kalman.zig");
const bias_mod = @import("bias.zig");
const pack_mod = @import("pack.zig");
const Engine = engine_mod.Engine;
const Result = engine_mod.Result;
const lessKey = engine_mod.lessKey;

// ---- Memberships ------------------------------------------------------------

pub const System = struct { id: u64, members: std.ArrayList([]const u8) };

// One picture of the system tracks: the tracks in creation order, each with its
// members in key order, and the counter that names the next one.
pub const Membership = struct {
    systems: std.ArrayList(System),
    next_system: u64,

    pub fn init(alloc: Allocator) Membership {
        return .{ .systems = std.ArrayList(System).init(alloc), .next_system = 1 };
    }

    fn clone(self: Membership, alloc: Allocator) !Membership {
        var out = Membership{ .systems = std.ArrayList(System).init(alloc), .next_system = self.next_system };
        for (self.systems.items) |s| {
            var list = std.ArrayList([]const u8).init(alloc);
            try list.appendSlice(s.members.items);
            try out.systems.append(.{ .id = s.id, .members = list });
        }
        return out;
    }

    fn systemOf(self: Membership, key: []const u8) ?u64 {
        for (self.systems.items) |s| {
            for (s.members.items) |m| if (std.mem.eql(u8, m, key)) return s.id;
        }
        return null;
    }

    fn index(self: Membership, id: u64) usize {
        for (self.systems.items, 0..) |s, i| if (s.id == id) return i;
        unreachable;
    }

    fn members(self: Membership, id: u64) []const []const u8 {
        return self.systems.items[self.index(id)].members.items;
    }
};

// A leaves its system track (`leave`), which ends when left empty (`end`).
fn leave(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), key: []const u8, reason: []const u8) !void {
    const id = m.systemOf(key).?;
    const i = m.index(id);
    const list = &m.systems.items[i].members;
    for (list.items, 0..) |x, j| {
        if (std.mem.eql(u8, x, key)) {
            _ = list.orderedRemove(j);
            break;
        }
    }
    const name = try eng.groupName(id);
    try events.append(try eng.object(.{ .{ "ev", "leave" }, .{ "system", name }, .{ "entity", key }, .{ "reason", reason } }));
    if (list.items.len == 0) {
        _ = m.systems.orderedRemove(i);
        try events.append(try eng.object(.{ .{ "ev", "end" }, .{ "system", name } }));
    }
}

fn join(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), id: u64, key: []const u8) !void {
    try Engine.insertSorted(&m.systems.items[m.index(id)].members, key);
    try events.append(try eng.object(.{ .{ "ev", "join" }, .{ "system", try eng.groupName(id) }, .{ "entity", key } }));
}

fn start(eng: *Engine, m: *Membership, events: *std.ArrayList(json.Value), key: []const u8) !void {
    const id = m.next_system;
    m.next_system += 1;
    var list = std.ArrayList([]const u8).init(eng.alloc());
    try list.append(key);
    try m.systems.append(.{ .id = id, .members = list });
    try events.append(try eng.object(.{ .{ "ev", "start" }, .{ "system", try eng.groupName(id) }, .{ "entity", key } }));
}

// `[entity, chosen]`; `chosen` null is `alone`.
const Choice = struct { entity: []const u8, chosen: ?u64 };

// One pending tick of a history.
const Record = struct {
    cost: f64,
    choices: std.ArrayList(Choice),
    events: std.ArrayList(json.Value),
    membership: Membership,

    fn clone(self: Record, alloc: Allocator) !Record {
        var choices = std.ArrayList(Choice).init(alloc);
        try choices.appendSlice(self.choices.items);
        var events = std.ArrayList(json.Value).init(alloc);
        try events.appendSlice(self.events.items);
        return .{ .cost = self.cost, .choices = choices, .events = events, .membership = try self.membership.clone(alloc) };
    }
};

const History = struct {
    records: std.ArrayList(Record),

    // The sum, left to right from 0, of the records' `cost`, oldest first.
    fn total(self: History) f64 {
        var t: f64 = 0;
        for (self.records.items) |r| t += r.cost;
        return t;
    }

    fn newest(self: History) *Record {
        return &self.records.items[self.records.items.len - 1];
    }
};

fn choicesEqual(x: []const Choice, y: []const Choice) bool {
    if (x.len != y.len) return false;
    for (x, y) |a, b| {
        if (!std.mem.eql(u8, a.entity, b.entity)) return false;
        if (a.chosen != b.chosen) return false;
    }
    return true;
}

// The method's state beyond the entities: the committed membership, the
// histories in rank order, and the retiring entities.
pub const State = struct {
    committed: Membership,
    histories: std.ArrayList(History),
    retiring: std.StringArrayHashMap(void),
    // "Sensor bias": the stored offsets, used only with `bias`.
    bias: bias_mod.State,

    pub fn init(alloc: Allocator) !State {
        // At the start there is one history with no records.
        var histories = std.ArrayList(History).init(alloc);
        try histories.append(.{ .records = std.ArrayList(Record).init(alloc) });
        return .{
            .committed = Membership.init(alloc),
            .histories = histories,
            .retiring = std.StringArrayHashMap(void).init(alloc),
            .bias = bias_mod.State.init(alloc),
        };
    }

    // A history's latest membership: its newest record's, or the committed one.
    fn latest(self: *State, h: History) Membership {
        return if (h.records.items.len == 0) self.committed else h.newest().membership;
    }
};

pub fn isRetiring(eng: *Engine, key: []const u8) bool {
    return eng.assign_state.retiring.contains(key);
}

// ---- Assignment of one source -------------------------------------------------

// "Fused estimate", one axis: inverse-variance weights of the members' predictions.
const FusedAxis = struct { p: f64, v: f64, pp: f64, vv: f64 };
const Fused = struct { east: FusedAxis, north: FusedAxis };

fn fuseAxis(axes: []const kalman.Axis) FusedAxis {
    var ipp: f64 = 0;
    var ivv: f64 = 0;
    var sp: f64 = 0;
    var sv: f64 = 0;
    for (axes) |a| {
        ipp += 1.0 / a.pp;
        sp += a.p / a.pp;
        ivv += 1.0 / a.vv;
        sv += a.v / a.vv;
    }
    const pp = 1.0 / ipp;
    const vv = 1.0 / ivv;
    return .{ .p = pp * sp, .v = vv * sv, .pp = pp, .vv = vv };
}

// Members in key order, each predicted to `t_ms`. With `frame_of` (an entity's
// source) the estimate is for a comparison ("Cost"): each member's predicted
// `pp` gets its timing variance (correlate.md 0.8), then, with the pack's
// `bias`, the member is moved into that source's frame ("Sensor bias"). An
// estimate for output (`frame_of` null) does neither.
fn fused(eng: *Engine, members: []const []const u8, t_ms: i64, frame_of: ?[]const u8) !Fused {
    const a = eng.alloc();
    const east = try a.alloc(kalman.Axis, members.len);
    const north = try a.alloc(kalman.Axis, members.len);
    for (members, 0..) |m, i| {
        const e = eng.entities.get(m).?;
        var f = if (frame_of != null) e.predictedForComparison(t_ms, eng.pack) else e.predictedTo(t_ms, eng.pack);
        if (eng.pack.bias) |bp| {
            if (frame_of) |src| f = try bias_mod.moveInto(a, &eng.assign_state.bias, bp, eng.pack.time_offset, src, e.source, f);
        }
        east[i] = f.east;
        north[i] = f.north;
    }
    return .{ .east = fuseAxis(east), .north = fuseAxis(north) };
}

// "Cost": d² of A against the fused estimate of M, both at A's `last_time_ms`;
// `pp_a` is A's filter `pp` plus A's timing variance (0.6).
fn cost(eng: *Engine, a_key: []const u8, members: []const []const u8) !f64 {
    const a = eng.entities.get(a_key).?;
    const m = try fused(eng, members, a.last_time_ms, a.source);
    const pp_a_east = a.filter.east.pp + a.time_var_east;
    const pp_a_north = a.filter.north.pp + a.time_var_north;
    const de = a.filter.east.p - m.east.p;
    const dn = a.filter.north.p - m.north.p;
    return de * de / (pp_a_east + m.east.pp) + dn * dn / (pp_a_north + m.north.pp);
}

const Column = struct { id: u64, others: []const []const u8 };

// Steps 1 and 2: the columns, and per row an entry for each column then its own
// `alone` at index `cols.len`; null is a forbidden entry.
const Entries = struct {
    cols: []const Column,
    rows: []const []const u8,
    values: []const ?f64, // rows.len by cols.len + 1, row-major

    fn at(self: Entries, i: usize, j: usize) ?f64 {
        return self.values[i * (self.cols.len + 1) + j];
    }

    fn chosenId(self: Entries, j: usize) ?u64 {
        return if (j < self.cols.len) self.cols[j].id else null;
    }
};

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, key)) return true;
    return false;
}

fn entries(eng: *Engine, res: *Result, m: Membership, source: []const u8, rows: []const []const u8) !Entries {
    const a = eng.alloc();

    // 1. Columns: R left out, not empty, no entity of S; creation order.
    var cols = std.ArrayList(Column).init(a);
    for (m.systems.items) |s| {
        var others = std.ArrayList([]const u8).init(a);
        var has_s = false;
        for (s.members.items) |x| {
            if (contains(rows, x)) continue;
            if (std.mem.eql(u8, eng.entities.get(x).?.source, source)) has_s = true;
            try others.append(x);
        }
        if (others.items.len == 0 or has_s) continue;
        try cols.append(.{ .id = s.id, .others = others.items });
    }

    // 2. Entries, with the gate records in the order the tests run.
    const width = cols.items.len + 1;
    const values = try a.alloc(?f64, rows.len * width);
    for (rows, 0..) |r, i| {
        const own = m.systemOf(r);
        for (cols.items, 0..) |c, j| {
            values[i * width + j] = null;
            var ok = true;
            for (c.others) |o| {
                if (!try eng.runTests(res, .gate, eng.pack.gate, r, o)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            var d2 = try cost(eng, r, c.others);
            if (own != null and own.? == c.id) d2 -= eng.pack.keep_bonus;
            values[i * width + j] = d2;
        }
        var alone = eng.pack.new_cost;
        if (own) |id| {
            if (m.members(id).len == 1) alone -= eng.pack.keep_bonus;
        }
        values[i * width + cols.items.len] = alone;
    }
    const e = Entries{ .cols = cols.items, .rows = rows, .values = values };

    // The cost records, entities in key order, columns in creation order then `alone`.
    for (rows, 0..) |r, i| {
        for (cols.items, 0..) |c, j| try assignRecord(eng, res, r, try eng.groupName(c.id), "cost", e.at(i, j));
        try assignRecord(eng, res, r, "alone", "cost", e.at(i, cols.items.len));
    }
    return e;
}

fn assignRecord(eng: *Engine, res: *Result, a: []const u8, b: []const u8, test_name: []const u8, value: ?f64) !void {
    try res.trace.append(try eng.object(.{
        .{ "stage", "assign" },
        .{ "a", a },
        .{ "b", b },
        .{ "test", test_name },
        .{ "value", value },
        .{ "limit", json.Value{ .null = {} } },
        .{ "pass", value != null },
    }));
}

// ---- Ranking ------------------------------------------------------------------

// `choice[i]` is row i's column index, `cols.len` for `alone`: the choice vector.
const Assignment = struct { choice: []const usize, total: f64 };

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
fn ranked(alloc: Allocator, e: Entries, k: usize) ![]const Assignment {
    var all = std.ArrayList(Assignment).init(alloc);
    const choice = try alloc.alloc(usize, e.rows.len);
    const used = try alloc.alloc(bool, e.cols.len);
    @memset(used, false);
    try enumerate(alloc, e, 0, choice, used, &all);
    std.mem.sort(Assignment, all.items, {}, ranksBefore);
    return all.items[0..@min(k, all.items.len)];
}

// Step 4, apply: entities of R in key order. Adds the choices, events and cost to `rec`.
fn apply(eng: *Engine, rec: *Record, e: Entries, asg: Assignment) !void {
    const m = &rec.membership;
    for (e.rows, asg.choice) |r, j| {
        const chosen = e.chosenId(j);
        try rec.choices.append(.{ .entity = r, .chosen = chosen });
        const own = m.systemOf(r);
        if (chosen) |target| {
            if (own != null and own.? == target) continue;
            if (own != null) try leave(eng, m, &rec.events, r, "assign");
            try join(eng, m, &rec.events, target, r);
        } else {
            if (own) |id| {
                if (m.members(id).len == 1) continue;
                try leave(eng, m, &rec.events, r, "assign");
            }
            try start(eng, m, &rec.events, r);
        }
    }
    rec.cost += asg.total;
}

// ---- Window -------------------------------------------------------------------

// With `window` above 1, the trace records from `from` on get `"h"` and, when given, `"r"`.
fn tag(res: *Result, from: usize, h: usize, r: ?usize) !void {
    for (res.trace.items[from..]) |*rec| {
        try rec.object.put("h", .{ .integer = @intCast(h) });
        if (r) |x| try rec.object.put("r", .{ .integer = @intCast(x) });
    }
}

const Candidate = struct { history: History, total: f64, h: usize, r: usize };

fn candidateBefore(_: void, x: Candidate, y: Candidate) bool {
    if (x.total != y.total) return x.total < y.total;
    if (x.h != y.h) return x.h < y.h;
    return x.r < y.r;
}

// Step 3, one source S with its rows R (key order), over every history.
fn assignSource(eng: *Engine, res: *Result, source: []const u8, rows: []const []const u8) !void {
    const a = eng.alloc();
    const st = &eng.assign_state;
    const windowed = eng.pack.window > 1;
    const k: usize = @intCast(eng.pack.hypotheses);

    var candidates = std.ArrayList(Candidate).init(a);
    for (st.histories.items, 0..) |hist, h| {
        const rec = hist.newest().*;
        const from = res.trace.items.len;
        const e = try entries(eng, res, rec.membership, source, rows);
        if (windowed) try tag(res, from, h, null);

        for (try ranked(a, e, k), 0..) |asg, r| {
            const choice_from = res.trace.items.len;
            for (rows, asg.choice, 0..) |row, j, i| {
                const b = if (e.chosenId(j)) |id| try eng.groupName(id) else "alone";
                try assignRecord(eng, res, row, b, "choice", e.at(i, j));
            }
            if (windowed) try tag(res, choice_from, h, r);

            // The candidate: `h` with its newest record replaced by a copy with `r` applied.
            var records = std.ArrayList(Record).init(a);
            try records.appendSlice(hist.records.items[0 .. hist.records.items.len - 1]);
            var copy = try rec.clone(a);
            try apply(eng, &copy, e, asg);
            try records.append(copy);
            const cand = History{ .records = records };
            try candidates.append(.{ .history = cand, .total = cand.total(), .h = h, .r = r });
        }
    }

    // Candidates by total, then h, then r; the first k are the histories. With
    // `margin`, of those only the ones with total at most `cut = best + margin`.
    std.mem.sort(Candidate, candidates.items, {}, candidateBefore);
    const cut: ?f64 = if (eng.pack.margin) |m| candidates.items[0].total + m else null;
    st.histories.clearRetainingCapacity();
    for (candidates.items, 0..) |c, i| {
        var kept = i < k;
        if (cut) |limit| kept = kept and c.total <= limit;
        if (kept) try st.histories.append(c.history);
        if (windowed) try historyRecord(eng, res, .{ .integer = @intCast(c.h) }, .{ .integer = @intCast(c.r) }, "total", c.total, if (cut) |x| json.Value{ .float = x } else .null, kept);
    }
}

fn historyRecord(eng: *Engine, res: *Result, a: json.Value, b: json.Value, test_name: []const u8, value: f64, limit: json.Value, pass: bool) !void {
    try res.trace.append(try eng.object(.{
        .{ "stage", "history" },
        .{ "a", a },
        .{ "b", b },
        .{ "test", test_name },
        .{ "value", value },
        .{ "limit", limit },
        .{ "pass", pass },
    }));
}

fn isStale(eng: *Engine, key: []const u8, now_ms: i64) bool {
    const e = eng.entities.get(key).?;
    const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
    return now_ms - e.last_time_ms > eng.pack.stale_ms or own_stale;
}

// "Window", on each tick.
pub fn tick(eng: *Engine, now_ms: i64) !Result {
    const a = eng.alloc();
    const st = &eng.assign_state;
    const windowed = eng.pack.window > 1;
    var res = Result{ .events = json.Array.init(a), .trace = json.Array.init(a) };

    // 1. Staleness, among entities not retiring, in key order.
    const restarted = try a.dupe([]const u8, eng.restarted.keys());
    std.mem.sort([]const u8, restarted, {}, lessKey);
    var stale = std.ArrayList([]const u8).init(a);
    for (try eng.sortedKeys()) |key| {
        if (!st.retiring.contains(key) and isStale(eng, key, now_ms)) try stale.append(key);
    }
    for (st.histories.items) |*hist| {
        var rec = Record{
            .cost = 0,
            .choices = std.ArrayList(Choice).init(a),
            .events = std.ArrayList(json.Value).init(a),
            .membership = try st.latest(hist.*).clone(a),
        };
        for (stale.items) |key| {
            if (rec.membership.systemOf(key) != null) try leave(eng, &rec.membership, &rec.events, key, "stale");
            try rec.events.append(try eng.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
        }
        // Each restarted entity that is not stale leaves its system track.
        for (restarted) |key| {
            if (contains(stale.items, key)) continue;
            if (rec.membership.systemOf(key) != null) try leave(eng, &rec.membership, &rec.events, key, "restart");
        }
        try hist.records.append(rec);
    }
    // No entity is restarted after this step.
    eng.restarted.clearRetainingCapacity();
    for (stale.items) |key| {
        try st.retiring.put(key, {});
        _ = eng.reported.orderedRemove(key);
    }

    // 2. Rows: the entities reported since the previous tick, grouped by source.
    const reported = try a.dupe([]const u8, eng.reported.keys());
    std.mem.sort([]const u8, reported, {}, lessKey);
    eng.reported.clearRetainingCapacity();
    var sources = std.ArrayList([]const u8).init(a);
    for (reported) |key| {
        const src = eng.entities.get(key).?.source;
        if (!contains(sources.items, src)) try sources.append(src);
    }
    std.mem.sort([]const u8, sources.items, {}, lessKey);

    // 3. Sources, in key order.
    for (sources.items) |src| {
        var rows = std.ArrayList([]const u8).init(a);
        for (reported) |key| if (std.mem.eql(u8, eng.entities.get(key).?.source, src)) try rows.append(key);
        try assignSource(eng, &res, src, rows.items);
    }

    // 4. Commit, when the best history has `window` records.
    const best = st.histories.items[0];
    if (best.records.items.len == @as(usize, @intCast(eng.pack.window))) {
        const done = best.records.items[0];
        var kept = std.ArrayList(History).init(a);
        for (st.histories.items, 0..) |hist, rank| {
            const keep = choicesEqual(hist.records.items[0].choices.items, done.choices.items);
            if (windowed) try historyRecord(eng, &res, .{ .integer = @intCast(rank) }, .null, "commit", hist.total(), .null, keep);
            if (!keep) continue;
            var records = std.ArrayList(Record).init(a);
            try records.appendSlice(hist.records.items[1..]);
            try kept.append(.{ .records = records });
        }
        try res.events.appendSlice(done.events.items);
        st.committed = done.membership;
        for (done.events.items) |ev| {
            if (!std.mem.eql(u8, ev.object.get("ev").?.string, "drop")) continue;
            const key = ev.object.get("entity").?.string;
            _ = eng.entities.orderedRemove(key);
            _ = st.retiring.orderedRemove(key);
        }
        st.histories = kept;
    }

    // 5. Bias: the update of Sensor bias, from the committed membership.
    if (eng.pack.bias) |bp| try updateBias(eng, &res, bp, reported, now_ms);

    // 6. Output: one `system` per committed system track, retiring members
    // included; with `margin`, per system track of the best history's latest membership.
    const reported_systems = if (eng.pack.margin != null) st.latest(st.histories.items[0]) else st.committed;
    for (reported_systems.systems.items) |s| try res.events.append(try systemEvent(eng, s, now_ms));
    // Then, with a window, one `provisional` per system track of the best history.
    if (windowed) {
        for (st.latest(st.histories.items[0]).systems.items) |s| {
            try res.events.append(try eng.object(.{
                .{ "ev", "provisional" },
                .{ "system", try eng.groupName(s.id) },
                .{ "members", try eng.stringList(s.members.items) },
            }));
        }
    }
    return res;
}

// "Sensor bias", Update: committed system tracks in creation order, their members
// not retiring in key order, each pair X before Y of two sources with at least
// one of them among the tick's rows.
fn updateBias(eng: *Engine, res: *Result, bp: pack_mod.Bias, rows: []const []const u8, now_ms: i64) !void {
    const a = eng.alloc();
    const st = &eng.assign_state;
    for (st.committed.systems.items) |s| {
        var members = std.ArrayList([]const u8).init(a);
        for (s.members.items) |m| if (!st.retiring.contains(m)) try members.append(m);
        for (members.items, 0..) |x, i| {
            for (members.items[i + 1 ..]) |y| {
                const ex = eng.entities.get(x).?;
                const ey = eng.entities.get(y).?;
                if (std.mem.eql(u8, ex.source, ey.source)) continue;
                if (!contains(rows, x) and !contains(rows, y)) continue;
                // 1. ES is the entity whose source is first in key order, ET the other.
                const es, const et = if (lessKey({}, ex.source, ey.source)) .{ ex, ey } else .{ ey, ex };
                const key = try bias_mod.pairKey(a, es.source, et.source);
                // 2 and 3.
                const o = try bias_mod.update(a, &st.bias, bp, eng.pack.time_offset, key, es.predictedTo(now_ms, eng.pack), et.predictedTo(now_ms, eng.pack));
                // 4. Trace, with the state after step 3.
                var rec = try eng.object(.{
                    .{ "stage", "bias" },
                    .{ "a", x },
                    .{ "b", y },
                    .{ "test", "offset" },
                    .{ "value", o.d2 },
                    .{ "limit", bp.gate },
                    .{ "pass", o.accepted },
                    .{ "east", o.after.east },
                    .{ "north", o.after.north },
                    .{ "var", o.after.variance },
                    .{ "pairs", o.after.pairs },
                });
                // "Time offset": the record adds `time_offset_ms`, tau*1000.
                if (eng.pack.time_offset != null) try rec.object.put("time_offset_ms", .{ .float = o.after.tau * 1000.0 });
                try res.trace.append(rec);
            }
        }
    }
}

fn systemEvent(eng: *Engine, s: System, now_ms: i64) !json.Value {
    const f = try fused(eng, s.members.items, now_ms, null);
    const pos = eng.ref.?.toDegrees(.{ .east = f.east.p, .north = f.north.p });
    var course = frame.deg(std.math.atan2(f.east.v, f.north.v));
    if (course < 0) course += 360.0;
    if (course >= 360.0) course -= 360.0;
    var ev = try eng.object(.{
        .{ "ev", "system" },
        .{ "system", try eng.groupName(s.id) },
        .{ "members", try eng.stringList(s.members.items) },
        .{ "lat", pos.lat },
        .{ "lon", pos.lon },
        .{ "course", course },
        .{ "speed_ms", std.math.hypot(f.east.v, f.north.v) },
    });
    // `hae` from the member with the greatest `last_time_ms` that has one; ties to key order.
    var top: ?struct { t: i64, hae: f64 } = null;
    for (s.members.items) |mk| {
        const e = eng.entities.get(mk).?;
        const hae = e.number("hae") orelse continue;
        if (top == null or e.last_time_ms > top.?.t) top = .{ .t = e.last_time_ms, .hae = hae };
    }
    if (top) |b| try ev.object.put("hae", .{ .float = b.hae });
    return ev;
}

// ---- Snapshot -----------------------------------------------------------------

fn systemsValue(eng: *Engine, m: Membership) !json.Value {
    var systems = json.ObjectMap.init(eng.alloc());
    for (m.systems.items) |s| try systems.put(try eng.groupName(s.id), try eng.stringList(s.members.items));
    return .{ .object = systems };
}

fn sortedList(eng: *Engine, keys: []const []const u8) !json.Value {
    const sorted = try eng.alloc().dupe([]const u8, keys);
    std.mem.sort([]const u8, sorted, {}, lessKey);
    return eng.stringList(sorted);
}

fn historyValue(eng: *Engine, hist: History) !json.Value {
    const a = eng.alloc();
    var records = json.Array.init(a);
    for (hist.records.items) |rec| {
        var choices = json.Array.init(a);
        for (rec.choices.items) |c| {
            var pair = json.Array.init(a);
            try pair.append(.{ .string = c.entity });
            try pair.append(.{ .string = if (c.chosen) |id| try eng.groupName(id) else "alone" });
            try choices.append(.{ .array = pair });
        }
        var events = json.Array.init(a);
        try events.appendSlice(rec.events.items);
        try records.append(try eng.object(.{
            .{ "cost", rec.cost },
            .{ "choices", json.Value{ .array = choices } },
            .{ "events", json.Value{ .array = events } },
            .{ "systems", try systemsValue(eng, rec.membership) },
            .{ "next_system", rec.membership.next_system },
        }));
    }
    return eng.object(.{ .{ "total", hist.total() }, .{ "records", json.Value{ .array = records } } });
}

pub fn snapshot(eng: *Engine) !json.Value {
    const a = eng.alloc();
    const st = &eng.assign_state;
    var ref: json.Value = .null;
    if (eng.ref) |r| {
        var arr = json.Array.init(a);
        try arr.append(.{ .float = r.lat0 });
        try arr.append(.{ .float = r.lon0 });
        ref = .{ .array = arr };
    }
    var entities = json.ObjectMap.init(a);
    for (try eng.sortedKeys()) |key| {
        const e = eng.entities.get(key).?;
        const system: ?[]const u8 = if (st.committed.systemOf(key)) |id| try eng.groupName(id) else null;
        var obj = try eng.object(.{ .{ "last_time_ms", e.last_time_ms }, .{ "system", system } });
        try eng.putFilter(&obj.object, e);
        try entities.put(key, obj);
    }
    var out = try eng.object(.{
        .{ "ref", ref },
        .{ "entities", json.Value{ .object = entities } },
        .{ "systems", try systemsValue(eng, st.committed) },
        .{ "next_system", st.committed.next_system },
        .{ "reported", try sortedList(eng, eng.reported.keys()) },
    });
    // With `restart`: the restarted entities. With `bias`: the stored pairs, keys in order.
    if (eng.pack.restart != null) try out.object.put("restarted", try sortedList(eng, eng.restarted.keys()));
    if (eng.pack.bias != null) {
        var pairs = json.ObjectMap.init(a);
        const keys = try a.dupe([]const u8, st.bias.pairs.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        for (keys) |key| {
            const p = st.bias.pairs.get(key).?;
            var pair = try eng.object(.{
                .{ "east", p.east },
                .{ "weight_east", p.weight_east },
                .{ "north", p.north },
                .{ "weight_north", p.weight_north },
                .{ "var", p.variance },
                .{ "pairs", p.pairs },
            });
            // With `time_offset`: `time_offset_ms` (tau*1000) and `sums` ([S1, ..., S8]).
            if (eng.pack.time_offset != null) {
                try pair.object.put("time_offset_ms", .{ .float = p.tau * 1000.0 });
                var sums = json.Array.init(a);
                for (p.sums) |x| try sums.append(.{ .float = x });
                try pair.object.put("sums", .{ .array = sums });
            }
            try pairs.put(key, pair);
        }
        try out.object.put("bias", .{ .object = pairs });
    }
    // With a window: the retiring entities and the histories in rank order.
    if (eng.pack.window > 1) {
        try out.object.put("retiring", try sortedList(eng, st.retiring.keys()));
        var histories = json.Array.init(a);
        for (st.histories.items) |hist| try histories.append(try historyValue(eng, hist));
        try out.object.put("histories", .{ .array = histories });
    }
    return out;
}
