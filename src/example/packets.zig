const std = @import("std");

const packet_id = @import("simple_serialization").packet_id;


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

pub const EverythingPacket = struct {
    pub const name = "everything";
    pub const id: packet_id = std.math.maxInt(packet_id) - 1;

    i: i8,
    u: u9,
    f: f32,
    d: f64,
    b: bool,
    n: void,
    a: [5]u8,
    s: struct {
        oi: ?i20,
        st: []const u8,
    },
    e: enum {
        value1,
        value2,
        value3,
    },
};

pub const EnumTest = struct {
    pub const name = "enum_test";
    pub const id: packet_id = 3;

    e: enum {
        value1,
        value2,
        value3,
    },
};
