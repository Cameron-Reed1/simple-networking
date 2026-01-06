pub const Server = @import("Server.zig").Server;
pub const Connection = @import("Connection.zig").Connection;
pub const packets = @import("packets.zig");
pub const packet_id = packets.packet_id;

const std = @import("std");


pub fn connect(Packet: type, allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection(Packet) {
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    errdefer stream.close();

    return try .fromStream(allocator, stream);
}
