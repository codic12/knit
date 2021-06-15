const std = @import("std");

pub fn spawn(
    allocator: *std.mem.Allocator,
    env: *const std.BufMap,
    cmd: []const []const u8,
    wait: bool,
) !i32 {
    const pid = try std.os.fork();
    switch (pid) {
        0 => {
            switch (std.process.execve(allocator, cmd, env)) {
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

pub const UnitKind = enum { Blocking, Daemon };

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
        cmds: []const Command,
        kind: UnitKind,
        allocator: *std.mem.Allocator,
    ) !Unit {
        return Unit{
            .name = name,
            .cmds = try allocator.dupe(Command, cmds), // make Unit own it
            .kind = kind,
            .running = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Unit) void {
        self.allocator.free(self.cmds);
    }

    pub fn load(self: *Unit, env: *const std.BufMap) !void {
        for (self.cmds) |*cmd, idx| {
            const x = try spawn(self.allocator, env, cmd.cmd, self.kind == UnitKind.Blocking);
            self.running = true;
            if (self.kind != UnitKind.Blocking) {
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
