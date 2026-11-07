//! ghs - switch GitHub accounts for both `gh` and `git` in one shot.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const version = "0.1.0";
const host = "github.com";

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
};

const Account = struct { login: []const u8, active: bool };

const usage =
    \\ghs - switch GitHub accounts for gh and git together
    \\
    \\usage:
    \\  ghs              pick an account interactively
    \\  ghs <login>      switch gh + git user.name/user.email to <login>
    \\  ghs list         list logged-in accounts
    \\  ghs status       show current gh account, git identity and remote
    \\
    \\overrides (optional, otherwise taken from the GitHub API):
    \\  git config --global ghs.<login>.name  "Name"
    \\  git config --global ghs.<login>.email "mail@example.com"
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_w = Io.File.stdout().writer(io, &out_buf);
    const ctx: Ctx = .{ .gpa = gpa, .io = io, .out = &out_w.interface };
    defer ctx.out.flush() catch {};

    const args = try init.minimal.args.toSlice(gpa);
    const cmd: []const u8 = if (args.len > 1) args[1] else "";

    if (cmd.len == 0) {
        try pick(ctx);
    } else if (eql(cmd, "list") or eql(cmd, "ls")) {
        try list(ctx);
    } else if (eql(cmd, "status") or eql(cmd, "st")) {
        try status(ctx);
    } else if (eql(cmd, "-h") or eql(cmd, "--help") or eql(cmd, "help")) {
        try ctx.out.writeAll(usage);
    } else if (eql(cmd, "-v") or eql(cmd, "--version")) {
        try ctx.out.print("ghs {s}\n", .{version});
    } else {
        try switchTo(ctx, cmd);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Run a command; returns trimmed stdout, or error.CommandFailed (stderr is echoed).
fn run(ctx: Ctx, argv: []const []const u8) ![]const u8 {
    const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv }) catch |e| {
        try ctx.out.print("ghs: failed to run '{s}': {s}\n", .{ argv[0], @errorName(e) });
        return error.CommandFailed;
    };
    switch (r.term) {
        .exited => |code| if (code == 0) return std.mem.trim(u8, r.stdout, " \r\n\t"),
        else => {},
    }
    try ctx.out.print("{s}", .{r.stderr});
    return error.CommandFailed;
}

/// Like run, but returns null on failure or empty output, without printing.
fn runQuiet(ctx: Ctx, argv: []const []const u8) ?[]const u8 {
    const r = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv }) catch return null;
    switch (r.term) {
        .exited => |code| if (code == 0) {
            const s = std.mem.trim(u8, r.stdout, " \r\n\t");
            return if (s.len == 0) null else s;
        },
        else => {},
    }
    return null;
}

fn accounts(ctx: Ctx) ![]Account {
    const json = try run(ctx, &.{ "gh", "auth", "status", "--json", "hosts" });
    const Entry = struct { login: []const u8, active: bool };
    const Status = struct { hosts: std.json.ArrayHashMap([]const Entry) };
    const parsed = try std.json.parseFromSliceLeaky(Status, ctx.gpa, json, .{ .ignore_unknown_fields = true });
    const entries = parsed.hosts.map.get(host) orelse return &.{};
    const accs = try ctx.gpa.alloc(Account, entries.len);
    for (entries, 0..) |e, i| accs[i] = .{ .login = e.login, .active = e.active };
    return accs;
}

fn printAccounts(ctx: Ctx, accs: []const Account) !void {
    for (accs, 1..) |a, i| {
        try ctx.out.print("{s} {d}) {s}\n", .{ if (a.active) "*" else " ", i, a.login });
    }
}

fn list(ctx: Ctx) !void {
    try printAccounts(ctx, try accounts(ctx));
}

fn pick(ctx: Ctx) !void {
    const accs = try accounts(ctx);
    if (accs.len == 0) {
        try ctx.out.writeAll("no accounts. run `gh auth login` first.\n");
        return;
    }
    try printAccounts(ctx, accs);
    try ctx.out.writeAll("select> ");
    try ctx.out.flush();

    var in_buf: [256]u8 = undefined;
    var in_r = Io.File.stdin().reader(ctx.io, &in_buf);
    const line = (in_r.interface.takeDelimiter('\n') catch null) orelse return;
    const s = std.mem.trim(u8, line, " \r\n\t");
    if (s.len == 0) return;

    const login = blk: {
        if (std.fmt.parseInt(usize, s, 10)) |n| {
            if (n >= 1 and n <= accs.len) break :blk accs[n - 1].login;
        } else |_| {}
        break :blk s;
    };
    try switchTo(ctx, login);
}

fn switchTo(ctx: Ctx, login: []const u8) !void {
    _ = run(ctx, &.{ "gh", "auth", "switch", "-h", host, "-u", login }) catch return;

    const name_key = try std.fmt.allocPrint(ctx.gpa, "ghs.{s}.name", .{login});
    const email_key = try std.fmt.allocPrint(ctx.gpa, "ghs.{s}.email", .{login});
    var name = runQuiet(ctx, &.{ "git", "config", "--global", "--get", name_key });
    var email = runQuiet(ctx, &.{ "git", "config", "--global", "--get", email_key });

    if (name == null or email == null) {
        const User = struct {
            id: u64,
            login: []const u8,
            name: ?[]const u8 = null,
            email: ?[]const u8 = null,
        };
        const json = run(ctx, &.{ "gh", "api", "user" }) catch return;
        const u = try std.json.parseFromSliceLeaky(User, ctx.gpa, json, .{ .ignore_unknown_fields = true });
        if (name == null) name = u.name orelse u.login;
        if (email == null) email = u.email orelse
            try std.fmt.allocPrint(ctx.gpa, "{d}+{s}@users.noreply.github.com", .{ u.id, u.login });
    }

    _ = run(ctx, &.{ "git", "config", "--global", "user.name", name.? }) catch return;
    _ = run(ctx, &.{ "git", "config", "--global", "user.email", email.? }) catch return;
    try ctx.out.print("switched to {s}  ({s} <{s}>)\n", .{ login, name.?, email.? });
}

fn status(ctx: Ctx) !void {
    const accs = try accounts(ctx);
    var active: []const u8 = "(none)";
    for (accs) |a| {
        if (a.active) active = a.login;
    }
    const name = runQuiet(ctx, &.{ "git", "config", "user.name" }) orelse "(unset)";
    const email = runQuiet(ctx, &.{ "git", "config", "user.email" }) orelse "(unset)";

    try ctx.out.print("gh account : {s}\n", .{active});
    try ctx.out.print("git user   : {s} <{s}>\n", .{ name, email });
    if (runQuiet(ctx, &.{ "git", "remote", "get-url", "origin" })) |r| {
        try ctx.out.print("remote     : {s}\n", .{r});
        if (ownerOf(r)) |owner| {
            if (!std.ascii.eqlIgnoreCase(owner, active)) {
                try ctx.out.print("note       : remote owner '{s}' differs from gh account '{s}'\n", .{ owner, active });
            }
        }
    }
}

/// Extract the owner from https://github.com/owner/repo or git@github.com:owner/repo
fn ownerOf(url: []const u8) ?[]const u8 {
    const start = if (std.mem.indexOf(u8, url, "github.com/")) |i|
        i + "github.com/".len
    else if (std.mem.indexOf(u8, url, "github.com:")) |i|
        i + "github.com:".len
    else
        return null;
    const rest = url[start..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    return rest[0..end];
}

test ownerOf {
    try std.testing.expectEqualStrings("ygp", ownerOf("https://github.com/ygp/ghs.git").?);
    try std.testing.expectEqualStrings("ygp", ownerOf("git@github.com:ygp/ghs.git").?);
    try std.testing.expect(ownerOf("https://example.com/x/y") == null);
}
