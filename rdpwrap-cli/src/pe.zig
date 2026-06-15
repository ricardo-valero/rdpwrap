// Minimal PE (Portable Executable) parser. We only need one piece of
// information: the size of the .text region inside a loaded module, so the
// patcher can sanity-check that an INI offset lies inside it before writing.
//
// The DLL gets a HMODULE from `LoadLibrary("termsrv.dll")`, which on Windows
// is the loaded module's base address — i.e., a pointer to its DOS header
// in memory. We read SizeOfCode from the optional header.
//
// Layout we walk (offsets in bytes, from module base):
//
//   0x00   IMAGE_DOS_HEADER       starts with "MZ"
//   0x3C    e_lfanew (i32)        offset of the PE header
//   N      "PE\0\0"               4-byte signature
//   N+4    IMAGE_FILE_HEADER      20 bytes
//   N+24   IMAGE_OPTIONAL_HEADER  starts with magic (PE32 = 0x10B, PE32+ = 0x20B)
//          + SizeOfCode at offset 4 inside the optional header
//
// References:
//   https://learn.microsoft.com/en-us/windows/win32/debug/pe-format

const std = @import("std");

pub const Error = error{
    NotPe,
    UnknownArch,
    BufferTooSmall,
};

pub const Arch = enum { x86, x64 };

pub const Info = struct {
    arch: Arch,
    /// Size of the code region from the optional header. Byte patches and
    /// hook trampolines must land within this many bytes of the base —
    /// anything beyond means the offset is malformed (or the wrong INI
    /// section for this build).
    size_of_code: u32,
    /// Total size of the mapped image. Data-style offsets (e.g. the SLInit
    /// field addresses, which live in .data) are bounded by this, not by
    /// `size_of_code`.
    size_of_image: u32,
};

const DOS_MAGIC: u16 = 0x5A4D; // 'MZ'
const PE_SIGNATURE: u32 = 0x00004550; // 'PE\0\0'
const PE32_MAGIC: u16 = 0x010B;
const PE32PLUS_MAGIC: u16 = 0x020B;

/// Parse the headers of a PE image starting at `base`. The image is read as
/// raw bytes; this works on both file-on-disk PEs and loaded-in-memory PEs
/// because the headers occupy contiguous bytes from the module base in both
/// representations.
pub fn parse(image: []const u8) Error!Info {
    if (image.len < 0x40) return Error.BufferTooSmall;
    if (readU16(image, 0) != DOS_MAGIC) return Error.NotPe;

    const lfanew_signed = std.mem.readInt(i32, image[0x3C..0x40], .little);
    if (lfanew_signed < 0) return Error.NotPe;
    const pe_off: usize = @intCast(lfanew_signed);

    // Need: 4 (sig) + 20 (file header) + 60 (through SizeOfImage at opt+56)
    if (pe_off + 4 + 20 + 60 > image.len) return Error.BufferTooSmall;
    if (readU32(image, pe_off) != PE_SIGNATURE) return Error.NotPe;

    const opt_off = pe_off + 4 + 20;
    const magic = readU16(image, opt_off);
    const arch: Arch = switch (magic) {
        PE32_MAGIC => .x86,
        PE32PLUS_MAGIC => .x64,
        else => return Error.UnknownArch,
    };

    // SizeOfCode is at offset 4 inside the optional header (same in PE32 and PE32+).
    // SizeOfImage is at offset 56 (same in both — the offset is anchored to the
    // start of the Windows-specific fields, which differ in length between PE32
    // and PE32+, but Microsoft kept SizeOfImage aligned at 56 either way).
    const size_of_code = readU32(image, opt_off + 4);
    const size_of_image = readU32(image, opt_off + 56);

    return .{ .arch = arch, .size_of_code = size_of_code, .size_of_image = size_of_image };
}

inline fn readU16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}

inline fn readU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a minimal valid PE header buffer for testing. Mirrors the actual
/// on-disk / in-memory layout closely enough for the parser, but is just a
/// flat byte buffer with the relevant fields set.
fn synthPe(comptime arch: Arch, size_of_code: u32) [0x100]u8 {
    var buf: [0x100]u8 = std.mem.zeroes([0x100]u8);
    // DOS magic.
    std.mem.writeInt(u16, buf[0..2], DOS_MAGIC, .little);
    // e_lfanew → PE header at 0x40.
    std.mem.writeInt(i32, buf[0x3C..0x40], 0x40, .little);
    // PE signature.
    std.mem.writeInt(u32, buf[0x40..0x44], PE_SIGNATURE, .little);
    // FileHeader: zero-filled is fine for parsing.
    // OptionalHeader at 0x40 + 4 + 20 = 0x58.
    const magic: u16 = switch (arch) {
        .x86 => PE32_MAGIC,
        .x64 => PE32PLUS_MAGIC,
    };
    std.mem.writeInt(u16, buf[0x58..0x5A], magic, .little);
    // SizeOfCode at OptionalHeader + 4 = 0x5C.
    std.mem.writeInt(u32, buf[0x5C..0x60], size_of_code, .little);
    // SizeOfImage at OptionalHeader + 56 = 0x90. Tests use 8x size_of_code
    // so they don't have to think about a separate parameter.
    std.mem.writeInt(u32, buf[0x90..0x94], size_of_code *| 8, .little);
    return buf;
}

test "parse: PE32+ (x64)" {
    const img = synthPe(.x64, 0x12345);
    const info = try parse(&img);
    try testing.expectEqual(Arch.x64, info.arch);
    try testing.expectEqual(@as(u32, 0x12345), info.size_of_code);
}

test "parse: PE32 (x86)" {
    const img = synthPe(.x86, 0xABCD);
    const info = try parse(&img);
    try testing.expectEqual(Arch.x86, info.arch);
    try testing.expectEqual(@as(u32, 0xABCD), info.size_of_code);
}

test "parse: rejects non-MZ input" {
    var img: [0x100]u8 = std.mem.zeroes([0x100]u8);
    img[0] = 'X';
    img[1] = 'Y';
    try testing.expectError(Error.NotPe, parse(&img));
}

test "parse: rejects bad PE signature" {
    var img = synthPe(.x64, 1);
    // Corrupt the signature.
    img[0x40] = 0;
    try testing.expectError(Error.NotPe, parse(&img));
}

test "parse: rejects unknown arch magic" {
    var img = synthPe(.x64, 1);
    std.mem.writeInt(u16, img[0x58..0x5A], 0xDEAD, .little);
    try testing.expectError(Error.UnknownArch, parse(&img));
}

test "parse: short buffer" {
    const tiny: [16]u8 = std.mem.zeroes([16]u8);
    try testing.expectError(Error.BufferTooSmall, parse(&tiny));
}

test "parse: e_lfanew points past buffer" {
    var img = synthPe(.x64, 1);
    std.mem.writeInt(i32, img[0x3C..0x40], 0x10000, .little);
    try testing.expectError(Error.BufferTooSmall, parse(&img));
}
