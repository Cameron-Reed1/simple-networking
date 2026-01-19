const std = @import("std");
const packets = @import("packets.zig");


addr: std.net.Address,
    onConnect: *const fn(std.net.Stream, std.mem.Allocator) anyerror!void,
    shut_down: *const std.atomic.Value(bool),

    pub fn start(self: *const @This(), allocator: std.mem.Allocator) !void {
        var server = try self.addr.listen(.{ .force_nonblocking = true });
        defer server.deinit();


        while (!self.shut_down.load(.acquire)) {
            const conn = server.accept() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            defer conn.stream.close();


            self.onConnect(conn.stream, allocator) catch |err| {
                std.debug.print("Error with connection: {t}\n", .{err});
            };
        }
    }
