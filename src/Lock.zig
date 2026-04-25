const Lock = @This();

const std = @import("std");
const testing = std.testing;
const log = std.log;

const Io = std.Io;
const Writer = Io.Writer;
const Timestamp = Io.Timestamp;

pub const State = enum {
    unlocked,
    locked,
};

id: u32,
state: State,
expiration: Timestamp,

pub fn init(id: u32, expiration: Timestamp) Lock {
    return .{
        .id = id,
        .state = .unlocked,
        .expiration = expiration,
    };
}

test init {
    var lk = Lock.init(std.hash.Adler32.hash("test-lock"), Timestamp.now(testing.io, .real).addDuration(.fromMilliseconds(1000)));
    try testing.expectEqual(lk.id, std.hash.Adler32.hash("test-lock"));
    lk.lock(.zero);
    try testing.expectEqual(lk.state, .locked);
    lk.unlock();
    try testing.expectEqual(lk.state, .unlocked);
}

pub fn format(self: *const Lock, writer: *Writer) Writer.Error!void {
    try writer.print("lock: id={d} state={s} expiration={d}", .{ self.id, switch (self.state) {
        .unlocked => "unlocked",
        .locked => "locked",
    }, self.expiration.toSeconds() });
    try writer.flush();
}

pub fn lock(self: *Lock, expiration: Timestamp) void {
    self.state = .locked;
    self.expiration = expiration;
}

pub fn unlock(self: *Lock) void {
    self.state = .unlocked;
}
