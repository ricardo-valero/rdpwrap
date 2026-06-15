// Apply one INI section's patches to a loaded module.
//
// Walks the section's keys looking for two patch shapes:
//
//   `<Family>Patch.<arch>=1`   — write the hex bytes from `[PatchCodes]`
//                                at the given offset (byte patch).
//   `<Family>Hook.<arch>=1`    — install a JMP trampoline at the given
//                                offset that redirects to a function
//                                exported from rdpwrap.dll (hook patch).
//
// In both cases the page is briefly flipped to PAGE_EXECUTE_READWRITE via
// VirtualProtect, the write happens, and the original protection is
// restored.

const std = @import("std");
const c = @import("win/c.zig");
const ini_mod = @import("ini.zig");
const patcher = @import("patcher.zig");
const log = @import("dll_log.zig");

pub const Stats = struct {
    applied: u32 = 0,
    skipped: u32 = 0,
    failed: u32 = 0,
};

/// Apply all enabled byte/hook patches from `section` to the module mapped
/// at `base` of size `code_size`. Per-patch failures are logged but do not
/// stop the loop. `self_module` is the rdpwrap.dll HMODULE — used to resolve
/// hook function addresses via GetProcAddress.
pub fn applySection(
    base: [*]u8,
    code_size: u32,
    section: *const ini_mod.Section,
    ini: *const ini_mod.Ini,
    arch: patcher.Arch,
    self_module: c.HMODULE,
    scratch: std.mem.Allocator,
) Stats {
    var stats: Stats = .{};
    const arch_suffix: []const u8 = if (arch == .x64) ".x64" else ".x86";

    var it = section.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.endsWith(u8, key, arch_suffix)) continue;
        const bare = key[0 .. key.len - arch_suffix.len];

        if (std.mem.endsWith(u8, bare, "Patch")) {
            const family = bare[0 .. bare.len - "Patch".len];
            if (!std.mem.eql(u8, entry.value_ptr.*, "1")) {
                stats.skipped += 1;
                continue;
            }
            applyByteFamily(base, code_size, section, ini, family, arch, scratch) catch |e| {
                logPatchError("patch", family, e);
                stats.failed += 1;
                continue;
            };
            stats.applied += 1;
        } else if (std.mem.endsWith(u8, bare, "Hook")) {
            const family = bare[0 .. bare.len - "Hook".len];
            if (!std.mem.eql(u8, entry.value_ptr.*, "1")) {
                stats.skipped += 1;
                continue;
            }
            applyHookFamily(base, code_size, section, ini, family, arch, self_module, scratch) catch |e| {
                logPatchError("hook", family, e);
                stats.failed += 1;
                continue;
            };
            stats.applied += 1;
        }
    }

    return stats;
}

fn logPatchError(kind: []const u8, family: []const u8, e: anyerror) void {
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "  {s} '{s}' failed: {s}",
        .{ kind, family, @errorName(e) },
    ) catch "  patch failed";
    log.line(msg);
}

fn applyByteFamily(
    base: [*]u8,
    code_size: u32,
    section: *const ini_mod.Section,
    ini: *const ini_mod.Ini,
    family: []const u8,
    arch: patcher.Arch,
    scratch: std.mem.Allocator,
) !void {
    const ini_arch: ini_mod.Arch = if (arch == .x64) .x64 else .x86;

    const off_key = try std.mem.concat(scratch, u8, &.{ family, "Offset" });
    const offset = (try ini.getHex(section.name, off_key, ini_arch, scratch)) orelse
        return error.MissingOffset;

    const code_key = try std.mem.concat(scratch, u8, &.{ family, "Code" });
    const code_name = (try ini.getValue(section.name, code_key, ini_arch, scratch)) orelse
        return error.MissingCode;
    const hex = (try ini.getValue("PatchCodes", code_name, .any, scratch)) orelse
        return error.UnknownPatchCode;

    var decoded: [64]u8 = undefined;
    const bytes = try patcher.decodeHex(&decoded, hex);

    if (offset + bytes.len > code_size) return error.OffsetOutOfRange;
    const off_usize: usize = @intCast(offset);

    const target_ptr: *anyopaque = @ptrCast(base + off_usize);
    var old_protect: c.DWORD = 0;
    if (c.VirtualProtect(target_ptr, bytes.len, c.PAGE_EXECUTE_READWRITE, &old_protect) == .FALSE)
        return error.VirtualProtectFailed;

    const module_slice: []u8 = base[0..code_size];
    try patcher.applyBytes(module_slice, off_usize, bytes);

    var dummy: c.DWORD = 0;
    _ = c.VirtualProtect(target_ptr, bytes.len, old_protect, &dummy);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "  patch '{s}' @ {x} ({d}b)",
        .{ family, offset, bytes.len },
    ) catch "  patched";
    log.line(msg);
}

fn applyHookFamily(
    base: [*]u8,
    code_size: u32,
    section: *const ini_mod.Section,
    ini: *const ini_mod.Ini,
    family: []const u8,
    arch: patcher.Arch,
    self_module: c.HMODULE,
    scratch: std.mem.Allocator,
) !void {
    const ini_arch: ini_mod.Arch = if (arch == .x64) .x64 else .x86;

    const off_key = try std.mem.concat(scratch, u8, &.{ family, "Offset" });
    const offset = (try ini.getHex(section.name, off_key, ini_arch, scratch)) orelse
        return error.MissingOffset;

    const func_key = try std.mem.concat(scratch, u8, &.{ family, "Func" });
    const func_name = (try ini.getValue(section.name, func_key, ini_arch, scratch)) orelse
        return error.MissingFunc;

    // GetProcAddress needs a null-terminated C string. INI values aren't, so
    // copy into a stack buffer with the null appended.
    var name_buf: [128]u8 = undefined;
    if (func_name.len + 1 > name_buf.len) return error.FuncNameTooLong;
    @memcpy(name_buf[0..func_name.len], func_name);
    name_buf[func_name.len] = 0;

    const hook_proc = c.GetProcAddress(self_module, @ptrCast(&name_buf)) orelse
        return error.HookNotExported;
    const hook_addr: u64 = @intFromPtr(hook_proc);

    const trampoline_size: usize = if (arch == .x64) 12 else 6;
    if (offset + trampoline_size > code_size) return error.OffsetOutOfRange;
    const off_usize: usize = @intCast(offset);

    const target_ptr: *anyopaque = @ptrCast(base + off_usize);
    var old_protect: c.DWORD = 0;
    if (c.VirtualProtect(target_ptr, trampoline_size, c.PAGE_EXECUTE_READWRITE, &old_protect) == .FALSE)
        return error.VirtualProtectFailed;

    const module_slice: []u8 = base[0..code_size];
    _ = try patcher.applyJmp(module_slice, off_usize, hook_addr, arch);

    var dummy: c.DWORD = 0;
    _ = c.VirtualProtect(target_ptr, trampoline_size, old_protect, &dummy);

    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "  hook '{s}' @ {x} -> {s} ({d}b trampoline)",
        .{ family, offset, func_name, trampoline_size },
    ) catch "  hook installed";
    log.line(msg);
}
