const ser = @import("simple_serialization");
const std = @import("std");

const type_tags = ser.type_tags;

const packet_id = ser.packet_id;


const ParseError = error {
    InvalidTypeTag,
};


pub fn printSerializedPacket(data: []const u8) ParseError!void {
    var i: usize = 0;
    while (i < data.len) {
        i += try print_value(data[i], data[i+1..], 0) + 1;
    }
}


pub fn printSerializedPacketWithHeader(header: ser.packets.PacketHeader, data: []const u8) ParseError!void {
    std.debug.print("SerializedPacket(id: {}, len: {})\n", .{header.id, header.len});
    var i: usize = 0;
    while (i < data.len) {
        i += try print_value(data[i], data[i+1..], 0) + 1;
    }
}


fn print_value(tag: u8, data: []const u8, indent: u8) ParseError!usize {
    return switch (tag) {
        type_tags.@"null",
        type_tags.optional_null => print_null(indent),
        type_tags.boolean => print_boolean(data, indent),
        type_tags.int.unsigned.@"8" => print_int(u8, data, indent),
        type_tags.int.unsigned.@"16" => print_int(u16, data, indent),
        type_tags.int.unsigned.@"32" => print_int(u32, data, indent),
        type_tags.int.unsigned.@"64" => print_int(u64, data, indent),
        type_tags.int.signed.@"8" => print_int(i8, data, indent),
        type_tags.int.signed.@"16" => print_int(i16, data, indent),
        type_tags.int.signed.@"32" => print_int(i32, data, indent),
        type_tags.int.signed.@"64" => print_int(i64, data, indent),
        type_tags.float.@"32" => print_float(f32, data, indent),
        type_tags.float.@"64" => print_float(f64, data, indent),
        type_tags.array => try print_array(data, indent),
        type_tags.struct_start => try print_struct(data, indent),
        type_tags.optional_value => try print_value(data[0], data[1..], indent),
        type_tags.@"enum" => blk: {
            print_indent(indent);
            std.debug.print("[Enum] ", .{});
            break :blk try print_value(data[0], data[1..], 0) + 1;
        },
        else => {
            std.debug.print("t: {}\n", .{ tag });
            return ParseError.InvalidTypeTag;
        },
    };
}


fn print_indent(indent: u8) void {
    for (0..indent) |_| {
        std.debug.print("    ", .{});
    }
}

fn print_null(indent: u8) usize {
    print_indent(indent);
    std.debug.print("null\n", .{});

    return 0;
}

fn print_boolean(data: []const u8, indent: u8) usize {
    print_indent(indent);
    std.debug.print("bool: {s}\n", .{ if (data[0] == 0) "false" else "true" });

    return 1;
}

fn print_int(T: type, data: []const u8, indent: u8) usize {
    const value = std.mem.readInt(T, data[0..@sizeOf(T)], .big);

    print_indent(indent);
    std.debug.print("{s}: {}\n", .{ @typeName(T), value });

    return @sizeOf(T);
}

fn print_float(T: type, data: []const u8, indent: u8) usize {
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), data[0..@sizeOf(T)]);

    print_indent(indent);
    std.debug.print("{s}: {}\n", .{ @typeName(T), value });

    return @sizeOf(T);
}

fn print_array(data: []const u8, indent: u8) ParseError!usize {
    const child_tag = data[0];
    const len = std.mem.readInt(u16, data[1..][0..@sizeOf(u16)], .big);

    print_indent(indent);
    std.debug.print("[{}]{s}: {{\n", .{ len, try type_name(child_tag) });

    var i: usize = 3;
    for (0..len) |_| {
        i += try print_value(child_tag, data[i..], indent + 1);
    }

    print_indent(indent);
    std.debug.print("}}\n", .{});

    return i;
}

fn print_struct(data: []const u8, indent: u8) ParseError!usize {
    print_indent(indent);
    std.debug.print("{{\n", .{});

    var i: usize = 0;
    while (data[i] != ser.type_tags.struct_end) {
        i += try print_value(data[i], data[i+1..], indent + 1) + 1;
    }

    print_indent(indent);
    std.debug.print("}}\n", .{});

    return i + 1;
}

fn type_name(tag: u8) ParseError![]const u8 {
    return switch (tag) {
        ser.type_tags.@"null",
        ser.type_tags.optional_null => "null",
        ser.type_tags.boolean => "bool",
        ser.type_tags.int.unsigned.@"8" => "u8",
        ser.type_tags.int.unsigned.@"16" => "u16",
        ser.type_tags.int.unsigned.@"32" => "u32",
        ser.type_tags.int.unsigned.@"64" => "u64",
        ser.type_tags.int.signed.@"8" => "i8",
        ser.type_tags.int.signed.@"16" => "i16",
        ser.type_tags.int.signed.@"32" => "i32",
        ser.type_tags.int.signed.@"64" => "i64",
        ser.type_tags.float.@"32" => "f32",
        ser.type_tags.float.@"64" => "f64",
        ser.type_tags.array => "array",
        ser.type_tags.struct_start => "struct",
        ser.type_tags.optional_value => "optional",
        else => return ParseError.InvalidTypeTag,
    };
}
