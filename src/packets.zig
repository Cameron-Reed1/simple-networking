const config = @import("config");
const std = @import("std");
const type_tags = @import("type_tags.zig");


pub const packet_id = @Type(.{ .int = .{ .bits = config.packet_id_bits, .signedness = .unsigned } });


const DeserializeError = error {
    UnexpectedValue,
    HeaderLengthIncorrect,
};


pub const PacketHeader = struct {
    id: packet_id,
    len: u16,
};


pub fn genPacketsUnion(packets: anytype) type {
    const packets_type_info = @typeInfo(@TypeOf(packets));
    if (packets_type_info != .@"struct") {
        @compileError("genPacketsUnion takes a tuple or struct of packets, got " ++ @typeName(@TypeOf(packets)));
    }

    const fields_info = packets_type_info.@"struct".fields;
    comptime var enum_fields: [fields_info.len]std.builtin.Type.EnumField= undefined;
    comptime var union_fields: [fields_info.len]std.builtin.Type.UnionField = undefined;

    inline for (fields_info, 0..) |field, i| {
        if (field.type != type) {
            @compileError("genPacketsUnion expected packet type, got " ++ @typeName(field.type));
        }
        const packet_type: type = @field(packets, field.name);
        const pkt_type_info = @typeInfo(packet_type);

        if (pkt_type_info != .@"struct") {
            @compileError("All packet types must be structs; got " ++ @typeName(packet_type));
        }

        const pkt_name = packet_type.name;
        const pkt_id = packet_type.id;

        enum_fields[i] = std.builtin.Type.EnumField{
            .name = pkt_name,
            .value = pkt_id,
        };

        union_fields[i] = std.builtin.Type.UnionField{
            .type = packet_type,
            .name = pkt_name,
            .alignment = @alignOf(packet_type),
        };
    }

    const tag_type = @Type(.{ .@"enum" = .{ .tag_type = packet_id, .fields = &enum_fields, .decls = &.{}, .is_exhaustive = true } });

    return @Type(std.builtin.Type{ .@"union" = .{ .tag_type = tag_type, .fields = &union_fields, .decls = &.{}, .layout = .auto } });
}


pub fn serialize(allocator: std.mem.Allocator, packet: anytype) ![]const u8 {
    const PacketType = @TypeOf(packet);
    const packet_type_info = @typeInfo(PacketType);
    if (packet_type_info != .@"struct") {
        @compileError("Expected packet to be a struct, got " ++ @typeName(PacketType));
    }

    var buffer: std.ArrayListUnmanaged(u8) = .empty;

    try serialize_struct(allocator, &buffer, packet, config.include_type_tags);

    return try buffer.toOwnedSlice(allocator);
}

fn serialize_struct(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), value: anytype, include_tag: bool) !void {
    if (include_tag) {
        try buffer.append(allocator, type_tags.struct_start);
    }

    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |field| {
        try serialize_field(allocator, buffer, @field(value, field.name), include_tag);
    }

    if (include_tag) {
        try buffer.append(allocator, type_tags.struct_end);
    }
}

fn serialize_field(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), value: anytype, include_tag: bool) !void {
    const ValueType = @TypeOf(value);
    const value_type_info = @typeInfo(ValueType);

    const tag = comptime type_tags.get(ValueType) orelse @compileError("Cannot serialize type: " ++ @typeName(ValueType));
    if (include_tag and tag != type_tags.struct_start and tag != type_tags.optional_null) {
        try buffer.append(allocator, tag);
    }

    switch (value_type_info) {
        .void, .null => {},
        .bool => try buffer.append(allocator, if (value) 1 else 0),
        .int => |int_info| {
            const width = switch (int_info.bits) {
                1...8 => 1,
                9...16 => 2,
                17...32 => 4,
                33...64 => 8,
                else => unreachable,
            };
            const ExpandedInt = @Type(.{ .int = .{ .bits = width * 8, .signedness = int_info.signedness } });
            const bytes = try buffer.addManyAsArray(allocator, width);
            std.mem.writeInt(ExpandedInt, bytes, @as(ExpandedInt, value), .big);
        },
        .float => |float_info| {
            const width = float_info.bits / 8;
            const bytes = try buffer.addManyAsArray(allocator, width);
            @memcpy(bytes, std.mem.asBytes(&value));
        },
        .pointer => |ptr_info| try serialize_slice(ptr_info.child, allocator, buffer, value, include_tag),
        .array => |arr_info| try serialize_slice(arr_info.child, allocator, buffer, value, include_tag),
        .@"struct" => try serialize_struct(allocator, buffer, value, include_tag),
        .optional => {
            if (value) |v| {
                try buffer.append(allocator, if (include_tag) type_tags.optional_value else 1);
                try serialize_field(allocator, buffer, v, include_tag);
            } else {
                try buffer.append(allocator, if (include_tag) type_tags.optional_null else 0);
            }
        },
        else => @compileError("Cannot serialize type: " ++ @typeName(ValueType)),
    }
}

fn serialize_slice(T: type, allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), value: []const T, include_tag: bool) !void {
    if (include_tag) {
        try buffer.append(allocator, comptime type_tags.get(T) orelse @compileError("Cannot serialize type: " ++ @typeName(T)));
    }

    const bytes = try buffer.addManyAsArray(allocator, 2);
    std.mem.writeInt(u16, bytes, @intCast(value.len), .big);
    for (value) |v| {
        try serialize_field(allocator, buffer, v, false);
    }
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
        .array => |arr_info| index += try deserialize_slice(arr_info.child, arr_info.len, allocator, buffer[index..], value, include_tag),
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

    if (std.mem.readInt(u16, buffer[index..index + 2], .big) != len) {
        return DeserializeError.UnexpectedValue;
    }
    index += 2;

    for (0..len) |i| {
        index += try deserialize_field(T, allocator, buffer[index..], &value[i], false);
    }

    return index;
}
