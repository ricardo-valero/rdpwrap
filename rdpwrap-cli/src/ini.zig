// rdpwrap.ini parser. Format:
//
//   ; line comment
//   [SectionName]                    -- arbitrary name, often a 4-part version
//   Key=Value                        -- one per line
//   Key.x64=Value                    -- arch-suffixed: looked up by .x64 / .x86
//
// No quoting, no escapes, no inline comments — values run to end of line.
// CRLF and LF both accepted; trailing whitespace per line is trimmed.
//
// Used by both rdpwrap-cli (for status / update) and rdpwrap.dll (for
// runtime patching). Lookups are case-sensitive — that's how the upstream
// INI is authored, and the dll runs against fixed strings.

const std = @import("std");

pub const Arch = enum { any, x86, x64 };

pub const Section = struct {
    name: []const u8,
    /// Map from key (e.g. "LocalOnlyOffset.x64") to value ("92A81").
    /// All slices reference bytes inside `Ini.raw`.
    entries: std.StringHashMapUnmanaged([]const u8) = .empty,
};

pub const Ini = struct {
    arena: std.mem.Allocator,
    raw: []const u8,
    sections: std.ArrayListUnmanaged(Section) = .empty,
    section_index: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(_: *Ini) void {
        // Everything is arena-allocated; caller deinits the arena.
    }

    pub fn hasSection(self: *const Ini, name: []const u8) bool {
        return self.section_index.contains(name);
    }

    pub fn getSection(self: *const Ini, name: []const u8) ?*const Section {
        const idx = self.section_index.get(name) orelse return null;
        return &self.sections.items[idx];
    }

    /// Look up a value, optionally with an arch suffix. Tries `key.<arch>`
    /// first when `arch != .any`, then bare `key`.
    pub fn getValue(
        self: *const Ini,
        section: []const u8,
        key: []const u8,
        arch: Arch,
        scratch: std.mem.Allocator,
    ) !?[]const u8 {
        const sec = self.getSection(section) orelse return null;
        if (arch != .any) {
            const suffix: []const u8 = if (arch == .x64) ".x64" else ".x86";
            const suffixed = try std.mem.concat(scratch, u8, &.{ key, suffix });
            if (sec.entries.get(suffixed)) |v| return v;
        }
        return sec.entries.get(key);
    }

    /// Hex value (no `0x` prefix in upstream INI, e.g. `A059B`). Returns null
    /// when the key is missing; returns error.InvalidHex on a malformed value.
    pub fn getHex(
        self: *const Ini,
        section: []const u8,
        key: []const u8,
        arch: Arch,
        scratch: std.mem.Allocator,
    ) !?u64 {
        const v = (try self.getValue(section, key, arch, scratch)) orelse return null;
        return std.fmt.parseInt(u64, v, 16) catch error.InvalidHex;
    }

    /// Treats the value as a boolean: "1" / "true" → true, "0" / "false" /
    /// missing → false. Anything else → error.InvalidBool.
    pub fn getBool(
        self: *const Ini,
        section: []const u8,
        key: []const u8,
        arch: Arch,
        scratch: std.mem.Allocator,
    ) !bool {
        const v = (try self.getValue(section, key, arch, scratch)) orelse return false;
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) return true;
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) return false;
        return error.InvalidBool;
    }
};

pub fn parse(arena: std.mem.Allocator, raw: []const u8) !Ini {
    var ini: Ini = .{ .arena = arena, .raw = raw };

    var current: ?*Section = null;
    var line_iter = std.mem.splitAny(u8, raw, "\r\n");
    while (line_iter.next()) |line_raw| {
        const line = trimSpaces(line_raw);
        if (line.len == 0) continue;
        if (line[0] == ';' or line[0] == '#') continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.UnterminatedSection;
            const name = line[1..close];
            try ini.sections.append(arena, .{ .name = name });
            const idx = ini.sections.items.len - 1;
            current = &ini.sections.items[idx];
            const gop = try ini.section_index.getOrPut(arena, name);
            // Last definition wins on duplicate sections. Mirrors the C++.
            gop.value_ptr.* = idx;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const sec = current orelse continue; // value before any section — skip
        const key = trimSpaces(line[0..eq]);
        const val = trimSpaces(line[eq + 1 ..]);
        if (key.len == 0) continue;
        try sec.entries.put(arena, key, val);
    }

    return ini;
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const fixture = @embedFile("testdata/sample.ini");

test "parse: section discovery" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    try testing.expect(ini.hasSection("Main"));
    try testing.expect(ini.hasSection("SLPolicy"));
    try testing.expect(ini.hasSection("PatchCodes"));
    try testing.expect(ini.hasSection("10.0.26100.7623"));
    try testing.expect(ini.hasSection("10.0.26100.7623-SLInit"));
    try testing.expect(!ini.hasSection("does-not-exist"));
}

test "parse: comments and blank lines ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena,
        \\; comment at top
        \\
        \\[A]
        \\; comment in section
        \\x=1
        \\
        \\[B]
        \\y=2
        \\
    );
    try testing.expect(ini.hasSection("A"));
    try testing.expect(ini.hasSection("B"));
    try testing.expectEqualStrings("1", ini.getSection("A").?.entries.get("x").?);
    try testing.expectEqualStrings("2", ini.getSection("B").?.entries.get("y").?);
}

test "getValue: arch-suffixed keys win over bare keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    const v = (try ini.getValue("10.0.26100.7623", "LocalOnlyOffset", .x64, arena)).?;
    try testing.expectEqualStrings("92A81", v);

    // Win7 fixture has both arches present.
    const x86 = (try ini.getValue("6.1.7601.17514", "LocalOnlyOffset", .x86, arena)).?;
    const x64 = (try ini.getValue("6.1.7601.17514", "LocalOnlyOffset", .x64, arena)).?;
    try testing.expectEqualStrings("10A89", x86);
    try testing.expectEqualStrings("18193", x64);
}

test "getValue: bare key fallback when arch suffix missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    // [Main] keys have no arch suffix — should return regardless of arch query.
    const v = (try ini.getValue("Main", "Updated", .x64, arena)).?;
    try testing.expectEqualStrings("2026-01-25", v);
}

test "getHex: parses no-prefix hex" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    const off = (try ini.getHex("10.0.26100.7623", "LocalOnlyOffset", .x64, arena)).?;
    try testing.expectEqual(@as(u64, 0x92A81), off);
}

test "getBool: 1 / 0 / missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    try testing.expect(try ini.getBool("10.0.26100.7623", "LocalOnlyPatch", .x64, arena));
    try testing.expect(try ini.getBool("Main", "SLPolicyHookNT60", .any, arena));
    // Missing key → false (not an error — see contract).
    try testing.expect(!try ini.getBool("Main", "DoesNotExist", .any, arena));
}

test "PatchCodes: byte sequences are preserved verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, fixture);
    try testing.expectEqualStrings("90", (try ini.getValue("PatchCodes", "nop", .any, arena)).?);
    try testing.expectEqualStrings("EB", (try ini.getValue("PatchCodes", "jmpshort", .any, arena)).?);
    try testing.expectEqualStrings(
        "B8010000009090",
        (try ini.getValue("PatchCodes", "mov_eax_1_nop_2", .any, arena)).?,
    );
}

test "duplicate section: last definition wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena,
        \\[A]
        \\x=1
        \\[A]
        \\x=2
        \\
    );
    try testing.expectEqualStrings("2", ini.getSection("A").?.entries.get("x").?);
}

test "value before any section is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena,
        \\stray=value
        \\[A]
        \\x=1
        \\
    );
    try testing.expect(ini.hasSection("A"));
    try testing.expectEqualStrings("1", ini.getSection("A").?.entries.get("x").?);
}

test "CRLF line endings handled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ini = try parse(arena, "[A]\r\nx=1\r\n[B]\r\ny=2\r\n");
    try testing.expect(ini.hasSection("A"));
    try testing.expect(ini.hasSection("B"));
    try testing.expectEqualStrings("1", ini.getSection("A").?.entries.get("x").?);
    try testing.expectEqualStrings("2", ini.getSection("B").?.entries.get("y").?);
}
