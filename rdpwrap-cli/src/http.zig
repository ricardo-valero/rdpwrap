// Shared HTTPS-fetch wrapper around std.http.Client.
//
// Both `update` (fetches a fresh rdpwrap.ini) and `pdb-fetch` (downloads a
// PDB from Microsoft's symbol server) want the same thing: open an HTTPS
// connection with system trust roots, stream the body somewhere, surface
// the status. The "somewhere" differs — update buffers into memory so it
// can validate before writing, pdb-fetch streams directly to a file because
// PDBs can be tens of megabytes.

const std = @import("std");

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    response_writer: *std.Io.Writer,
) !std.http.Status {
    var client: std.http.Client = .{
        .allocator = gpa,
        .io = io,
    };
    defer client.deinit();

    const now = std.Io.Timestamp.now(io, .real);
    try client.ca_bundle.rescan(gpa, io, now);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = response_writer,
    });
    return result.status;
}
