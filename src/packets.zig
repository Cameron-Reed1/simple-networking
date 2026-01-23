const std = @import("std");
const config = @import("config");


pub const include_type_tags = config.include_type_tags;
pub const packet_id = @Type(.{ .int = .{ .bits = config.packet_id_bits, .signedness = .unsigned } });
pub const packet_len = @Type(.{ .int = .{ .bits = config.length_bits, .signedness = .unsigned } });


pub const PacketHeader = struct {
    id: packet_id,
    len: packet_len,
};


pub fn PacketUnion(packets: anytype) type {
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
