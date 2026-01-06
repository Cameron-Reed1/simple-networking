const std = @import("std");
const net = @import("simple_networking");

const packet_id = net.packet_id;


pub const ValuePacket = struct {
    pub const name = "value";
    pub const id: packet_id = 2;

    value: i32,
};

pub const LinePacket = struct {
    pub const name = "line";
    pub const id: packet_id = 1;

    line: []const u8,
};

pub const ClosePacket = struct {
    pub const name = "close";
    pub const id: packet_id = std.math.maxInt(packet_id);
};
