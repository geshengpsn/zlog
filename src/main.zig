const std = @import("std");
const zlog = @import("zlog");

pub fn main(init: std.process.Init) !void {
    const monitor = try zlog.Viewer.open(init.arena.allocator(), init.io, 5679);
    defer monitor.stop(init.io);
}
