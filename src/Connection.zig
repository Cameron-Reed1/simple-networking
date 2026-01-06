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
        stream_reader: std.net.Stream.Reader,
        stream_writer: std.net.Stream.Writer,

        pub fn fromStream(allocator: std.mem.Allocator, stream: std.net.Stream) !Connection(Packet) {
                const read_buf = try allocator.alloc(u8, 1024);
                errdefer allocator.free(read_buf);

                const write_buf = try allocator.alloc(u8, 1024);
                errdefer allocator.free(write_buf);


                return .{
                    .stream_reader = stream.reader(read_buf),
                    .stream_writer = stream.writer(write_buf),
                };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.stream_reader.getStream().close();
            allocator.free(self.stream_reader.interface().buffer);
            allocator.free(self.stream_writer.interface.buffer);
        }

        pub fn poll(self: *const @This(), timeout: i32) !bool {
            var pollfd = [1]std.posix.pollfd{
                .{
                    .fd = self.stream_reader.getStream().handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            return try std.posix.poll(&pollfd, timeout) != 0;
        }

        pub fn readHeader(self: *@This()) !packets.PacketHeader {
            const reader = self.stream_reader.interface();

            const HeaderLenType = @FieldType(packets.PacketHeader, "len");
            const id_bytes = try reader.takeArray(@sizeOf(packet_id));
            const len_bytes = try reader.takeArray(@sizeOf(HeaderLenType));

            return packets.PacketHeader{
                .id = std.mem.readInt(packet_id, id_bytes, .big),
                .len = std.mem.readInt(HeaderLenType, len_bytes, .big),
            };
        }

        pub fn readPacketData(self: *@This(), allocator: std.mem.Allocator, header: packets.PacketHeader) !PacketData {
            const reader = self.stream_reader.interface();

            return switch (@as(Tag, @enumFromInt(header.id))) {
                inline else => |t| blk: {
                    const pkt_type = @FieldType(Packet, @tagName(t));
                    const pkt_buf = try reader.take(header.len);

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


            var writer = &self.stream_writer.interface;
            try writer.writeAll(&header_bytes);
            try writer.writeAll(serialized);
            try writer.flush();
        }
    };
}
