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
    SymbolUrlTooLong,
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
    /// `size_of_image`.
    size_of_image: u32,
};

/// CodeView debug info pointing at the PDB on Microsoft's symbol server.
/// All three fields together form the symbol-server lookup key.
pub const DebugInfo = struct {
    /// 16-byte GUID, as it sits in the PE — first three sub-fields are
    /// little-endian-encoded integers (a u32 and two u16s); last 8 bytes
    /// are a flat sequence.
    guid: [16]u8,
    /// Age — bumped whenever the PDB is rebuilt for the same binary.
    age: u32,
    /// PDB file name as authored at link time (usually a basename like
    /// "termsrv.pdb"). Slice references the caller's image buffer.
    pdb_name: []const u8,
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

/// Walk the PE debug directory and return the CodeView PDB7 (RSDS) info if
/// any. Returns null when the binary has no debug directory or no RSDS entry
/// inside it. Designed for a file-on-disk view of the image; we walk the
/// section table to translate the debug-directory RVA into a file offset.
pub fn parseDebugInfo(image: []const u8) Error!?DebugInfo {
    if (image.len < 0x40) return Error.BufferTooSmall;
    if (readU16(image, 0) != DOS_MAGIC) return Error.NotPe;
    const lfanew_signed = std.mem.readInt(i32, image[0x3C..0x40], .little);
    if (lfanew_signed < 0) return Error.NotPe;
    const pe_off: usize = @intCast(lfanew_signed);

    if (pe_off + 4 + 20 > image.len) return Error.BufferTooSmall;
    if (readU32(image, pe_off) != PE_SIGNATURE) return Error.NotPe;

    const file_header_off = pe_off + 4;
    const num_sections = readU16(image, file_header_off + 2);
    const size_opt_header = readU16(image, file_header_off + 16);
    const opt_off = file_header_off + 20;

    if (opt_off + 2 > image.len) return Error.BufferTooSmall;
    const magic = readU16(image, opt_off);

    // Data Directory array starts at different offsets in PE32 vs PE32+.
    const dd_off: usize = switch (magic) {
        PE32_MAGIC => opt_off + 96,
        PE32PLUS_MAGIC => opt_off + 112,
        else => return Error.UnknownArch,
    };

    // Entry 6 (IMAGE_DIRECTORY_ENTRY_DEBUG) = { VirtualAddress, Size }.
    const debug_dd_off = dd_off + 6 * 8;
    if (debug_dd_off + 8 > image.len) return Error.BufferTooSmall;
    const debug_va = readU32(image, debug_dd_off);
    const debug_size = readU32(image, debug_dd_off + 4);
    if (debug_va == 0 or debug_size == 0) return null;

    const sect_off = opt_off + size_opt_header;
    const debug_file_off = rvaToFileOffset(image, sect_off, num_sections, debug_va) orelse return null;

    // Walk IMAGE_DEBUG_DIRECTORY entries (28 bytes each).
    const num_entries: usize = debug_size / 28;
    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        const entry_off = debug_file_off + i * 28;
        if (entry_off + 28 > image.len) break;
        const dbg_type = readU32(image, entry_off + 12);
        if (dbg_type != 2) continue; // IMAGE_DEBUG_TYPE_CODEVIEW
        const dbg_data_size = readU32(image, entry_off + 16);
        const dbg_data_rva = readU32(image, entry_off + 20);
        const dbg_data_file = readU32(image, entry_off + 24);

        // Prefer PointerToRawData when set; some toolchains leave the RVA
        // pointing to nothing useful for the debug payload.
        const cv_off: usize = if (dbg_data_file != 0)
            @intCast(dbg_data_file)
        else
            (rvaToFileOffset(image, sect_off, num_sections, dbg_data_rva) orelse continue);

        if (cv_off + 24 > image.len) continue;

        // CV_INFO_PDB70: 'RSDS' (4) + GUID (16) + Age (4) + PdbFileName (NUL-term).
        if (readU32(image, cv_off) != 0x53445352) continue; // 'RSDS' little-endian

        var guid: [16]u8 = undefined;
        @memcpy(&guid, image[cv_off + 4 ..][0..16]);
        const age = readU32(image, cv_off + 20);

        const name_start = cv_off + 24;
        const cv_end = cv_off + dbg_data_size;
        const search_end = @min(cv_end, image.len);
        if (name_start >= search_end) continue;
        const name_rel = std.mem.indexOfScalar(u8, image[name_start..search_end], 0) orelse continue;

        return .{
            .guid = guid,
            .age = age,
            .pdb_name = image[name_start .. name_start + name_rel],
        };
    }
    return null;
}

/// Format the Microsoft symbol-server URL for a CodeView debug info. Layout:
///   https://msdl.microsoft.com/download/symbols/<pdb>/<GUID_no_dashes_upper><age_hex>/<pdb>
/// The first three GUID sub-fields are read as little-endian integers and
/// rendered big-endian (the usual Windows GUID-string convention); the
/// trailing 8 bytes are emitted in order. Age is hex without padding.
pub fn formatSymbolUrl(out: []u8, info: DebugInfo) Error![]u8 {
    const g = info.guid;
    const d1 = std.mem.readInt(u32, g[0..4], .little);
    const d2 = std.mem.readInt(u16, g[4..6], .little);
    const d3 = std.mem.readInt(u16, g[6..8], .little);

    return std.fmt.bufPrint(
        out,
        "https://msdl.microsoft.com/download/symbols/{s}/{X:0>8}{X:0>4}{X:0>4}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X}/{s}",
        .{
            info.pdb_name,
            d1, d2,    d3,
            g[8],      g[9],
            g[10],     g[11],
            g[12],     g[13],
            g[14],     g[15],
            info.age,
            info.pdb_name,
        },
    ) catch Error.SymbolUrlTooLong;
}

fn rvaToFileOffset(image: []const u8, sect_off: usize, num_sections: u16, rva: u32) ?usize {
    var i: u16 = 0;
    while (i < num_sections) : (i += 1) {
        const sh = sect_off + @as(usize, i) * 40;
        if (sh + 40 > image.len) return null;
        const va = readU32(image, sh + 12);
        const vsize = readU32(image, sh + 8);
        const raw_ptr = readU32(image, sh + 20);
        if (rva >= va and rva < va + vsize) {
            return @as(usize, @intCast(raw_ptr)) + (rva - va);
        }
    }
    return null;
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

test "formatSymbolUrl: known GUID + age" {
    // GUID bytes laid out as on disk: data1 LE, data2 LE, data3 LE, then 8 raw.
    // Source GUID for the expected string {3F1C8E5A-2B4D-7E9F-8A6B-5C4D3E2F1A0B}:
    //   data1 = 0x3F1C8E5A → LE bytes 5A 8E 1C 3F
    //   data2 = 0x2B4D     → LE bytes 4D 2B
    //   data3 = 0x7E9F     → LE bytes 9F 7E
    //   trailing 8 = 8A 6B 5C 4D 3E 2F 1A 0B
    const info: DebugInfo = .{
        .guid = .{ 0x5A, 0x8E, 0x1C, 0x3F, 0x4D, 0x2B, 0x9F, 0x7E, 0x8A, 0x6B, 0x5C, 0x4D, 0x3E, 0x2F, 0x1A, 0x0B },
        .age = 1,
        .pdb_name = "termsrv.pdb",
    };
    var buf: [256]u8 = undefined;
    const url = try formatSymbolUrl(&buf, info);
    try testing.expectEqualStrings(
        "https://msdl.microsoft.com/download/symbols/termsrv.pdb/3F1C8E5A2B4D7E9F8A6B5C4D3E2F1A0B1/termsrv.pdb",
        url,
    );
}

test "formatSymbolUrl: age hex without padding" {
    const info: DebugInfo = .{
        .guid = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 },
        .age = 0x2A,
        .pdb_name = "foo.pdb",
    };
    var buf: [256]u8 = undefined;
    const url = try formatSymbolUrl(&buf, info);
    try testing.expect(std.mem.endsWith(u8, url, "2A/foo.pdb"));
}
