const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const boot_info_mod = b.createModule(.{
        .root_source_file = b.path("boot/BootInfo.zig"),
        .optimize = optimize,
    });

    const boot_mod = b.createModule(.{
        .root_source_file = b.path("boot/efi/main.zig"),
        .optimize = optimize,
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
            .abi = .msvc,
        }),
    });
    boot_mod.addImport("BootInfo", boot_info_mod);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/main.zig"),
        .optimize = optimize,
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
    });
    kernel_mod.addImport("BootInfo", boot_info_mod);
    kernel_mod.addAnonymousImport("panic_font", .{ .root_source_file = b.path("assets/panic_font") });

    const boot_exe = b.addExecutable(.{
        .name = "boot",
        .root_module = boot_mod,
    });

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    kernel_exe.setLinkerScript(b.path("kernel/linker.ld"));

    const esp_wf = b.addWriteFiles();
    _ = esp_wf.addCopyFile(boot_exe.getEmittedBin(), "EFI/BOOT/BOOTX64.EFI");
    _ = esp_wf.addCopyFile(kernel_exe.getEmittedBin(), "kernel");

    b.installDirectory(.{
        .source_dir = esp_wf.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "esp",
    });
}
