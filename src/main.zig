const std = @import("std");
const build_zig_zon = @import("build_zig_zon");
const clap = @import("clap");

const process = std.process;
const log = std.log;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const Mutex = std.Io.Mutex;
const IpAddress = Io.net.IpAddress;
const Client = std.http.Client;

const ZlockServer = @import("ZlockServer.zig");
const Lock = @import("Lock.zig");

const commands = enum {
    create,
    lock,
    trylock,
    unlock,
    server,
    version,
    help,
};
const clap_main_parsers = .{
    .command = clap.parsers.enumeration(commands),
};
const clap_main_params = clap.parseParamsComptime(
    \\-h, --help   Display this help and exit.
    \\<command>
    \\
);

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var iter = try init.minimal.args.iterateAllocator(gpa);
    defer iter.deinit();
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &clap_main_params, clap_main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return commandHelp(io);
    };
    defer res.deinit();

    if (res.positionals.len == 0) {
        return commandHelp(io);
    }

    const cmd = res.positionals[0] orelse return commandHelp(io);
    switch (cmd) {
        .create => try commandCreate(gpa, io),
        .lock => try commandLock(io),
        .trylock => try commandTryLock(io),
        .unlock => try commandUnlock(io),
        .server => try commandServer(gpa, io, &iter),
        .version => try commandVersion(io),
        .help => try commandHelp(io),
    }
}

/// TODO
fn commandCreate(allocator: Allocator, io: Io) !void {
    log.err("command not implemented", .{});

    const hostname = try Io.net.HostName.init("localhost");

    const stream = try hostname.connect(io, 1998, .{ .mode = .stream });
    defer stream.close(io);

    var w_buff: [1024]u8 = undefined;
    var writer = stream.writer(io, &w_buff);

    _ = try writer.interface.write("create A\n");
    try writer.interface.flush();

    var r_buff: [1024]u8 = undefined;
    var reader = stream.reader(io, &r_buff);

    const res = try reader.interface.allocRemainingAlignedSentinel(allocator, .unlimited, .of(u8), '\n');
    defer allocator.free(res);

    const res_trimmed = std.mem.trimEnd(u8, res, "\n");
    try Io.File.stdout().writeStreamingAll(io, res_trimmed);
}

/// TODO
fn commandLock(io: Io) !void {
    _ = io;
    log.err("command not implemented", .{});
}

/// TODO
fn commandTryLock(io: Io) !void {
    _ = io;
    log.err("command not implemented", .{});
}

/// TODO
fn commandUnlock(io: Io) !void {
    _ = io;
    log.err("command not implemented", .{});
}

/// Start a zlock server
fn commandServer(allocator: Allocator, io: Io, iter: *process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\--address <str>     IpAddress to bind to. Defaults to [::1]:1998 or 0.0.0.0:1998.
        \\--help              Display this help and exit.
    );

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        process.exit(1);
    };
    defer res.deinit();

    const help_message = "help for server command\n"; // TODO

    if (res.args.help != 0)
        return try Io.File.stdout().writeStreamingAll(io, help_message);

    var address: IpAddress = undefined;
    if (res.args.address) |literal| {
        address = IpAddress.parseLiteral(literal) catch |err| {
            return log.err("Failed to parse address {s} ({}).", .{ literal, err });
        };
    } else {
        address = IpAddress.parseLiteral("[::1]:1998") catch |err| {
            return log.err("Failed to parse default address [::1]:1998 ({}).", .{err});
        };
    }

    // a list of locks
    var locks = try ArrayList(Lock).initCapacity(allocator, 0);
    var mutex = Mutex.init;
    const server: ZlockServer = .{
        .address = address,
        .locks = &locks,
        .mutex = &mutex,
    };

    try server.start(allocator, io);
}

fn commandVersion(io: Io) !void {
    const version = comptime try std.SemanticVersion.parse(build_zig_zon.version);
    const version_string = std.fmt.comptimePrint("{f}\n", .{version});
    try Io.File.stdout().writeStreamingAll(io, version_string);
}

fn commandHelp(io: Io) !void {
    const message =
        \\TODO
    ;
    try Io.File.stdout().writeStreamingAll(io, message);
}
