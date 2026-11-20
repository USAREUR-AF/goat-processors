// spec/quality.md "Rules", evaluation: one rule for one subject at a tick, a
// pure step from the rule's state and the measure's value to the next state.
// The engine writes the `action-start`/`action-end` event and the `rule` record.
const std = @import("std");
const qpack = @import("pack.zig");
const measures = @import("measures.zig");
const Rule = qpack.Rule;
const Num = measures.Num;

// "Rules": per rule, per subject.
pub const RuleState = struct { count: i64, active: bool };

pub const Change = enum { none, start, end };

pub const Step = struct {
    state: RuleState,
    pass: bool,
    // The `limit` of the trace record: `limit` while inactive, `clear` while active.
    shown_limit: f64,
    change: Change,
};

// An inactive rule counts the ticks its condition holds and starts at `for`;
// an active one ends when the clear test passes. An absent value never passes.
pub fn step(rule: Rule, st: RuleState, value: ?Num) Step {
    const v: ?f64 = if (value) |x| x.toF64() else null;
    var next = st;
    if (!st.active) {
        const pass = v != null and rule.op.holds(v.?, rule.limit);
        next.count = if (pass) st.count + 1 else 0;
        if (next.count >= rule.for_n) {
            next.active = true;
            next.count = 0;
            return .{ .state = next, .pass = pass, .shown_limit = rule.limit, .change = .start };
        }
        return .{ .state = next, .pass = pass, .shown_limit = rule.limit, .change = .none };
    }
    const pass = v != null and rule.op.clears(v.?, rule.clear);
    if (pass) next.active = false;
    return .{ .state = next, .pass = pass, .shown_limit = rule.clear, .change = if (pass) .end else .none };
}

test "a rule starts after `for` passing ticks and ends at the clear test" {
    const rule = Rule{ .name = "r", .scope = .entity, .measure = .age, .op = .gt, .limit = 10, .for_n = 2, .clear = 5, .action = .mark, .factor = null };
    var st = RuleState{ .count = 0, .active = false };
    var s = step(rule, st, .{ .int = 11 });
    try std.testing.expect(s.pass and s.change == .none and s.state.count == 1);
    st = s.state;
    s = step(rule, st, .{ .int = 12 });
    try std.testing.expect(s.change == .start and s.state.active and s.state.count == 0);
    st = s.state;
    s = step(rule, st, .{ .int = 7 });
    try std.testing.expect(!s.pass and s.change == .none and s.shown_limit == 5);
    s = step(rule, st, null);
    try std.testing.expect(!s.pass and s.state.active);
    s = step(rule, st, .{ .float = 4.5 });
    try std.testing.expect(s.pass and s.change == .end and !s.state.active);
    // An absent value resets the count of an inactive rule.
    s = step(rule, .{ .count = 1, .active = false }, null);
    try std.testing.expect(!s.pass and s.state.count == 0);
}
