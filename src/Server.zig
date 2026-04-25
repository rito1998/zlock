const Server = @This();

const std = @import("std");
const net = std.Io.net;
const log = std.log;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const IpAddress = net.IpAddress;

address: IpAddress = IpAddress.parseLiteral("[::1]:1998") catch unreachable,

pub fn echo() !void {}

pub fn format(self: *const Server, writer: *Writer) Writer.Error!void {
    try writer.print("zlock-server-{f}", .{self.address});
    try writer.flush();
}

pub fn start(self: *const Server, io: Io) !void {
    var connections_counter: std.atomic.Value(u32) = .init(0);

    var group = Io.Group.init;
    defer group.cancel(io);

    var server = try self.address.listen(io, .{});
    log.debug("Initialized server with address {f}.", .{self.address});
    defer server.deinit(io);

    while (true) {
        const connection = try server.accept(io);
        _ = connections_counter.fetchAdd(1, .acq_rel);
        log.debug("Connection accepted from {f} (connection_counter = {d})", .{ connection.socket.address, connections_counter.raw });

        group.async(io, handleConnection, .{ io, connection, &connections_counter });
    }
}

/// Starts an echo server that listens for incoming connections and echoes back any messages received.
/// Only handles one connection at a time.
pub fn startEchoExample(self: *const Server, io: Io) !void {
    var server = try self.address.listen(io, .{});
    log.debug("Initialized server with address {f}.", .{self.address});
    defer server.deinit(io);

    while (true) {
        var conn = try server.accept(io);
        log.debug("Connection accepted from {f}", .{conn.socket.address});

        var r_buff = [_]u8{0} ** 1024;
        var w_buff = [_]u8{0} ** 1024;

        var reader = conn.reader(io, &r_buff);
        var writer = conn.writer(io, &w_buff);

        const msg = reader.interface.takeDelimiterExclusive('\n') catch |err| {
            switch (err) {
                error.EndOfStream => log.err("EndOfStream: {f}", .{conn.socket.address}),
                error.StreamTooLong => log.err("StreamTooLong: {f}", .{conn.socket.address}),
                error.ReadFailed => log.err("ReadFailed: {f}", .{conn.socket.address}),
            }
            continue;
        };

        try writer.interface.writeAll(msg);
        _ = try writer.interface.write("\n");
        _ = try writer.interface.flush();
        log.debug("Received message: {s}", .{msg});

        conn.close(io);
        log.debug("Closed the connection to {f}...", .{conn.socket.address});
    }
}

pub fn handleConnection(io: Io, connection: Io.net.Stream, connections_counter: *std.atomic.Value(u32)) Io.Cancelable!void {
    var r_buff = [_]u8{0} ** 1024;
    var reader = connection.reader(io, &r_buff);

    const msg = reader.interface.takeDelimiterExclusive('\n') catch |err| {
        return switch (err) {
            error.EndOfStream => log.err("EndOfStream: {f}", .{connection.socket.address}),
            error.StreamTooLong => log.err("StreamTooLong: {f}", .{connection.socket.address}),
            error.ReadFailed => log.err("ReadFailed: {f}", .{connection.socket.address}),
        };
    };
    log.debug("Handling request: {s}", .{msg});

    connection.close(io);
    _ = connections_counter.fetchSub(1, .acq_rel);
    log.debug("Closed the connection to {f} (connection_counter = {d})", .{ connection.socket.address, connections_counter.raw });
}
