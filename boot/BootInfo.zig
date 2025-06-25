framebuffer: FramebufferInfo,

pub const FramebufferInfo = struct {
    slice: []u8,
    width: usize,
    height: usize,
};
