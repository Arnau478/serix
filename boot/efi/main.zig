const std = @import("std");
const BootInfo = @import("BootInfo");

const uefi = std.os.uefi;

var log_con_out: ?*uefi.protocol.SimpleTextOutput = null;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

const LogWriter = std.io.Writer(void, error{}, logWrite);

fn logWrite(_: void, bytes: []const u8) error{}!usize {
    if (log_con_out) |con_out| {
        for (bytes) |byte| {
            if (con_out.outputString(&[_:0]u16{byte}) != .success) break;
        }
    }
    return bytes.len;
}

fn logFn(comptime level: std.log.Level, comptime _: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
    const writer = LogWriter{ .context = {} };
    writer.print(level.asText() ++ ": " ++ format ++ "\r\n", args) catch |err| switch (err) {};
}

const UefiMemoryMap = struct {
    data: []align(8) u8,
    descriptor_size: usize,
    key: usize,
};

fn getMemoryMap() error{MemoryMapError}!UefiMemoryMap {
    const boot_services = uefi.system_table.boot_services.?;

    var memory_map_ptr: [*]align(8) u8 = undefined;
    var memory_map_size: usize = 0;
    var memory_map_key: usize = 0;
    var descriptor_size: usize = 0;
    var descriptor_version: u32 = 0;

    // This should fail with buffer_too_small, but return the size
    if (boot_services.getMemoryMap(&memory_map_size, null, &memory_map_key, &descriptor_size, &descriptor_version) != .buffer_too_small) return error.MemoryMapError;

    // Allocation can create up to 2 new descriptors
    memory_map_size += 2 * descriptor_size;

    // Allocate pool memory for the memory map
    if (boot_services.allocatePool(.loader_data, memory_map_size, &memory_map_ptr) != .success) return error.MemoryMapError;

    // Get the memory map, it should now succeed
    if (boot_services.getMemoryMap(&memory_map_size, @ptrCast(memory_map_ptr), &memory_map_key, &descriptor_size, &descriptor_version) != .success) return error.MemoryMapError;

    std.debug.assert(memory_map_size % descriptor_size == 0);

    return .{
        .data = memory_map_ptr[0..memory_map_size],
        .descriptor_size = descriptor_size,
        .key = memory_map_key,
    };
}

pub fn main() void {
    const boot_services = uefi.system_table.boot_services.?;
    const con_out = uefi.system_table.con_out.?;

    _ = con_out.reset(false);

    log_con_out = con_out;

    std.log.debug("Booting...", .{});

    std.log.debug("Opening kernel...", .{});
    var fs: *uefi.protocol.SimpleFileSystem = undefined;
    if (boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs)) != .success) return;
    var fs_root: *const uefi.protocol.File = undefined;
    if (fs.openVolume(&fs_root) != .success) return;
    var elf_file: *const uefi.protocol.File = undefined;
    if (fs_root.open(&elf_file, std.unicode.utf8ToUtf16LeStringLiteral("kernel"), uefi.protocol.File.efi_file_mode_read, 0) != .success) return;

    std.log.debug("Parsing kernel...", .{});
    var ehdr_size: usize = @sizeOf(std.elf.Elf64_Ehdr);
    const ehdr_data: []align(8) u8 = (uefi.pool_allocator.allocWithOptions(u8, ehdr_size, 8, null) catch return);
    if (elf_file.read(&ehdr_size, ehdr_data.ptr) != .success) return;
    const ehdr = std.mem.bytesToValue(std.elf.Elf64_Ehdr, ehdr_data);

    if (!std.mem.eql(u8, ehdr.e_ident[0..4], std.elf.MAGIC)) {
        std.log.err("Invalid kernel ELF file", .{});
        return;
    }

    std.log.debug("Kernel entry point: 0x{x}", .{ehdr.e_entry});

    const phdrs = uefi.pool_allocator.alloc(std.elf.Elf64_Phdr, ehdr.e_phnum) catch return;

    if (elf_file.setPosition(ehdr.e_phoff) != .success) return;
    var phdrs_size = @sizeOf(std.elf.Elf64_Phdr) * phdrs.len;
    if (elf_file.read(&phdrs_size, std.mem.sliceAsBytes(phdrs).ptr) != .success) return;

    var min_addr: usize = std.math.maxInt(usize);
    var max_addr: usize = 0;

    for (phdrs) |phdr| {
        if (phdr.p_type == std.elf.PT_LOAD) {
            min_addr = @min(min_addr, phdr.p_vaddr);
            max_addr = @max(max_addr, phdr.p_vaddr + phdr.p_memsz);
        }
    }

    std.log.debug("Memory range: 0x{x} - 0x{x}", .{ min_addr, max_addr });
    const kernel_size = max_addr - min_addr;
    const kernel_page_count = std.math.divCeil(usize, kernel_size, std.heap.pageSize()) catch unreachable;
    std.log.debug("Total memory needed: {} KiB ({} pages)", .{ kernel_size / 1024, kernel_page_count });

    std.log.debug("Allocating kernel...", .{});
    var kernel_base: [*]align(4096) u8 = @ptrFromInt(min_addr);
    if (boot_services.allocatePages(.allocate_address, .loader_code, kernel_page_count, &kernel_base) != .success) return;
    boot_services.setMem(kernel_base, kernel_size, 0);

    for (phdrs) |phdr| {
        if (phdr.p_type == std.elf.PT_LOAD) {
            if (elf_file.setPosition(phdr.p_offset) != .success) return;

            var file_size = phdr.p_filesz;
            if (file_size > 0) {
                if (elf_file.read(&file_size, @ptrFromInt(@intFromPtr(kernel_base) + (phdr.p_vaddr - min_addr))) != .success) return;
            }
        }
    }

    const kernel_entry: *const fn (usize, *BootInfo) callconv(.{ .x86_64_sysv = .{} }) noreturn = @ptrFromInt(@intFromPtr(kernel_base) + (ehdr.e_entry - min_addr));

    std.log.debug("Getting graphics info...", .{});
    var graphics: *uefi.protocol.GraphicsOutput = undefined;
    if (boot_services.locateProtocol(&uefi.protocol.GraphicsOutput.guid, null, @ptrCast(&graphics)) != .success) return;
    std.log.debug("Framebuffer at 0x{x} ({}x{})", .{ graphics.mode.frame_buffer_base, graphics.mode.info.horizontal_resolution, graphics.mode.info.vertical_resolution });

    const boot_info = uefi.pool_allocator.create(BootInfo) catch return;
    std.log.debug("Boot info at 0x{x}", .{@intFromPtr(boot_info)});

    boot_info.* = .{
        .framebuffer = .{
            .slice = @as([*]u8, @ptrFromInt(graphics.mode.frame_buffer_base))[0..graphics.mode.frame_buffer_size],
            .width = graphics.mode.info.horizontal_resolution,
            .height = graphics.mode.info.vertical_resolution,
        },
        .memory_map = undefined, // This is done later
    };

    var uefi_memory_map = getMemoryMap() catch return;
    const memory_map_data = uefi.pool_allocator.alloc(BootInfo.MemoryMapEntry, @divExact(uefi_memory_map.data.len, uefi_memory_map.descriptor_size) + 2) catch return;
    uefi_memory_map = getMemoryMap() catch return;
    var memory_map_len: usize = 0;

    var uefi_i: usize = 0;
    while (uefi_i < @divExact(uefi_memory_map.data.len, uefi_memory_map.descriptor_size)) : (uefi_i += 1) {
        const uefi_entry = @as(*uefi.tables.MemoryDescriptor, @ptrCast(@alignCast(&uefi_memory_map.data[uefi_memory_map.descriptor_size * uefi_i]))).*;
        std.log.debug("{}: {s} at 0x{x} with {} pages", .{ uefi_i, @tagName(uefi_entry.type), uefi_entry.physical_start, uefi_entry.number_of_pages });

        const memory_type: BootInfo.MemoryMapEntry.Type = switch (uefi_entry.type) {
            .conventional_memory, .boot_services_code, .boot_services_data => .usable,
            .loader_code, .loader_data => .loader_and_kernel,
            .acpi_reclaim_memory => .acpi,
            .acpi_memory_nvs => .nvs,
            .memory_mapped_io, .memory_mapped_io_port_space => .mmio,
            .runtime_services_code,
            .runtime_services_data,
            .unusable_memory,
            .pal_code,
            .persistent_memory,
            => .reserved,
            .reserved_memory_type, .max_memory_type => .unknown,
            _ => .unknown,
        };
        if (memory_map_len > 0 and
            memory_map_data[memory_map_len - 1].type == memory_type and
            memory_map_data[memory_map_len - 1].start + memory_map_data[memory_map_len - 1].length == uefi_entry.physical_start)
        {
            memory_map_data[memory_map_len - 1].length += uefi_entry.number_of_pages * 4096;
        } else {
            memory_map_data[memory_map_len] = .{
                .type = memory_type,
                .start = uefi_entry.physical_start,
                .length = uefi_entry.number_of_pages * 4096,
            };

            memory_map_len += 1;
        }
    }
    boot_info.memory_map = memory_map_data[0..memory_map_len];

    std.log.debug("Running kernel...", .{});
    if (boot_services.exitBootServices(uefi.handle, uefi_memory_map.key) == .success) {
        kernel_entry(0xdeadbeef, boot_info);
    } else {
        while (true) {}
    }
}
