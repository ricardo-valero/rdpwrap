// Resolve %ProgramFiles% from the inherited environment.

const std = @import("std");

const Map = std.process.Environ.Map;

pub fn programFiles(arena: std.mem.Allocator, environ: *const Map) ![]const u8 {
    if (environ.get("ProgramFiles")) |v| return arena.dupe(u8, v);
    // Fallback for very old systems / corrupted env.
    return arena.dupe(u8, "C:\\Program Files");
}

pub fn systemRoot(arena: std.mem.Allocator, environ: *const Map) ![]const u8 {
    if (environ.get("SystemRoot")) |v| return arena.dupe(u8, v);
    return arena.dupe(u8, "C:\\Windows");
}

pub fn join(arena: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(arena, parts);
}
