const std = @import("std");
const BootInfo = @import("BootInfo");
const kernel = @import("kernel");

pub fn main() void {
    var graphics: *std.os.uefi.protocol.GraphicsOutput = undefined;
    if (std.os.uefi.system_table.boot_services.?.locateProtocol(&std.os.uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&graphics)) != .success) {
        return;
    }

    var memory_map: [*]std.os.uefi.tables.MemoryDescriptor = undefined;
    var memory_map_size: usize = 0;
    var memory_map_key: usize = undefined;
    var memory_map_descriptor_size: usize = undefined;
    var memory_map_descriptor_version: u32 = undefined;
    while (std.os.uefi.system_table.boot_services.?.getMemoryMap(&memory_map_size, memory_map, &memory_map_key, &memory_map_descriptor_size, &memory_map_descriptor_version) == .buffer_too_small) {
        if (std.os.uefi.system_table.boot_services.?.allocatePool(.boot_services_data, memory_map_size, @ptrCast(&memory_map)) != .success) {
            return;
        }
    }

    if (std.os.uefi.system_table.boot_services.?.exitBootServices(std.os.uefi.handle, memory_map_key) == .success) {
        @as(fn (BootInfo) noreturn, kernel.kmain)(.{
            .framebuffer = .{
                .slice = @as([*]u8, @ptrFromInt(graphics.mode.frame_buffer_base))[0..graphics.mode.frame_buffer_size],
                .width = graphics.mode.info.horizontal_resolution,
                .height = graphics.mode.info.vertical_resolution,
            },
        });
    } else {
        while (true) {}
    }
}
