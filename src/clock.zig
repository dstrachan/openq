//! The wall clock behind `.z.P` and the other `.z` time variables.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const q = @import("root.zig");
const literal = q.literal;

/// Nanoseconds from 1970.01.01, the Unix epoch, to 2000.01.01, q's epoch.
const epoch_offset: i96 = @as(i96, literal.epoch_days) * literal.ns_per_day;

/// Nanoseconds since 2000.01.01 UTC, read from the real-time clock.
pub fn now(io: Io) i64 {
    const stamp = Io.Timestamp.now(io, .real);
    return @intCast(stamp.nanoseconds - epoch_offset);
}

/// The local time zone, read from `/etc/localtime` once when the Vm starts, as q reads it
/// once at startup. Without one, or when it cannot be read, local time is UTC.
pub const LocalZone = union(enum) {
    utc,
    zone: std.tz.Tz,

    pub fn load(io: Io, gpa: Allocator) LocalZone {
        const bytes = Io.Dir.cwd().readFileAlloc(io, "/etc/localtime", gpa, .unlimited) catch return .utc;
        defer gpa.free(bytes);
        var reader: Io.Reader = .fixed(bytes);
        const tz = std.tz.Tz.parse(gpa, &reader) catch return .utc;
        return .{ .zone = tz };
    }

    pub fn deinit(self: *LocalZone) void {
        switch (self.*) {
            .zone => |*tz| tz.deinit(),
            .utc => {},
        }
        self.* = .utc;
    }

    /// The local offset from UTC in seconds at `utc_seconds` since 1970.01.01.
    pub fn offset(self: LocalZone, utc_seconds: i64) i64 {
        switch (self) {
            .zone => |tz| {
                // The rule in force is the last transition at or before the instant; before
                // the first transition it is the first time type, as the TZif format
                // specifies. Beyond the last transition the zone's footer rule would apply,
                // but system zone files carry transitions decades ahead, so the last one is
                // used instead.
                var timetype: ?*const std.tz.Timetype = null;
                for (tz.transitions) |transition| {
                    if (transition.ts > utc_seconds) break;
                    timetype = transition.timetype;
                }
                if (timetype == null and tz.timetypes.len > 0) timetype = &tz.timetypes[0];
                return if (timetype) |t| t.offset else 0;
            },
            .utc => return 0,
        }
    }
};

test "now is after 2026 and the local offset is whole minutes" {
    const nanos = now(std.testing.io);
    try std.testing.expect(nanos > 26 * 365 * literal.ns_per_day);

    var zone: LocalZone = .load(std.testing.io, std.testing.allocator);
    defer zone.deinit();
    const seconds = @divFloor(nanos, literal.ns_per_second) + literal.epoch_days * 86_400;
    const local = zone.offset(seconds);
    try std.testing.expect(@mod(local, 60) == 0);
    try std.testing.expect(local > -15 * 3600 and local < 15 * 3600);
}
