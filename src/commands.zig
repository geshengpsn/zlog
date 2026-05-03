const std = @import("std");
const Object = @import("object.zig").Object;
const Pose = @import("object.zig").Pose;

pub const Command = union(enum) {
    remove: remove_command,
    add: add_command,
    set_pose: set_pose_command,

    pub fn writeBuffer(cmd: @This(), buffer: []u8) []const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        std.json.Stringify.value(cmd, .{}, &writer) catch return buffer[0..0];
        return writer.buffered();
    }
};

pub const remove_command = struct { id: []const u8 };
pub const add_command = struct { id: []const u8, object: Object };
pub const set_pose_command = struct { id: []const u8, pose: Pose };

test "remove command" {
    const command = Command{ .remove = .{ .id = "123456" } };

    try expectCommandWrites(command, "{\"remove\":{\"id\":\"123456\"}}");
}

test "add command" {
    const command = Command{ .add = .{
        .id = "cube-1",
        .object = .{ .geometry = .{ .cube = .{ .width = 2, .height = 3, .depth = 4 } } },
    } };
    try expectCommandWrites(
        command,
        "{\"add\":{\"id\":\"cube-1\",\"object\":{\"geometry\":{\"cube\":{\"width\":2,\"height\":3,\"depth\":4}},\"material\":{\"color\":{\"r\":255,\"g\":255,\"b\":255},\"opacity\":1,\"metalness\":0,\"roughness\":0.5},\"pose\":{\"position\":[0,0,0],\"rotation\":{\"w\":1,\"x\":0,\"y\":0,\"z\":0}}}}}",
    );
}

test "set pose command" {
    const command = Command{ .set_pose = .{
        .id = "cube-1",
        .pose = .{ .position = .{ 1, 2, 3 } },
    } };
    try expectCommandWrites(
        command,
        "{\"set_pose\":{\"id\":\"cube-1\",\"pose\":{\"position\":[1,2,3],\"rotation\":{\"w\":1,\"x\":0,\"y\":0,\"z\":0}}}}",
    );
}

test "writeBuffer returns empty slice when buffer is too small" {
    const command = Command{ .remove = .{ .id = "123456" } };
    var buffer = [_]u8{0};
    const str = command.writeBuffer(&buffer);

    try std.testing.expectEqual(@as(usize, 0), str.len);
}

fn expectCommandWrites(command: Command, expected: []const u8) !void {
    var buffer = [_]u8{0} ** 1024;
    buffer[0] = 0;
    const str = command.writeBuffer(&buffer);
    try std.testing.expectEqualStrings(expected, str);
}
