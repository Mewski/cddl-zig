//! Runtime sources, for writing a self-contained copy of the runtime next to
//! generated codecs. Paths are relative to the runtime directory; the root
//! module is `root_path`.

pub const File = struct {
    path: []const u8,
    contents: []const u8,
};

pub const root_path = "cddl_runtime.zig";

pub const files = [_]File{
    .{ .path = "cddl_runtime.zig", .contents = @embedFile("cddl_runtime.zig") },
    .{ .path = "canonical.zig", .contents = @embedFile("canonical.zig") },
    .{ .path = "decoder.zig", .contents = @embedFile("decoder.zig") },
    .{ .path = "embed.zig", .contents = @embedFile("embed.zig") },
    .{ .path = "encoder.zig", .contents = @embedFile("encoder.zig") },
    .{ .path = "errors.zig", .contents = @embedFile("errors.zig") },
    .{ .path = "float.zig", .contents = @embedFile("float.zig") },
    .{ .path = "head.zig", .contents = @embedFile("head.zig") },
    .{ .path = "value.zig", .contents = @embedFile("value.zig") },
};

test "every runtime file is embedded" {
    const std = @import("std");
    try std.testing.expectEqualStrings(root_path, files[0].path);
    for (files) |file| try std.testing.expect(file.contents.len != 0);
}
