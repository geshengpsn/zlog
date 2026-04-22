const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const monitor = try zlog.Monitor.open(init.io, 5679);
    defer monitor.stop(init.io);

    for (0..1000) |i| {
        try monitor.log(init.io, "hello", .{ .Transform = .{
            .x = 0,
            .y = 0,
            .z = @floatFromInt(i / 1000),
            .w = 0,
            .i = 0,
            .j = 0,
            .k = 0,
        } });
        try init.io.sleep(std.Io.Duration.fromMilliseconds(60), std.Io.Clock.real);
    }
}
