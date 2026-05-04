const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const viewer = try zlog.Viewer.open(init.arena.allocator(), init.io, 5679);
    defer viewer.stop(init.io);

    try viewer.createObject(init.io, "test_id", zlog.Geometry{ .cube = .{ .depth = 1, .height = 1, .width = 1 } }, .{}, .{});

    for (0..100) |i| {
        const p: zlog.Pose = .{ .position = .{ 0, 0, @as(f64, @floatFromInt(i)) * 0.01 } };
        try viewer.setPose(init.io, "test_id", p);
        try init.io.sleep(std.Io.Duration.fromMilliseconds(10), std.Io.Clock.real);
    }
}
