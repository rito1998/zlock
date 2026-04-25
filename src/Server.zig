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

pub fn start(self: *const Server, io: Io) Writer.Error!void {
    _ = io;
    log.info("Starting server at {f} --- NOT IMPLEMENTED", .{self.address}); // TODO
}
