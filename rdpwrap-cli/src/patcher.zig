// In-process patcher. Pure byte operations — the DLL wraps these with
// VirtualProtect + WriteProcessMemory at runtime, but the LOGIC (offset
// math, trampoline encoding, bounds checking) is testable in isolation.
//
// Two patch shapes the upstream INI uses:
//
//   1. Byte patches — write a fixed sequence of bytes at a known offset.
//      The byte string comes from the INI's `[PatchCodes]` section as a
//      hex string (e.g. `B8010000009090`). `decodeHex` turns that into a
//      byte buffer; `applyBytes` writes it.
//
//   2. JMP trampolines — inline 5-instruction redirect from a patched
//      offset to an absolute address (a hook function in our DLL). Two
//      arch-specific shapes (Fusix's FARJMP):
//
//        x64 (12 bytes):   48 B8 <8-byte addr>  50  C3
//                          ────  ─────────────  ──  ──
//                          mov   rax, addr      push ret
//                                                rax
//
//        x86 (6 bytes):    68 <4-byte addr>  C3
//                          ──  ──────────── ──
//                          push addr        ret

const std = @import("std");

pub const Error = error{
    OffsetOutOfRange,
    OddHexLength,
    InvalidHexDigit,
};

pub const Arch = enum { x86, x64 };

/// Write `bytes` at `offset` inside `buf`. Caller has already made the
/// memory region writable (VirtualProtect on the DLL side) and validated
/// that `offset` is inside the loaded image's code region.
pub fn applyBytes(buf: []u8, offset: usize, bytes: []const u8) Error!void {
    if (offset > buf.len or bytes.len > buf.len - offset) return Error.OffsetOutOfRange;
    @memcpy(buf[offset..][0..bytes.len], bytes);
}

/// Encode and write a JMP trampoline to `target_addr` at `offset` inside
/// `buf`. Returns the number of bytes written (12 for x64, 6 for x86) so
/// callers can chain or verify.
pub fn applyJmp(
    buf: []u8,
    offset: usize,
    target_addr: u64,
    arch: Arch,
) Error!usize {
    return switch (arch) {
        .x64 => blk: {
            if (offset > buf.len or 12 > buf.len - offset) return Error.OffsetOutOfRange;
            buf[offset + 0] = 0x48;
            buf[offset + 1] = 0xB8;
            std.mem.writeInt(u64, buf[offset + 2 ..][0..8], target_addr, .little);
            buf[offset + 10] = 0x50;
            buf[offset + 11] = 0xC3;
            break :blk 12;
        },
        .x86 => blk: {
            if (offset > buf.len or 6 > buf.len - offset) return Error.OffsetOutOfRange;
            const addr32: u32 = @truncate(target_addr);
            buf[offset + 0] = 0x68;
            std.mem.writeInt(u32, buf[offset + 1 ..][0..4], addr32, .little);
            buf[offset + 5] = 0xC3;
            break :blk 6;
        },
    };
}

/// Decode a hex byte sequence string (no separators, even length, no `0x`
/// prefix — e.g. `"B8010000009090"`) into a byte buffer. Used to convert
/// upstream INI `[PatchCodes]` values into the bytes `applyBytes` writes.
pub fn decodeHex(out: []u8, hex: []const u8) Error![]u8 {
    if (hex.len % 2 != 0) return Error.OddHexLength;
    const n = hex.len / 2;
    if (out.len < n) return Error.OffsetOutOfRange;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const hi = try nibble(hex[i * 2]);
        const lo = try nibble(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out[0..n];
}

fn nibble(c: u8) Error!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => Error.InvalidHexDigit,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeHex: PatchCodes values" {
    var out: [16]u8 = undefined;

    const nop = try decodeHex(&out, "90");
    try testing.expectEqualSlices(u8, &.{0x90}, nop);

    const jmpshort = try decodeHex(&out, "EB");
    try testing.expectEqualSlices(u8, &.{0xEB}, jmpshort);

    const mov = try decodeHex(&out, "B8010000009090");
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90 }, mov);

    // Lowercase accepted.
    const lower = try decodeHex(&out, "b8010000009090");
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0x90, 0x90 }, lower);
}

test "decodeHex: errors" {
    var out: [16]u8 = undefined;
    try testing.expectError(Error.OddHexLength, decodeHex(&out, "ABC"));
    try testing.expectError(Error.InvalidHexDigit, decodeHex(&out, "ZZ"));
}

test "applyBytes: writes at offset" {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    try applyBytes(&buf, 4, &.{ 0xDE, 0xAD, 0xBE, 0xEF });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF }, buf[0..8]);
}

test "applyBytes: out of range" {
    var buf: [4]u8 = undefined;
    try testing.expectError(Error.OffsetOutOfRange, applyBytes(&buf, 2, &.{ 0xAA, 0xBB, 0xCC }));
}

test "applyJmp: x64 trampoline shape" {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const written = try applyJmp(&buf, 4, 0x0123456789ABCDEF, .x64);
    try testing.expectEqual(@as(usize, 12), written);

    // Bytes preceding the patch are untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, buf[0..4]);
    // The trampoline.
    try testing.expectEqual(@as(u8, 0x48), buf[4]);
    try testing.expectEqual(@as(u8, 0xB8), buf[5]);
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), std.mem.readInt(u64, buf[6..14], .little));
    try testing.expectEqual(@as(u8, 0x50), buf[14]);
    try testing.expectEqual(@as(u8, 0xC3), buf[15]);
    // Remainder untouched.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, buf[16..32]);
}

test "applyJmp: x86 trampoline shape" {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    const written = try applyJmp(&buf, 2, 0xCAFEBABE, .x86);
    try testing.expectEqual(@as(usize, 6), written);
    try testing.expectEqual(@as(u8, 0x68), buf[2]);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, buf[3..7], .little));
    try testing.expectEqual(@as(u8, 0xC3), buf[7]);
}

test "applyJmp: x86 truncates 64-bit address" {
    var buf: [16]u8 = std.mem.zeroes([16]u8);
    _ = try applyJmp(&buf, 0, 0xDEADBEEF_CAFEBABE, .x86);
    // Only the low 32 bits should be written.
    try testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, buf[1..5], .little));
}

test "applyJmp: out of range" {
    var buf: [10]u8 = undefined;
    try testing.expectError(Error.OffsetOutOfRange, applyJmp(&buf, 0, 0, .x64)); // needs 12, has 10
    try testing.expectError(Error.OffsetOutOfRange, applyJmp(&buf, 5, 0, .x86)); // needs 6 from offset 5, has 5
}

test "end-to-end: decode + apply (mimics one INI patch)" {
    // Simulates: section says LocalOnlyOffset=8, LocalOnlyCode=jmpshort.
    // PatchCodes section says jmpshort=EB. Result: byte 0xEB written at
    // module_base + 8 inside our fake "loaded module" buffer.
    var fake_module: [64]u8 = std.mem.zeroes([64]u8);
    var decoded: [8]u8 = undefined;
    const bytes = try decodeHex(&decoded, "EB");
    try applyBytes(&fake_module, 8, bytes);
    try testing.expectEqual(@as(u8, 0xEB), fake_module[8]);
    // Surrounding bytes untouched.
    try testing.expectEqual(@as(u8, 0), fake_module[7]);
    try testing.expectEqual(@as(u8, 0), fake_module[9]);
}
