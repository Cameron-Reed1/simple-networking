const std = @import("std");
const packets = @import("packets.zig");

const packet_id = packets.packet_id;


pub fn Connection(PacketUnion: type) type {
    const Packet = PacketUnion;
    const Tag = std.meta.Tag(Packet);

    const PacketData = struct {
        packet: Packet,
        arena: std.heap.ArenaAllocator,
    };

    return struct {
        stream: ?std.net.Stream = null,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,

        pub fn poll(self: *const @This(), timeout: i32) !bool {
            if (self.stream == null) return true;

            var pollfd = [1]std.posix.pollfd{
                .{
                    .fd = self.stream.?.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            return try std.posix.poll(&pollfd, timeout) != 0;
        }

        pub fn readHeader(self: *@This()) !packets.PacketHeader {
            return packets.PacketHeader{
                .id = try self.reader.takeInt(packet_id, .big),
                .len = try self.reader.takeInt(@FieldType(packets.PacketHeader, "len"), .big),
            };
        }

        pub fn readPacketData(self: *@This(), allocator: std.mem.Allocator, header: packets.PacketHeader) !PacketData {
            return switch (@as(Tag, @enumFromInt(header.id))) {
                inline else => |t| blk: {
                    const pkt_type = @FieldType(Packet, @tagName(t));
                    const pkt_buf = try self.reader.take(header.len);

                    var arena: std.heap.ArenaAllocator = .init(allocator);
                    const arena_allocator = arena.allocator();

                    const packet = try packets.deserialize(pkt_type, arena_allocator, pkt_buf);
                    break :blk PacketData{
                        .packet = @unionInit(Packet, @tagName(t), packet),
                        .arena = arena,
                    };
                },
            };
        }

        pub fn readPacket(self: *@This(), allocator: std.mem.Allocator) !PacketData {
            const header = try self.readHeader();
            return try self.readPacketData(allocator, header);
        }

        pub fn sendPacket(self: *@This(), allocator: std.mem.Allocator, packet: Packet) !void {
            const serialized = switch (packet) {
                inline else => |p| try packets.serialize(allocator, p),
            };
            defer allocator.free(serialized);


            const HeaderLenType = @FieldType(packets.PacketHeader, "len");
            const header = packets.PacketHeader{
                .id = @intFromEnum(packet),
                .len = @intCast(serialized.len),
            };
            var header_bytes: [@sizeOf(packet_id) + @sizeOf(HeaderLenType)]u8 = undefined;
            std.mem.writeInt(packet_id, header_bytes[0..@sizeOf(packet_id)], header.id, .big);
            std.mem.writeInt(HeaderLenType, header_bytes[@sizeOf(packet_id)..], header.len, .big);


            try self.writer.writeAll(&header_bytes);
            try self.writer.writeAll(serialized);
            try self.writer.flush();
        }
    };
}
