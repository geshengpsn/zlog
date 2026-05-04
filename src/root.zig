const std = @import("std");
const objects = @import("object.zig");
const commands = @import("commands.zig");
const Command = commands.Command;
const Io = std.Io;
const net = Io.net;
const http = std.http;

pub const Geometry = objects.Geometry;
pub const ArrowGeometry = objects.ArrowGeometry;
pub const CubeGeometry = objects.CubeGeometry;
pub const CylinderGeometry = objects.CylinderGeometry;
pub const FrameGeometry = objects.FrameGeometry;
pub const SphereGeometry = objects.SphereGeometry;
pub const Color = objects.Color;
pub const Material = objects.Material;
pub const Pose = objects.Pose;

pub const Viewer = struct {
    queue_buffer: [1024]Command,
    queue: Io.Queue(Command),
    server_thread: ?std.Thread,
    listen_port: u16,
    address_mutex: Io.Mutex,
    connected_address: ?net.IpAddress,
    start_server_event: Io.Event,
    connected_ws_event: Io.Event,
    stop_event: Io.Event,

    const Status = enum {
        unconnected,
        connected,
    };

    pub fn open(allocator: std.mem.Allocator, io: std.Io, port: ?u16) !*@This() {
        const monitor = try allocator.create(@This());
        monitor.* = .{
            .queue_buffer = undefined,
            .queue = undefined,
            .server_thread = null,
            .listen_port = 0,
            .address_mutex = .init,
            .connected_address = null,
            .start_server_event = .unset,
            .connected_ws_event = .unset,
            .stop_event = .unset,
        };
        monitor.queue = Io.Queue(Command).init(monitor.queue_buffer[0..]);

        const listen_port = port orelse 5678;
        monitor.listen_port = listen_port;
        const address = net.IpAddress{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = listen_port,
        } };

        monitor.server_thread = try std.Thread.spawn(.{}, startServer, .{ io, address, &monitor.start_server_event, &monitor.connected_ws_event, &monitor.stop_event, &monitor.connected_address, &monitor.address_mutex, &monitor.queue });

        try monitor.start_server_event.wait(io);
        std.log.info("open browser at http://127.0.0.1:{d}/?port={d}", .{ listen_port, listen_port });

        var url_buffer: [126]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/?port={d}", .{ listen_port, listen_port });
        _ = try std.process.spawn(io, .{
            .argv = &.{ "open", url },
        });

        try monitor.connected_ws_event.wait(io);
        std.log.info("connected ws: {f}", .{monitor.connected_address orelse unreachable});

        return monitor;
    }

    pub fn stop(monitor: *@This(), io: Io) void {
        if (!monitor.stop_event.isSet()) {
            monitor.stop_event.set(io);
            monitor.queue.close(io);

            const wake_address = net.IpAddress{ .ip4 = .{
                .bytes = .{ 127, 0, 0, 1 },
                .port = monitor.listen_port,
            } };
            if (wake_address.connect(io, .{ .mode = .stream })) |stream| {
                stream.close(io);
            } else |err| {
                std.debug.print("monitor stop wake failed: {s}\n", .{@errorName(err)});
            }
        }

        if (monitor.server_thread) |server_thread| {
            server_thread.join();
            monitor.server_thread = null;
        }
    }

    fn log(
        monitor: *@This(),
        io: Io,
        data: Command,
    ) !void {
        try monitor.queue.putOne(io, data);
    }

    pub fn removeObject(viewer: *@This(), io: Io, id: []const u8) !void {
        try viewer.log(io, Command{ .remove = .{ .id = id } });
    }

    pub fn setPose(viewer: *@This(), io: Io, id: []const u8, pose: Pose) !void {
        try viewer.log(io, Command{ .set_pose = .{ .id = id, .pose = pose } });
    }

    pub fn createObject(viewer: *@This(), io: Io, id: []const u8, geometry: Geometry, material: Material, pose: Pose) !void {
        try viewer.log(io, Command{ .add = .{ .id = id, .object = .{ .geometry = geometry, .material = material, .pose = pose } } });
    }
};

fn startServer(io: Io, address: net.IpAddress, start_server_event: *Io.Event, connected_ws_event: *Io.Event, stop_event: *Io.Event, connected_address: *?net.IpAddress, address_mutex: *Io.Mutex, ch: *Io.Queue(Command)) !void {
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);
    start_server_event.set(io);
    while (true) {
        if (stop_event.isSet()) {
            break;
        }

        const stream = tcp_server.accept(io) catch |err| {
            if (stop_event.isSet()) {
                break;
            }
            std.debug.print("accept failed: {s}\n", .{@errorName(err)});
            continue;
        };

        if (stop_event.isSet()) {
            stream.close(io);
            break;
        }

        if (!connected_ws_event.isSet()) {
            var connection_thread = std.Thread.spawn(.{}, handleConnection, .{ io, stream, address_mutex, connected_address, connected_ws_event, ch }) catch |err| {
                std.debug.print("connection thread spawn failed: {s}\n", .{@errorName(err)});
                stream.close(io);
                continue;
            };
            connection_thread.detach();
        } else {
            stream.close(io);
        }
    }
}

fn handleConnection(io: Io, stream: net.Stream, address_mutex: *Io.Mutex, connected_address: *?net.IpAddress, connected_ws_event: *Io.Event, ch: *Io.Queue(Command)) void {
    defer {
        var stream_copy = stream;
        stream_copy.close(io);
    }
    const address = stream.socket.address;

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.debug.print("request read failed: {s}\n", .{@errorName(err)});
                return;
            },
        };
        // std.log.info("request: {s}", .{request.head_buffer});

        if (std.mem.eql(u8, request.head.target, "/ws")) {
            switch (request.upgradeRequested()) {
                .websocket => |opt_key| {
                    const key = opt_key orelse {
                        respondText(&request, .bad_request, "missing Sec-WebSocket-Key\n");
                        continue;
                    };

                    var ws = request.respondWebSocket(.{ .key = key }) catch |err| {
                        std.debug.print("websocket upgrade failed: {s}\n", .{@errorName(err)});
                        return;
                    };

                    address_mutex.lockUncancelable(io);
                    connected_address.* = address;
                    address_mutex.unlock(io);
                    connected_ws_event.set(io);

                    // ws.writeMessage("connected\n", .text) catch |err| {
                    //     std.debug.print("websocket welcome failed: {s}\n", .{@errorName(err)});
                    //     return;
                    // };

                    serveWebSocket(&ws, io, ch);
                    return;
                },
                .other => |name| {
                    std.debug.print("unsupported upgrade request: {s}\n", .{name});
                    respondText(&request, .bad_request, "unsupported upgrade request\n");
                    continue;
                },
                .none => {
                    respondText(&request, .bad_request, "expected websocket upgrade on /ws\n");
                    continue;
                },
            }
        }

        // std.debug.print("{s}", .{request.head.target});
        // const a = std.mem.startsWith(u8, request.head.target, "/?port=");
        var iter = std.mem.splitSequence(u8, request.head.target, "?");

        if (std.mem.eql(u8, iter.first(), "/")) {
            request.respond(@embedFile("index.html"), .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            }) catch |err| {
                std.debug.print("failed to send index page: {s}\n", .{@errorName(err)});
                return;
            };
            continue;
        }

        respondText(&request, .not_found, "not found\n");
    }
}

fn serveWebSocket(ws: *http.Server.WebSocket, io: Io, ch: *Io.Queue(Command)) void {
    var buffer: [1024]u8 = undefined;
    while (true) {
        // const message = ws.readSmallMessage() catch |err| switch (err) {
        //     error.ConnectionClose, error.EndOfStream => return,
        //     else => {
        //         std.debug.print("websocket read failed: {s}\n", .{@errorName(err)});
        //         return;
        //     },
        // };

        // switch (message.opcode) {
        //     .text, .binary => ws.writeMessage(message.data, message.opcode) catch |err| {
        //         std.debug.print("websocket echo failed: {s}\n", .{@errorName(err)});
        //         return;
        //     },
        //     .ping => ws.writeMessage(message.data, .pong) catch |err| {
        //         std.debug.print("websocket pong failed: {s}\n", .{@errorName(err)});
        //         return;
        //     },
        //     else => {},
        // }
        const msg = ch.getOne(io) catch {
            break;
        };

        const data = msg.writeBuffer(buffer[0..]);
        if (data.len == 0) {
            continue;
        }
        ws.writeMessage(data, .binary) catch {
            ch.close(io);
            break;
        };
    }
}

fn respondText(request: *http.Server.Request, status: http.Status, body: []const u8) void {
    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
        },
    }) catch |err| {
        std.debug.print("failed to send response: {s}\n", .{@errorName(err)});
    };
}
