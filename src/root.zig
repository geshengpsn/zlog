const std = @import("std");
const objects = @import("object.zig");
const commands = @import("commands.zig");
const Command = commands.Command;
const Io = std.Io;
const net = Io.net;
const http = std.http;
const stl_file_max_bytes = 128 * 1024 * 1024;

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
    active_connections: std.atomic.Value(usize),
    no_active_connections_event: Io.Event,

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
            .active_connections = .init(0),
            .no_active_connections_event = .is_set,
        };
        monitor.queue = Io.Queue(Command).init(monitor.queue_buffer[0..]);

        const listen_port = port orelse 5678;
        monitor.listen_port = listen_port;
        const address = net.IpAddress{ .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = listen_port,
        } };

        monitor.server_thread = try std.Thread.spawn(.{}, startServer, .{ io, address, &monitor.start_server_event, &monitor.connected_ws_event, &monitor.stop_event, &monitor.connected_address, &monitor.address_mutex, &monitor.queue, &monitor.active_connections, &monitor.no_active_connections_event });

        try monitor.start_server_event.wait(io);

        var url_buffer: [126]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/?port={d}", .{ listen_port, listen_port });
        _ = try std.process.spawn(io, .{
            .argv = &.{ "open", url },
        });

        try monitor.connected_ws_event.wait(io);
        // std.log.info("connected ws: {f}", .{monitor.connected_address orelse unreachable});

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

        if (monitor.active_connections.load(.monotonic) != 0) {
            monitor.no_active_connections_event.waitUncancelable(io);
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

fn startServer(io: Io, address: net.IpAddress, start_server_event: *Io.Event, connected_ws_event: *Io.Event, stop_event: *Io.Event, connected_address: *?net.IpAddress, address_mutex: *Io.Mutex, ch: *Io.Queue(Command), active_connections: *std.atomic.Value(usize), no_active_connections_event: *Io.Event) !void {
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);
    start_server_event.set(io);
    while (true) {
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

        connectionOpened(active_connections, no_active_connections_event);
        var connection_thread = std.Thread.spawn(.{}, handleConnection, .{ io, stream, address_mutex, connected_address, connected_ws_event, ch, active_connections, no_active_connections_event }) catch |err| {
            connectionClosed(io, active_connections, no_active_connections_event);
            std.debug.print("connection thread spawn failed: {s}\n", .{@errorName(err)});
            stream.close(io);
            continue;
        };
        connection_thread.detach();
    }
}

fn handleConnection(io: Io, stream: net.Stream, address_mutex: *Io.Mutex, connected_address: *?net.IpAddress, connected_ws_event: *Io.Event, ch: *Io.Queue(Command), active_connections: *std.atomic.Value(usize), no_active_connections_event: *Io.Event) void {
    defer {
        var stream_copy = stream;
        stream_copy.close(io);
        connectionClosed(io, active_connections, no_active_connections_event);
    }
    const address = stream.socket.address;

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => {
                std.log.info("http connection closing: {s}\n", .{@errorName(err)});
                return;
            },
            else => {
                std.log.info("request read failed: {s}\n", .{@errorName(err)});
                return;
            },
        };

        if (std.mem.eql(u8, request.head.target, "/ws")) {
            if (connected_ws_event.isSet()) {
                respondText(&request, .bad_request, "websocket already connected\n");
                return;
            }

            switch (request.upgradeRequested()) {
                .websocket => |opt_key| {
                    const key = opt_key orelse {
                        respondText(&request, .bad_request, "missing Sec-WebSocket-Key\n");
                        return;
                    };

                    var ws = request.respondWebSocket(.{ .key = key }) catch |err| {
                        std.debug.print("websocket upgrade failed: {s}\n", .{@errorName(err)});
                        return;
                    };

                    address_mutex.lockUncancelable(io);
                    connected_address.* = address;
                    address_mutex.unlock(io);
                    connected_ws_event.set(io);

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
        // std.log.debug("{s}", .{request.head.target});
        // const a = std.mem.startsWith(u8, request.head.target, "/?port=");
        var iter = std.mem.splitSequence(u8, request.head.target, "?");
        const header = iter.first();

        if (std.mem.eql(u8, header, "/")) {
            request.respond(@embedFile("index.html"), .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            }) catch |err| {
                std.debug.print("failed to send index page: {s}\n", .{@errorName(err)});
                return;
            };
            return;
        }

        if (std.ascii.endsWithIgnoreCase(header, ".stl")) {
            respondStlFile(&request, io, header);
            return;
        }

        respondText(&request, .not_found, "not found\n");
    }
}

fn serveWebSocket(ws: *http.Server.WebSocket, io: Io, ch: *Io.Queue(Command)) void {
    var buffer: [1024]u8 = undefined;
    while (true) {
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

fn connectionOpened(active_connections: *std.atomic.Value(usize), no_active_connections_event: *Io.Event) void {
    const previous = active_connections.fetchAdd(1, .monotonic);
    if (previous == 0) {
        no_active_connections_event.reset();
    }
}

fn connectionClosed(io: Io, active_connections: *std.atomic.Value(usize), no_active_connections_event: *Io.Event) void {
    const previous = active_connections.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);
    if (previous == 1) {
        no_active_connections_event.set(io);
    }
}

fn respondStlFile(request: *http.Server.Request, io: Io, target: []const u8) void {
    const relative_file_path = sanitizeStlTarget(target) orelse {
        respondText(request, .bad_request, "invalid stl path\n");
        return;
    };

    const file_contents = Io.Dir.cwd().readFileAlloc(io, relative_file_path, std.heap.page_allocator, .limited(stl_file_max_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            respondText(request, .not_found, "stl not found\n");
            return;
        },
        error.StreamTooLong => {
            respondText(request, .payload_too_large, "stl file too large\n");
            return;
        },
        else => {
            std.debug.print("failed to read stl file '{s}': {s}\n", .{ relative_file_path, @errorName(err) });
            respondText(request, .internal_server_error, "failed to read stl file\n");
            return;
        },
    };
    defer std.heap.page_allocator.free(file_contents);

    request.respond(file_contents, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "model/stl" },
        },
    }) catch |err| {
        std.debug.print("failed to send stl file '{s}': {s}\n", .{ relative_file_path, @errorName(err) });
    };
}

fn sanitizeStlTarget(target: []const u8) ?[]const u8 {
    if (!std.ascii.endsWithIgnoreCase(target, ".stl")) {
        return null;
    }
    if (std.mem.indexOfScalar(u8, target, '\\') != null) {
        return null;
    }

    const raw_path = std.mem.trimStart(u8, target, "/");
    if (raw_path.len == 0 or Io.Dir.path.isAbsolute(raw_path)) {
        return null;
    }

    var iter = Io.Dir.path.ComponentIterator(.posix, u8).init(raw_path);
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) {
            return null;
        }
    }

    return raw_path;
}

test "sanitize stl target accepts relative stl paths" {
    try std.testing.expectEqualStrings("a.stl", sanitizeStlTarget("/a.stl") orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("meshes/a.STL", sanitizeStlTarget("/meshes/a.STL") orelse return error.TestUnexpectedResult);
}

test "sanitize stl target rejects unsafe or non stl paths" {
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStlTarget("/a.obj"));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStlTarget("/../a.stl"));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStlTarget("/meshes/../a.stl"));
    try std.testing.expectEqual(@as(?[]const u8, null), sanitizeStlTarget("/meshes\\a.stl"));
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
