const std = @import("std");
const packets = @import("packets.zig");
const Connection = @import("Connection.zig").Connection;


pub fn Server(PacketUnion: type) type {
    const Packet = PacketUnion;

    return struct {
        addr: std.net.Address,
        onConnect: *const fn(Connection(Packet), std.mem.Allocator) anyerror!void,
        shut_down: *const std.atomic.Value(bool),

        pub fn start(self: *const @This(), allocator: std.mem.Allocator) !void {
            var server = try self.addr.listen(.{});
            defer server.deinit();


            var pollfd = [1]std.posix.pollfd{
                .{
                    .fd = server.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            while (!self.shut_down.load(.acquire)) {
                if (try std.posix.poll(&pollfd, 100) == 0) continue;

                const conn = try server.accept();
                errdefer conn.stream.close();

                const c: Connection(Packet) = try .fromStream(allocator, conn.stream);
                self.onConnect(c, allocator) catch |err| {
                    std.debug.print("Error with connection: {t}\n", .{err});
                };
            }
        }
    };
}
