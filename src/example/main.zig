const std = @import("std");
const simple_networking = @import("simple_networking");
const packets = @import("packets.zig");
const tools = @import("tools");


const Packet = simple_networking.packets.genPacketsUnion(.{
    packets.ValuePacket,
    packets.LinePacket,
    packets.ClosePacket,
});


var shut_down: std.atomic.Value(bool) = .init(false);


fn exit_signal(_: i32) callconv(.c) void {
    shut_down.store(true, .release);
}


pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("Memory was leaked D:\n", .{});
        }
    }


    if (std.os.argv.len != 2) {
        std.debug.print("Usage: {s} [--server/--client]\n", .{ std.os.argv[0] });
        std.posix.exit(1);
    }


    const exit_handler = std.posix.Sigaction{
        .handler = .{ .handler = exit_signal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESETHAND,
    };
    std.posix.sigaction(std.posix.SIG.INT, &exit_handler, null);


    const arg = std.mem.span(std.os.argv[1]);
    if (std.mem.eql(u8, arg, "--server")) {
        try run_server(allocator);
    } else if (std.mem.eql(u8, arg, "--client")) {
        try run_client(allocator);
    } else if (std.mem.eql(u8, arg, "--visualizer")) {
        try run_visualize_server(allocator);
    } else if (std.mem.eql(u8, arg, "--visualize")) {
        if (simple_networking.packets.include_type_tags) {
            const s1 = try simple_networking.packets.serialize(allocator, packets.LinePacket{ .line = "Hello, World!" });
            defer allocator.free(s1);
            try tools.printSerializedPacket(s1);

            const s2 = try simple_networking.packets.serialize(allocator, packets.ValuePacket{ .value = -9375 });
            defer allocator.free(s2);
            try tools.printSerializedPacket(s2);

            const s3 = try simple_networking.packets.serialize(allocator, struct{ i: u8, f: f32, b: bool, s: []const u8 }{ .i = 85, .f = -1.234, .b = false, .s = "tble" });
            defer allocator.free(s3);
            try tools.printSerializedPacket(s3);

            const tags = simple_networking.type_tags;
            try tools.printSerializedPacketWithHeader(.{ .id = 25, .len = 5 }, &.{ tags.struct_start, tags.int.signed.@"16", 65, 25, tags.struct_end });
        } else {
            std.debug.print("This requires -Dinclude_type_tags to be set\n", .{});
            std.posix.exit(2);
        }
    }
}


fn run_server(allocator: std.mem.Allocator) !void {
    var server: simple_networking.Server(Packet) = .{ .addr = .initIp4(.{127, 0, 0, 1}, 15000), .onConnect = handleConnection, .shut_down = &shut_down };
    try server.start(allocator);
    std.debug.print("Exiting\n", .{});
}

fn handleConnection(conn: simple_networking.Connection(Packet), allocator: std.mem.Allocator) !void {
    var connection = conn;
    defer connection.deinit(allocator);

    while (!shut_down.load(.acquire)) {
        if (!try connection.poll(100)) continue;

        const pkt = connection.readPacket(allocator) catch |err| {
            std.debug.print("Error reading packet: {any}\n", .{err});
            break;
        };
        defer pkt.arena.deinit();
        print(pkt.packet);
        if (pkt.packet == .close) break;
    }
}


fn run_visualize_server(allocator: std.mem.Allocator) !void {
    var server: simple_networking.Server(Packet) = .{ .addr = .initIp4(.{127, 0, 0, 1}, 15000), .onConnect = handleVisConnection, .shut_down = &shut_down };
    try server.start(allocator);
    std.debug.print("Exiting\n", .{});
}

fn handleVisConnection(conn: simple_networking.Connection(Packet), allocator: std.mem.Allocator) !void {
    var connection = conn;
    defer connection.deinit(allocator);

    while (!shut_down.load(.acquire)) {
        if (!try connection.poll(100)) continue;

        const header = try connection.readHeader();
        const pkt_buf = try connection.stream_reader.interface().take(header.len);

        std.debug.print("Raw: {any}\n", .{ pkt_buf });
        try tools.printSerializedPacketWithHeader(header, pkt_buf);
    }
}


fn run_client(allocator: std.mem.Allocator) !void {
    var connection = try simple_networking.connect(Packet, allocator, "127.0.0.1", 15000);
    defer {
        connection.sendPacket(allocator, .{ .close = .{} }) catch {};
        connection.deinit(allocator);
    }

    var stdin_buf: [1024]u8 = undefined;
    const stdin_file = std.fs.File.stdin();
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdin = &stdin_reader.interface;


    var pollfd = [1]std.posix.pollfd{
        .{
            .fd = stdin_file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    while (!shut_down.load(.acquire)) {
        if (try std.posix.poll(&pollfd, 100) == 0) continue;

        const line = try stdin.takeDelimiter('\n') orelse break;
        if (std.mem.eql(u8, line, "exit")) break;
        if (std.mem.startsWith(u8, line, "value ")) {
            const v = std.fmt.parseInt(i32, line[6..], 10) catch {
                try connection.sendPacket(allocator, .{ .line = .{ .line = line } });
                continue;
            };
            try connection.sendPacket(allocator, .{ .value = .{ .value = v } });
        } else {
            try connection.sendPacket(allocator, .{ .line = .{ .line = line } });
        }
    }
    std.debug.print("Closing\n", .{});
}

fn print(pkt: Packet) void {
    switch (pkt) {
        .line => |p| {
            std.debug.print("{s}\n", .{ p.line });
        },
        inline else => |p| {
            std.debug.print("{s}: {any}\n", .{ @typeName(@TypeOf(p)), p });
        },
    }
}
