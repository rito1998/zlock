const ZlockServer = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_zig_zon = @import("build_zig_zon");
const Lock = @import("Lock.zig");
const net = std.Io.net;
const log = std.log;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cancelable = Io.Cancelable;
const Writer = Io.Writer;
const SplitIterator = std.mem.SplitIterator(u8, .sequence);
const IpAddress = net.IpAddress;
const Stream = net.Stream;
const ArrayList = std.ArrayList;
const Mutex = std.Io.Mutex;
const Timestamp = Io.Timestamp;

address: IpAddress,
locks: *ArrayList(Lock),
mutex: *Mutex,

const Command = enum {
    create,
    lock,
    trylock,
    unlock,
    version,
    help,
};

pub fn format(self: *const ZlockServer, writer: *Writer) Writer.Error!void {
    try writer.print("zlock server at {f} ({d} locks)", .{ self.address, self.locks.items.len });
    try writer.flush();
}

pub fn logLocks(self: *const ZlockServer, io: Io) !void {
    const now = Timestamp.now(io, .real);
    log.info("-------------------- LOCKS --------------------", .{});
    if (self.locks.items.len > 0) {
        for (self.locks.items) |lock| {
            log.info("- {f} (expires in {d} seconds)", .{
                lock,
                lock.expiration.toSeconds() - now.toSeconds(),
            });
        }
    } else {
        log.info("no locks", .{});
    }
    log.info("-----------------------------------------------", .{});
}

// expiration is better checked lazily right when a lock is accessed with isLocked(now),
// but such dirty "polling" expiration handler can help with initial debugging
fn lockExpirationHandler(self: *const ZlockServer, io: Io) Cancelable!void {
    while (true) {
        try self.mutex.lock(io);
        if (self.locks.items.len > 0) {
            for (self.locks.items) |*lock| {
                if (lock.isExpired(.now(io, .real))) {
                    if (lock.state == .locked) {
                        log.warn("lock {d} expired, unlocking it", .{lock.id});
                        lock.unlock();
                    }
                }
            }
        }
        self.mutex.unlock(io);

        try io.sleep(.fromMilliseconds(100), .real); // prevent busy waiting
    }
}

pub fn start(self: *const ZlockServer, allocator: Allocator, io: Io) !void {
    var group = Io.Group.init;
    defer group.cancel(io);

    var server = try self.address.listen(io, .{});
    log.info("Initialized server with address {f}.", .{self.address});
    defer server.deinit(io);

    try group.concurrent(io, lockExpirationHandler, .{ self, io });

    while (true) {
        const connection = try server.accept(io);
        try group.concurrent(io, handleConnection, .{ self, allocator, io, connection });
    }
}

// raw text protocol sketch for testing (TODO: make a proper http server...)
// can be easily tested with netcat like so:
// >> "create ExampleLockName" | ncat localhost 1998
// >> "trylock ExampleLockName 10000" | ncat localhost 1998
pub fn handleConnection(self: *const ZlockServer, allocator: Allocator, io: Io, connection: Stream) Cancelable!void {
    defer connection.close(io);

    var r_buff = [_]u8{0} ** 1024;
    var reader = connection.reader(io, &r_buff);

    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    const msg = reader.interface.takeDelimiterExclusive('\n') catch |err| {
        return switch (err) {
            error.EndOfStream => log.err("EndOfStream: {f}", .{connection.socket.address}),
            error.StreamTooLong => log.err("StreamTooLong: {f}", .{connection.socket.address}),
            error.ReadFailed => log.err("ReadFailed: {f}", .{connection.socket.address}),
            //error.ConnectionResetByPeer => log.err("ConnectionResetByPeer: {f}", .{connection.socket.address}),
        };
    };
    const trimmed_msg = std.mem.trim(u8, msg, "\r\n");

    log.info("Received \"{s}\" from {f}", .{ trimmed_msg, connection.socket.address });

    var iterator = std.mem.splitSequence(u8, trimmed_msg, " ");
    if (iterator.next()) |param| {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const command = std.meta.stringToEnum(Command, param) orelse {
            log.err("unknown command \"{s}\" from {f}", .{ param, connection.socket.address });
            writer.interface.print("unknown command \"{s}\"\n", .{param}) catch return Cancelable.Canceled;
            writer.interface.flush() catch return Cancelable.Canceled;
            return Cancelable.Canceled;
        };

        switch (command) {
            .create => try self.commandCreate(allocator, io, &iterator, connection),
            .trylock => try self.commandTrylock(io, &iterator, connection),
            .lock => try self.commandLock(io, &iterator, connection),
            .unlock => try self.commandUnlock(io, &iterator, connection),
            .version => try commandVersion(io, connection),
            .help => try commandHelp(io, connection),
        }
    }

    log.info("Closed the connection to {f}. Current server state: {f}", .{ connection.socket.address, self });
    try self.logLocks(io);
}

fn commandCreate(self: *const ZlockServer, allocator: Allocator, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    var lock_name: []const u8 = undefined;
    if (args.next()) |arg| {
        lock_name = arg;
    } else {
        log.info("missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    var found = false;
    if (self.locks.items.len > 0) {
        for (self.locks.items) |lock| {
            if (lock.id == std.hash.Adler32.hash(lock_name)) {
                log.info("lock {s} already exists, denying create from {f}", .{ lock_name, connection.socket.address });
                writer.interface.print("already exists\n", .{}) catch return Cancelable.Canceled;
                writer.interface.flush() catch return Cancelable.Canceled;
                found = true;
                break;
            }
        }
    }
    if (!found) {
        const new_lock: Lock = .init(std.hash.Adler32.hash(lock_name), .zero);
        self.locks.append(allocator, new_lock) catch return Cancelable.Canceled;
        writer.interface.print("created\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn commandTrylock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    // expect lock name argument
    var lock_name: []const u8 = undefined;
    if (args.next()) |arg| {
        lock_name = arg;
    } else {
        log.info("missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    // expect expiration milliseconds argument
    var expiration_ms: i64 = undefined;
    if (args.next()) |arg| {
        expiration_ms = std.fmt.parseInt(i64, arg, 10) catch {
            log.info("invalid expiration '{s}' from {f}", .{ arg, connection.socket.address });
            return Cancelable.Canceled;
        };
    } else {
        log.info("missing expiration milliseconds from {f}", .{connection.socket.address});
        writer.interface.print("error: missing expiration milliseconds\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    if (self.locks.items.len > 0) {
        for (0..self.locks.items.len) |i| {
            if (self.locks.items[i].id == std.hash.Adler32.hash(lock_name)) {
                if (self.locks.items[i].state == .unlocked) {
                    writer.interface.print("granted\n", .{}) catch return Cancelable.Canceled;
                    writer.interface.flush() catch return Cancelable.Canceled;
                    self.locks.items[i].lock(Timestamp.now(io, .real).addDuration(.fromMilliseconds(expiration_ms)));
                } else {
                    log.info("lock {s} is already held, denying lock from {f}", .{ lock_name, connection.socket.address });

                    writer.interface.print("denied\n", .{}) catch return Cancelable.Canceled;
                    writer.interface.flush() catch return Cancelable.Canceled;
                }
            }
        }
    } else {
        writer.interface.print("not found\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn commandLock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    // expect lock name argument
    var lock_name: []const u8 = undefined;
    if (args.next()) |arg| {
        lock_name = arg;
    } else {
        log.info("missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    // expect expiration milliseconds argument
    var expiration_ms: i64 = undefined;
    if (args.next()) |arg| {
        expiration_ms = std.fmt.parseInt(i64, arg, 10) catch {
            log.info("invalid expiration '{s}' from {f}", .{ arg, connection.socket.address });
            return Cancelable.Canceled;
        };
    } else {
        log.info("missing expiration milliseconds from {f}", .{connection.socket.address});
        writer.interface.print("error: missing expiration milliseconds\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    if (self.locks.items.len > 0) {
        for (0..self.locks.items.len) |i| {
            if (self.locks.items[i].id == std.hash.Adler32.hash(lock_name)) {
                while (self.locks.items[i].state == .locked) {
                    self.mutex.unlock(io);
                    try io.sleep(.fromSeconds(1), .real);
                    try self.mutex.lock(io);
                }
                writer.interface.print("granted\n", .{}) catch return Io.Cancelable.Canceled;
                writer.interface.flush() catch return Io.Cancelable.Canceled;
                self.locks.items[i].lock(Timestamp.now(io, .real).addDuration(.fromMilliseconds(expiration_ms)));
            }
        }
    } else {
        writer.interface.print("not found\n", .{}) catch return Io.Cancelable.Canceled;
        writer.interface.flush() catch return Io.Cancelable.Canceled;
    }
}

fn commandUnlock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    var lock_name: []const u8 = undefined;
    if (args.next()) |arg| {
        lock_name = arg;
    } else {
        log.info("missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
        return Cancelable.Canceled;
    }

    var found = false;
    if (self.locks.items.len > 0) {
        for (self.locks.items) |*lock| {
            if (lock.id == std.hash.Adler32.hash(lock_name)) {
                lock.unlock();
                writer.interface.print("unlocked\n", .{}) catch return Cancelable.Canceled;
                writer.interface.flush() catch return Cancelable.Canceled;
                found = true;
            }
        }
    }
    if (!found) {
        writer.interface.print("not found\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn commandVersion(io: Io, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    writer.interface.print("{s}\n", .{build_zig_zon.version}) catch return Cancelable.Canceled;
    writer.interface.flush() catch return Cancelable.Canceled;
}

fn commandHelp(io: Io, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    const help_message =
        \\ Available commands:
        \\ - create <lock_name>: creates a new lock, name is hashed to create a lock ID
        \\ - lock <lock_name> <expiration_ms>: blocking
        \\ - trylock <lock_name> <expiration_ms>: non-blocking
        \\ - unlock <lock_name>
        \\ - version
        \\ - help
    ;

    writer.interface.print("{s}\n", .{help_message}) catch return Cancelable.Canceled;
    writer.interface.flush() catch return Cancelable.Canceled;
}

pub fn getLockByName(self: *const ZlockServer, lock_name: []const u8) ?*Lock {
    if (self.locks.items.len > 0) {
        for (self.locks.items) |*lock| {
            if (lock.id == std.hash.Adler32.hash(lock_name)) {
                return lock;
            }
        }
    }
    return null;
}
