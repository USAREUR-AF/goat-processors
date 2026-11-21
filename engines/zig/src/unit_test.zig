// The unit tests of every module (zig build test runs them with the vectors).
const std = @import("std");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const api = @import("api.zig");
pub const model = struct {
    pub const frame = @import("model/frame.zig");
    pub const kalman = @import("model/kalman.zig");
    pub const imm = @import("model/imm.zig");
    pub const params = @import("model/params.zig");
    pub const report = @import("model/report.zig");
};
pub const correlate = struct {
    pub const pack = @import("correlate/pack.zig");
    pub const entity = @import("correlate/entity.zig");
    pub const tests = @import("correlate/tests.zig");
    pub const engine = @import("correlate/engine.zig");
    pub const confirm = @import("correlate/confirm.zig");
    pub const estimate = @import("correlate/estimate.zig");
    pub const sprt = @import("correlate/sprt.zig");
    pub const methods = @import("correlate/methods.zig");
    pub const noop_test = @import("correlate/noop_test.zig");
};
pub const assign = struct {
    pub const assign = @import("assign/assign.zig");
    pub const bias = @import("assign/bias.zig");
    pub const membership = @import("assign/membership.zig");
    pub const ranking = @import("assign/ranking.zig");
};
pub const filter = struct {
    pub const pack = @import("filter/pack.zig");
    pub const geo = @import("filter/geo.zig");
    pub const engine = @import("filter/engine.zig");
    pub const conditions = @import("filter/conditions.zig");
};
pub const fuse = struct {
    pub const pack = @import("fuse/pack.zig");
    pub const kinematics = @import("fuse/kinematics.zig");
    pub const engine = @import("fuse/engine.zig");
    pub const attributes = @import("fuse/attributes.zig");
};
pub const quality = struct {
    pub const pack = @import("quality/pack.zig");
    pub const measures = @import("quality/measures.zig");
    pub const engine = @import("quality/engine.zig");
    pub const rules = @import("quality/rules.zig");
    pub const samples = @import("quality/samples.zig");
};
pub const trace = struct {
    pub const record = @import("trace/record.zig");
};
pub const snapshot = struct {
    pub const common = @import("snapshot/common.zig");
    pub const correlate = @import("snapshot/correlate.zig");
    pub const assign = @import("snapshot/assign.zig");
    pub const filter = @import("snapshot/filter.zig");
    pub const fuse = @import("snapshot/fuse.zig");
    pub const quality = @import("snapshot/quality.zig");
};
pub const io = struct {
    pub const json_read = @import("io/json_read.zig");
    pub const json_write = @import("io/json_write.zig");
    pub const steps = @import("io/steps.zig");
    pub const compare = @import("io/compare.zig");
    pub const vector_files = @import("io/vector_files.zig");
    pub const runner = @import("io/runner.zig");
};
