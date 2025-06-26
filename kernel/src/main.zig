const std = @import("std");
const boot = @import("boot");
const BootInfo = @import("BootInfo");
const framebuffer = @import("framebuffer.zig");
const panic_font = @embedFile("panic_font");

pub var boot_info: *BootInfo = undefined;

pub const panic = std.debug.FullPanic(panicHandler);

const PanicWriter = struct {
    row: usize = 0,
    col: usize = 0,
    row_offset: usize = 0,
    col_offset: usize = 0,

    fn putChar(w: *PanicWriter, char: u8) void {
        switch (char) {
            '\n', '\r' => {
                w.col = 0;
                w.row += 1;
            },
            else => {
                for (0..16) |y| {
                    for (0..8) |x| {
                        if ((@as(*const [4096]u8, panic_font)[@as(usize, char) * 16 + y] >> @intCast(7 - x)) & 1 > 0) {
                            framebuffer.putPixel((w.col + w.col_offset) * 8 + x, (w.row + w.row_offset) * 16 + y, .{ .r = 255, .g = 255, .b = 255 });
                        }
                    }
                }
                w.col += 1;
            },
        }
    }

    fn write(w: *PanicWriter, bytes: []const u8) error{}!usize {
        for (bytes) |char| {
            w.putChar(char);
        }
        return bytes.len;
    }

    fn writer(w: *PanicWriter) std.io.GenericWriter(*PanicWriter, error{}, write) {
        return .{ .context = w };
    }
};

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    framebuffer.clear(.{ .r = 0, .g = 0, .b = 0 });
    framebuffer.clear(.{ .r = 50, .g = 0, .b = 0 });

    var writer: PanicWriter = .{ .col_offset = 2, .row_offset = 1 };
    writer.writer().print(
        \\* PANIC *
        \\
        \\Message: {s}
        \\
        \\Trace address: 0x{?x:0>16}
        \\
        \\Halting system...
    , .{ msg, first_trace_addr }) catch |err| switch (err) {};

    while (true) {}
}

pub const std_options: std.Options = .{
    .logFn = logFn,
};

const LogWriter = std.io.Writer(void, error{}, logWrite);

// TODO: Write a general "real" write function
fn logWrite(_: void, bytes: []const u8) error{}!usize {
    for (bytes) |byte| {
        asm volatile ("outb %[data], %[port]"
            :
            : [data] "{al}" (byte),
              [port] "N{dx}" (0xE9),
        );
    }
    return bytes.len;
}

fn logFn(comptime level: std.log.Level, comptime _: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const writer = LogWriter{ .context = {} };
    writer.print(level.asText() ++ ": " ++ format ++ "\n", args) catch |err| switch (err) {};
}

export fn _start(magic: usize, _boot_info: *BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    if (magic != 0xdeadbeef) @trap();
    boot_info = _boot_info;
    kmain();
}

fn kmain() noreturn {
    std.log.debug("Starting kernel...", .{});

    for (boot_info.memory_map, 0..) |entry, i| {
        std.log.debug("Memory map entry {d:0>2}: {s:<18} 0x{x} -- 0x{x}", .{ i, @tagName(entry.type), entry.start, entry.start + entry.length });
    }

    std.log.debug("Halting", .{});
    while (true) {}
}
