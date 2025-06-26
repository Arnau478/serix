framebuffer: FramebufferInfo,
memory_map: []MemoryMapEntry,

pub const FramebufferInfo = struct {
    slice: []u8,
    width: usize,
    height: usize,
};

pub const MemoryMapEntry = struct {
    type: Type,
    start: usize,
    length: usize,

    pub const Type = enum {
        unknown,
        usable,
        loader_and_kernel,
        acpi,
        nvs,
        mmio,
        reserved,
    };
};
