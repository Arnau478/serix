const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .msvc,
    });

    const boot_info_mod = b.createModule(.{
        .root_source_file = b.path("boot/BootInfo.zig"),
        .optimize = optimize,
        .target = target,
    });

    const boot_mod = b.createModule(.{
        .root_source_file = b.path("boot/efi/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    boot_mod.addImport("BootInfo", boot_info_mod);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .optimize = optimize,
        .target = target,
    });
    kernel_mod.addImport("BootInfo", boot_info_mod);
    kernel_mod.addImport("boot", boot_mod);
    boot_mod.addImport("kernel", kernel_mod);
    kernel_mod.addAnonymousImport("panic_font", .{ .root_source_file = b.path("assets/panic_font") });

    const exe = b.addExecutable(.{
        .name = "stub",
        .root_module = kernel_mod,
    });

    const esp_wf = b.addWriteFiles();
    _ = esp_wf.addCopyFile(exe.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");

    b.installDirectory(.{
        .source_dir = esp_wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "esp",
    });
}
