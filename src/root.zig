pub const Server = @import("Server.zig").Server;
pub const Connection = @import("Connection.zig").Connection;
pub const packets = @import("packets.zig");
pub const packet_id = packets.packet_id;

const std = @import("std");


pub fn connect(Packet: type, allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection(Packet) {
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();


    const read_buf = try allocator.alloc(u8, 1024);
    errdefer allocator.free(read_buf);

    const write_buf = try allocator.alloc(u8, 1024);
    errdefer allocator.free(write_buf);


    return .{
        .stream_reader = stream.reader(read_buf),
        .stream_writer = stream.writer(write_buf),
    };
}
