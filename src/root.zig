pub const compiler = @import("compiler/root.zig");
pub const runtime_abi: u32 = 1;

test {
    _ = compiler;
}
