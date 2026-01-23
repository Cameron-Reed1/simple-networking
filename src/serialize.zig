const std = @import("std");
const config = @import("config");
const packets = @import("packets.zig");
const type_tags = @import("type_tags.zig");

const packet_id = packets.packet_id;


pub fn write(PacketUnion: type, allocator: std.mem.Allocator, packet: PacketUnion, writer: *std.Io.Writer, include_header: bool) !void {
    const serialized = switch (packet) {
        inline else => |p| try serialize(allocator, p),
    };
    defer allocator.free(serialized);


    if (include_header) {
        const HeaderLenType = @FieldType(packets.PacketHeader, "len");
        const header = packets.PacketHeader{
            .id = @intFromEnum(packet),
            .len = @intCast(serialized.len),
        };
        var header_bytes: [@sizeOf(packet_id) + @sizeOf(HeaderLenType)]u8 = undefined;
        std.mem.writeInt(packet_id, header_bytes[0..@sizeOf(packet_id)], header.id, .big);
        std.mem.writeInt(HeaderLenType, header_bytes[@sizeOf(packet_id)..], header.len, .big);

        try writer.writeAll(&header_bytes);
    }

    try writer.writeAll(serialized);
    try writer.flush();
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
        .array => |arr_info| try serialize_slice(arr_info.child, allocator, buffer, &value, include_tag),
        .@"struct" => try serialize_struct(allocator, buffer, value, include_tag),
        .optional => {
            if (value) |v| {
                try buffer.append(allocator, if (include_tag) type_tags.optional_value else 1);
                try serialize_field(allocator, buffer, v, include_tag);
            } else {
                try buffer.append(allocator, if (include_tag) type_tags.optional_null else 0);
            }
        },
        .@"enum" => try serialize_field(allocator, buffer, @intFromEnum(value), include_tag),
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
