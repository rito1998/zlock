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

    var iterator = std.mem.splitSequence(u8, trimmed_msg, " ");
    if (iterator.next()) |param| {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const command = std.meta.stringToEnum(Command, param) orelse {
            log.err("unknown command: {s} from {f}", .{ trimmed_msg, connection.socket.address });
            writer.interface.print("unknown command\n", .{}) catch return Cancelable.Canceled;
            writer.interface.flush() catch return Cancelable.Canceled;
            return Cancelable.Canceled;
        };

        switch (command) {
            .create => try self.handleCommandCreate(allocator, io, &iterator, connection),
            .trylock => try self.handleCommandTrylock(io, &iterator, connection),
            .lock => try self.handleCommandLock(io, &iterator, connection),
            .unlock => try self.handleCommandUnlock(io, &iterator, connection),
            .version => try handleCommandVersion(io, connection),
            .help => try handleCommandHelp(io, connection),
        }
    }

    log.info("Closed the connection to {f}. Current server state: {f}", .{ connection.socket.address, self });
    try self.logLocks(io);
}

fn handleCommandCreate(self: *const ZlockServer, allocator: Allocator, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    if (args.next()) |name| {
        log.info("received create command for {s} from {f}", .{ name, connection.socket.address });

        var found = false;
        if (self.locks.items.len > 0) {
            for (self.locks.items) |lock| {
                if (lock.id == std.hash.Adler32.hash(name)) {
                    log.info("lock {s} already exists, denying create from {f}", .{ name, connection.socket.address });
                    writer.interface.print("already exists\n", .{}) catch return Cancelable.Canceled;
                    writer.interface.flush() catch return Cancelable.Canceled;
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            const new_lock: Lock = .init(std.hash.Adler32.hash(name), .zero);
            self.locks.append(allocator, new_lock) catch return Cancelable.Canceled;
            writer.interface.print("created\n", .{}) catch return Cancelable.Canceled;
            writer.interface.flush() catch return Cancelable.Canceled;
        }
    } else {
        log.info("create command missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: create command missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn handleCommandTrylock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    if (args.next()) |name| {
        if (args.next()) |expiration_ms_str| {
            const expiration_ms = std.fmt.parseInt(i64, expiration_ms_str, 10) catch {
                log.info("trylock command has invalid expiration '{s}' from {f}", .{ expiration_ms_str, connection.socket.address });
                return Cancelable.Canceled;
            };
            log.info("received lock command for {s} with expiration {d}ms from {f}", .{ name, expiration_ms, connection.socket.address });

            if (self.locks.items.len > 0) {
                for (0..self.locks.items.len) |i| {
                    if (self.locks.items[i].id == std.hash.Adler32.hash(name)) {
                        if (self.locks.items[i].state == .unlocked) {
                            writer.interface.print("granted\n", .{}) catch return Cancelable.Canceled;
                            writer.interface.flush() catch return Cancelable.Canceled;
                            self.locks.items[i].lock(Timestamp.now(io, .real).addDuration(.fromMilliseconds(expiration_ms)));
                        } else {
                            log.info("lock {s} is already held, denying lock from {f}", .{ name, connection.socket.address });

                            writer.interface.print("denied\n", .{}) catch return Cancelable.Canceled;
                            writer.interface.flush() catch return Cancelable.Canceled;
                        }
                    }
                }
            } else {
                writer.interface.print("not found\n", .{}) catch return Cancelable.Canceled;
                writer.interface.flush() catch return Cancelable.Canceled;
            }
        } else {
            log.info("trylock command missing expiration milliseconds from {f}", .{connection.socket.address});
            writer.interface.print("error: trylock command missing expiration milliseconds\n", .{}) catch return Cancelable.Canceled;
            writer.interface.flush() catch return Cancelable.Canceled;
        }
    } else {
        log.info("trylock command missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: trylock command missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn handleCommandLock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    if (args.next()) |name| {
        log.info("received lock command for {s} from {f}", .{ name, connection.socket.address });

        if (self.locks.items.len > 0) {
            for (0..self.locks.items.len) |i| {
                if (self.locks.items[i].id == std.hash.Adler32.hash(name)) {
                    while (self.locks.items[i].state == .locked) {
                        self.mutex.unlock(io);
                        try io.sleep(.fromSeconds(1), .real);
                        try self.mutex.lock(io);
                    }
                    writer.interface.print("granted\n", .{}) catch return Io.Cancelable.Canceled;
                    writer.interface.flush() catch return Io.Cancelable.Canceled;
                    if (args.next()) |expiration_ms_str| {
                        const expiration_ms = std.fmt.parseInt(i64, expiration_ms_str, 10) catch {
                            log.info("lock command has invalid expiration '{s}' from {f}", .{ expiration_ms_str, connection.socket.address });
                            return Io.Cancelable.Canceled;
                        };
                        self.locks.items[i].lock(Timestamp.now(io, .real).addDuration(.fromMilliseconds(expiration_ms)));
                    } else {
                        log.warn("lock command missing expiration milliseconds from {f}, defaulting to 10 seconds", .{connection.socket.address});
                        self.locks.items[i].lock(Timestamp.now(io, .real).addDuration(.fromSeconds(10)));
                    }
                }
            }
        } else {
            writer.interface.print("not found\n", .{}) catch return Io.Cancelable.Canceled;
            writer.interface.flush() catch return Io.Cancelable.Canceled;
        }
    } else {
        log.info("lock command missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: lock command missing lock name\n", .{}) catch return Io.Cancelable.Canceled;
        writer.interface.flush() catch return Io.Cancelable.Canceled;
    }
}

fn handleCommandUnlock(self: *const ZlockServer, io: Io, args: *SplitIterator, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    if (args.next()) |name| {
        log.info("received unlock command for {s} from {f}", .{ name, connection.socket.address });

        var found = false;
        if (self.locks.items.len > 0) {
            for (self.locks.items) |*lock| {
                if (lock.id == std.hash.Adler32.hash(name)) {
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
    } else {
        log.info("unlock command missing lock name from {f}", .{connection.socket.address});
        writer.interface.print("error: unlock command missing lock name\n", .{}) catch return Cancelable.Canceled;
        writer.interface.flush() catch return Cancelable.Canceled;
    }
}

fn handleCommandVersion(io: Io, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    log.info("received version command from {f}", .{connection.socket.address});
    writer.interface.print("{s}\n", .{build_zig_zon.version}) catch return Cancelable.Canceled;
    writer.interface.flush() catch return Cancelable.Canceled;
}

fn handleCommandHelp(io: Io, connection: Stream) Cancelable!void {
    var w_buff = [_]u8{0} ** 1024;
    var writer = connection.writer(io, &w_buff);

    const help_message =
        \\ Available commands:
        \\ - create <lock_name>: creates a new lock, name is hashed to create a lock ID
        \\ - lock <lock_name> [expiration_ms]: blocking
        \\ - trylock <lock_name> <expiration_ms>: non-blocking
        \\ - unlock <lock_name>
        \\ - version
        \\ - help
    ;

    log.info("received help command from {f}", .{connection.socket.address});
    writer.interface.print("{s}\n", .{help_message}) catch return Cancelable.Canceled;
    writer.interface.flush() catch return Cancelable.Canceled;
}
