const Client = @This();

const std = @import("std");
const log = std.log;

pub fn hello() !void {
    log.info("Hello from the client!", .{});
}
