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

const Client = @import("Client.zig");
const Server = @import("Server.zig");
const Lock = @import("Lock.zig");

const SubCommands = enum {
    lock,
    trylock,
    unlock,
    server,
    version,
    help,
};
const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};
const main_params = clap.parseParamsComptime(
    \\-h, --help   Display this help and exit.
    \\<command>
    \\
);
const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

pub fn main(init: process.Init) !void {
    const arena = init.gpa;
    const io = init.io;

    var iter = try init.minimal.args.iterateAllocator(arena);
    defer iter.deinit();
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = arena,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return subCommandHelp(io);
    };
    defer res.deinit();

    if (res.positionals.len == 0) {
        return subCommandHelp(io);
    }

    const subcommand = res.positionals[0] orelse return subCommandHelp(io);
    switch (subcommand) {
        .lock => try subCommandLock(io), // TODO
        .trylock => try subCommandTryLock(io), // TODO
        .unlock => try subCommandUnlock(io), // TODO
        .server => try subCommandServer(arena, io, &iter, res), // TODO
        .version => try subCommandVersion(io),
        .help => try subCommandHelp(io),
    }
}

fn subCommandLock(io: Io) !void {
    _ = io;
    // TODO
}

fn subCommandTryLock(io: Io) !void {
    _ = io;
    // TODO
}

fn subCommandUnlock(io: Io) !void {
    _ = io;
    // TODO
}

/// Start a zlock server
fn subCommandServer(allocator: Allocator, io: Io, iter: *process.Args.Iterator, main_args: MainArgs) !void {
    _ = main_args;

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

    const help_message = "help for server subcommand\n"; // TODO

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
    const server: Server = .{
        .address = address,
        .locks = &locks,
        .mutex = &mutex,
    };

    try server.start(allocator, io);
}

fn subCommandVersion(io: Io) !void {
    const version = comptime try std.SemanticVersion.parse(build_zig_zon.version);
    const version_string = std.fmt.comptimePrint("{f}\n", .{version});
    try Io.File.stdout().writeStreamingAll(io, version_string);
}

fn subCommandHelp(io: Io) !void {
    const message =
        \\TODO
    ;
    try Io.File.stdout().writeStreamingAll(io, message);
}
