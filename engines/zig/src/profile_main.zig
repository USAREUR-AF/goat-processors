// A sampling profiler around the runner (profile/profile.sh), standard library
// only, for x86_64 Linux: a SIGPROF every millisecond of CPU time records the
// instruction pointer and the frame-pointer chain of callers; at exit the
// samples are written to $GOAT_PROFILE_OUT as "<count> <self|total> <address>"
// lines, resolved to functions by profile.sh with addr2line. Not part of the
// engine; built with -fno-omit-frame-pointer.
const std = @import("std");
const linux = std.os.linux;
const runner = @import("io/runner.zig");

const max_samples = 1 << 22;
const depth = 48;
// The profiler's state is process-wide by nature (a signal handler writes it).
var stacks: [max_samples][depth]usize = undefined;
var lens: [max_samples]u8 = undefined;
var count: usize = 0;

fn onSample(_: i32, _: *const linux.siginfo_t, ctx: ?*anyopaque) callconv(.C) void {
    if (count >= max_samples) return;
    const uc: *const linux.ucontext_t = @ptrCast(@alignCast(ctx.?));
    var n: usize = 0;
    stacks[count][n] = uc.mcontext.gregs[linux.REG.RIP];
    n += 1;
    var fp = uc.mcontext.gregs[linux.REG.RBP];
    while (n < depth and fp != 0 and fp % 8 == 0) {
        const frame: [*]const usize = @ptrFromInt(fp);
        const ret = frame[1];
        if (ret == 0) break;
        stacks[count][n] = ret - 1;
        n += 1;
        const next = frame[0];
        if (next <= fp) break;
        fp = next;
    }
    lens[count] = @intCast(n);
    count += 1;
}

pub fn main() !void {
    var act = linux.Sigaction{ .handler = .{ .sigaction = onSample }, .mask = linux.empty_sigset, .flags = linux.SA.SIGINFO | linux.SA.RESTART };
    _ = linux.sigaction(linux.SIG.PROF, &act, null);
    // itimerval {interval, value}, 1 ms each (the struct's second field is microseconds).
    const tv = linux.itimerspec{ .it_interval = .{ .tv_sec = 0, .tv_nsec = 1000 }, .it_value = .{ .tv_sec = 0, .tv_nsec = 1000 } };
    _ = linux.setitimer(@intFromEnum(linux.ITIMER.PROF), &tv, null);

    try runner.main();

    const off = linux.itimerspec{ .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 }, .it_value = .{ .tv_sec = 0, .tv_nsec = 0 } };
    _ = linux.setitimer(@intFromEnum(linux.ITIMER.PROF), &off, null);

    const path = std.posix.getenv("GOAT_PROFILE_OUT") orelse "profile.samples";
    var self_counts = std.AutoHashMap(usize, usize).init(std.heap.page_allocator);
    var total_counts = std.AutoHashMap(usize, usize).init(std.heap.page_allocator);
    for (0..count) |i| {
        const s = stacks[i][0..lens[i]];
        (try self_counts.getOrPutValue(s[0], 0)).value_ptr.* += 1;
        // Each address once per sample for the inclusive count.
        for (s, 0..) |addr, j| {
            const seen = for (s[0..j]) |x| {
                if (x == addr) break true;
            } else false;
            if (!seen) (try total_counts.getOrPutValue(addr, 0)).value_ptr.* += 1;
        }
    }
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    const w = bw.writer();
    try w.print("{d} samples 0\n", .{count});
    var it = self_counts.iterator();
    while (it.next()) |e| try w.print("{d} self 0x{x}\n", .{ e.value_ptr.*, e.key_ptr.* });
    var it2 = total_counts.iterator();
    while (it2.next()) |e| try w.print("{d} total 0x{x}\n", .{ e.value_ptr.*, e.key_ptr.* });
    try bw.flush();
}
