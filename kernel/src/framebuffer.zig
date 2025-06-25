const std = @import("std");
const root = @import("root");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub fn putPixel(x: usize, y: usize, color: Color) void {
    std.debug.assert(x < root.boot_info.framebuffer.width);
    std.debug.assert(y < root.boot_info.framebuffer.height);
    root.boot_info.framebuffer.slice[4 * (y * root.boot_info.framebuffer.width + x) + 0] = color.b;
    root.boot_info.framebuffer.slice[4 * (y * root.boot_info.framebuffer.width + x) + 1] = color.g;
    root.boot_info.framebuffer.slice[4 * (y * root.boot_info.framebuffer.width + x) + 2] = color.r;
}

pub fn clear(color: Color) void {
    for (0..root.boot_info.framebuffer.height) |y| {
        for (0..root.boot_info.framebuffer.width) |x| {
            putPixel(x, y, color);
        }
    }
}
