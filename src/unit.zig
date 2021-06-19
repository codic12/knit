const std = @import("std");

pub fn spawn(
    allocator: *std.mem.Allocator,
    env: *const std.BufMap,
    cmd: []const []const u8,
    wait: bool,
) !i32 {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = &arena_allocator.allocator;

    const argv_buf = try arena.allocSentinel(?[*:0]u8, cmd.len, null);

    for (cmd) |arg, i| argv_buf[i] = (try arena.dupeZ(u8, arg)).ptr;
    const pid = try std.os.fork();

    switch (pid) {
        0 => {
            switch (std.os.execveZ(argv_buf.ptr[0].?, argv_buf.ptr, std.c.environ)) {
                error.AccessDenied => std.log.err("access denied", .{}),
                error.FileNotFound => std.log.err("file not found", .{}),
                else => std.log.err("unhandled error", .{}),
            }
        },
        else => {
            if (wait) {
                _ = std.os.waitpid(pid, 0);
            }
            return pid;
        },
    }
    return 0; // should not happen
}

pub const UnitKind = enum { Task, Daemon };

pub const Command = struct {
    cmd: []const []const u8,
    pid: i32,
    running: bool,
};

/// a Unit is a runtime-loadable service-like structure. it consists of a command and information describing it.
pub const Unit = struct {
    name: []const u8,
    cmds: []Command,
    kind: UnitKind,
    running: bool,
    allocator: *std.mem.Allocator,

    pub fn init(
        name: []const u8,
        cmds: []Command,
        kind: UnitKind,
        allocator: *std.mem.Allocator,
    ) !Unit {
        return Unit{
            .name = name,
            .cmds = cmds,
            .kind = kind,
            .running = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Unit) void {
        for (self.cmds) |cmd| {
            for (cmd.cmd) |str| self.allocator.free(str);
            self.allocator.free(cmd.cmd);
        }
        self.allocator.free(self.cmds);
    }

    pub fn load(self: *Unit, env: *const std.BufMap) !void {
        for (self.cmds) |*cmd, idx| {
            std.debug.print("{any}", .{cmd.cmd});
            const x = try spawn(self.allocator, env, cmd.cmd, self.kind == UnitKind.Task);
            self.running = true;
            if (self.kind != UnitKind.Task) {
                self.cmds[idx].pid = x;
                self.cmds[idx].running = true;
            }
        }
    }

    pub fn unload(self: *Unit) void {
        if (!self.running) return; // already unloaded; better safe than sorry
        for (self.cmds) |p| {
            if (p.running) continue;
            _ = std.os.kill(p.pid, 0) catch continue;
        }
        self.running = false;
    }
};
