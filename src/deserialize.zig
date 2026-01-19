const std = @import("std");
const config = @import("config");
const packets = @import("packets.zig");
const type_tags = @import("type_tags.zig");

const packet_id = packets.packet_id;


const DeserializeError = error {
    UnexpectedValue,
    HeaderLengthIncorrect,
};


fn PacketData(PacketUnion: type) type {
    return struct {
        packet: PacketUnion,
        arena: std.heap.ArenaAllocator,
    };
}


pub fn readHeader(reader: *std.Io.Reader) !packets.PacketHeader {
    return packets.PacketHeader{
        .id = try reader.takeInt(packet_id, .big),
        .len = try reader.takeInt(@FieldType(packets.PacketHeader, "len"), .big),
    };
}

pub fn readPacketData(PacketUnion: type, allocator: std.mem.Allocator, reader: *std.Io.Reader, header: packets.PacketHeader) !PacketData(PacketUnion) {
    const Tag = std.meta.Tag(PacketUnion);
    return switch (@as(Tag, @enumFromInt(header.id))) {
        inline else => |t| blk: {
            const pkt_type = @FieldType(PacketUnion, @tagName(t));
            const pkt_buf = try reader.take(header.len);

            var arena: std.heap.ArenaAllocator = .init(allocator);
            const arena_allocator = arena.allocator();

            const packet = try deserialize(pkt_type, arena_allocator, pkt_buf);
            break :blk PacketData(PacketUnion){
                .packet = @unionInit(PacketUnion, @tagName(t), packet),
                .arena = arena,
            };
        },
    };
}

pub fn readPacket(PacketUnion: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !PacketData(PacketUnion) {
    const header = try readHeader(reader);
    std.debug.print("Header: {any}\n", .{ header });
    return try readPacketData(PacketUnion, allocator, reader, header);
}


pub fn deserialize(PacketType: type, allocator: std.mem.Allocator, buffer: []const u8) !PacketType {
    var value: PacketType = undefined;

    const packet_type_info = @typeInfo(PacketType);
    if (packet_type_info != .@"struct") {
        @compileError("Expected packet to be a struct, got " ++ @typeName(PacketType));
    }

    const used_len = try deserialize_struct(PacketType, allocator, buffer, &value, config.include_type_tags);
    if (used_len != buffer.len) {
        return DeserializeError.HeaderLengthIncorrect;
    }

    return value;
}

fn deserialize_struct(PacketType: type, allocator: std.mem.Allocator, buffer: []const u8, value: *PacketType, include_tag: bool) !usize {
    var index: usize = 0;

    if (include_tag) {
        if (buffer[index] != type_tags.struct_start) return DeserializeError.UnexpectedValue;
        index += 1;
    }

    inline for (@typeInfo(PacketType).@"struct".fields) |field| {
        index += try deserialize_field(field.type, allocator, buffer[index..], &@field(value, field.name), include_tag);
    }

    if (include_tag) {
        if (buffer[index] != type_tags.struct_end) return DeserializeError.UnexpectedValue;
        index += 1;
    }

    return index;
}

fn deserialize_field(T: type, allocator: std.mem.Allocator, buffer: []const u8, value: *T, include_tag: bool) !usize {
    const value_type_info = @typeInfo(T);

    var index: usize = 0;

    const tag = comptime type_tags.get(T) orelse @compileError("Cannot deserialize unserializable type: " ++ @typeName(T));
    if (include_tag and tag != type_tags.struct_start and tag != type_tags.optional_null) {
        if (buffer[index] != tag) return DeserializeError.UnexpectedValue;
        index += 1;
    }

    switch (value_type_info) {
        .void, .null => {},
        .bool => {
            value.* = buffer[index] != 0;
            index += 1;
        },
        .int => |int_info| {
            const width = switch (int_info.bits) {
                1...8 => 1,
                9...16 => 2,
                17...32 => 4,
                33...64 => 8,
                else => unreachable,
            };
            const ExpandedInt = @Type(.{ .int = .{ .bits = width * 8, .signedness = int_info.signedness } });
            const int_val = std.mem.readInt(ExpandedInt, buffer[index..][0..width], .big);
            value.* = @intCast(int_val);
            index += width;
        },
        .float => |float_info| {
            const width = float_info.bits / 8;
            @memcpy(std.mem.asBytes(value), buffer[index..index + width]);
            index += width;
        },
        .pointer => |ptr_info| index += try deserialize_slice(ptr_info.child, allocator, buffer[index..], value, include_tag),
        .array => |arr_info| index += try deserialize_array(arr_info.child, arr_info.len, allocator, buffer[index..], value, include_tag),
        .@"struct" => index += try deserialize_struct(T, allocator, buffer[index..], value, include_tag),
        .optional => |opt_info| {
            if ((include_tag and buffer[index] == type_tags.optional_value) or (!include_tag and buffer[index] == 1)) {
                index += 1;
                index += try deserialize_field(opt_info.child, allocator, buffer[index..], @ptrCast(value), include_tag);
            } else if ((include_tag and buffer[index] == type_tags.optional_null) or (!include_tag and buffer[index] == 0)) {
                index += 1;
                value.* = null;
            } else {
                return DeserializeError.UnexpectedValue;
            }
        },
        else => @compileError("Cannot deserialize unserializable type: " ++ @typeName(T)),
    }

    return index;
}

fn deserialize_slice(T: type, allocator: std.mem.Allocator, buffer: []const u8, value: *[]const T, include_tag: bool) !usize {
    var index: usize = 0;

    if (include_tag) {
        if (buffer[index] != comptime type_tags.get(T) orelse @compileError("Cannot deserialize unserializable type: " ++ @typeName(T)))
            return DeserializeError.UnexpectedValue;
        index += 1;
    }

    const len = std.mem.readInt(u16, buffer[index..][0..2], .big);
    index += 2;

    const values: []T = try allocator.alloc(T, len);
    for (0..len) |i| {
        index += try deserialize_field(T, allocator, buffer[index..], &values[i], false);
    }

    value.* = values;

    return index;
}

fn deserialize_array(T: type, len: comptime_int, allocator: std.mem.Allocator, buffer: []const u8, value: *[len]T, include_tag: bool) !usize {
    var index: usize = 0;

    if (include_tag) {
        if (buffer[index] != comptime type_tags.get(T) orelse @compileError("Cannot deserialize unserializable type: " ++ @typeName(T)))
            return DeserializeError.UnexpectedValue;
        index += 1;
    }

    if (std.mem.readInt(u16, buffer[index..][0..2], .big) != len) {
        return DeserializeError.UnexpectedValue;
    }
    index += 2;

    for (0..len) |i| {
        index += try deserialize_field(T, allocator, buffer[index..], &value[i], false);
    }

    return index;
}
