const logger = std.log.scoped(.utils);

const std = @import("std");

const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };

pub const BinarySize = struct {
    bytes: usize,

    pub fn init(bytes: usize) BinarySize {
        return .{ .bytes = bytes };
    }

    pub fn format(
        self: BinarySize,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        var i: usize = 0;
        var value = self.bytes;
        var unit = units[0];

        while (value >= 1024 and i + 1 < units.len) {
            value /= 1024;
            unit = units[i + 1];
            i += 1;
        }

        try writer.print("{d}{s}", .{ value, unit });
    }
};

pub fn kib(comptime value: comptime_int) comptime_int {
    return value * 1024;
}

pub fn mib(comptime value: comptime_int) comptime_int {
    return kib(value) * 1024;
}

pub fn gib(comptime value: comptime_int) comptime_int {
    return mib(value) * 1024;
}

pub fn tib(comptime value: comptime_int) comptime_int {
    return gib(value) * 1024;
}

pub fn alignDown(comptime T: type, value: T, comptime alignment: T) T {
    return value - (value % alignment);
}

pub fn alignUp(comptime T: type, value: T, comptime alignment: T) T {
    return alignDown(T, value + alignment - 1, alignment);
}

pub fn divRoundUp(comptime T: type, value: T, comptime alignment: T) T {
    return (value + (alignment - 1)) / alignment;
}

pub fn isAligned(comptime T: type, value: T, comptime alignment: T) bool {
    return alignDown(T, value, alignment) == value;
}

pub fn vital(value: anytype, comptime message: []const u8) @TypeOf(value catch unreachable) {
    return value catch |err| {
        logger.err("A vital check failed: {s}", .{@errorName(err)});

        std.debug.panicExtra(@errorReturnTrace(), message, .{});
    };
}
