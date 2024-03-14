const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const state_t = packed struct {
    read: u32,
    write: u32,

    fn len(self: @This(), comptime size: u32) u32 {
        const MASK: u32 = size - 1;

        return (self.write + size - self.read) & MASK;
    }

    fn neg(self: @This(), comptime size: u32) u32 {
        const MASK: u32 = size - 1;
        return (self.read + size - (self.write + 1)) & MASK;
    }
};

/// Not thread safe
///
/// I wanted a thread save version but could not garentee writer safety,
/// and thread saftey is not needed for my purposes
pub fn Mirror(comptime size: u32) type {
    const FULL: usize = 2 * @as(usize, size);
    const MASK: u32 = size - 1;

    if (@popCount(size) != 1) {
        @compileError("Mirror needs a power of 2 size to work");
    }

    if (size < std.mem.page_size) {
        @compileError("Need a size that is at least a page for a mirror");
    }

    if (@bitSizeOf(usize) != 64) {
        @compileError("Mirror is written for a 64 bit machine");
    }

    return struct {
        const Self = @This();

        base: []align(std.mem.page_size) u8,
        state: state_t,

        pub fn new() !Self {
            const fd = try std.os.memfd_create("mirror", std.os.MFD.CLOEXEC);
            try std.os.ftruncate(fd, size);

            const base = try std.os.mmap(
                null,
                FULL,
                std.os.PROT.READ | std.os.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            );

            _ = try std.os.mmap(
                @ptrCast(base),
                size,
                std.os.PROT.READ | std.os.PROT.WRITE,
                .{
                    .TYPE = .PRIVATE,
                },
                fd,
                0,
            );

            const b: [*]align(std.mem.page_size) u8 = @ptrCast(base);

            _ = try std.os.mmap(
                b + size,
                size,
                std.os.PROT.READ | std.os.PROT.WRITE,
                .{
                    .TYPE = .PRIVATE,
                },
                fd,
                0,
            );

            return Self{
                .base = base,
                .state = .{ .read = 0, .write = 0 },
            };
        }

        pub fn len(self: *const Self) usize {
            return self.state.len(size);
        }

        pub fn close(self: Self) void {
            std.os.munmap(self.base);
        }

        pub fn buffer(self: *Self) []u8 {
            var end = self.state.write;

            if (end < self.state.read) {
                end += size;
            }

            return self.base[self.state.read..end];
        }

        pub fn read(self: *Self, buf: []u8) bool {
            if (buf.len > self.state.len(size)) {
                return false;
            }

            const start = self.state.read;

            self.state.read += @intCast(buf.len);

            const end = self.state.read;

            std.mem.copyForwards(u8, buf, self.base[start..end]);

            self.state.read &= MASK;

            return true;
        }

        pub fn drop(self: *Self, num: usize) bool {
            if (num > self.state.len(size)) {
                return false;
            }

            self.state.read += @intCast(num);
            self.state.read &= MASK;

            return true;
        }

        pub fn write(self: *Self, buf: []const u8) bool {
            if (buf.len > self.state.neg(size)) {
                return false;
            }

            const start = self.state.write;
            self.state.write += @intCast(buf.len);
            const end = self.state.write;

            std.mem.copyForwards(u8, self.base[start..end], buf);

            self.state.write &= MASK;

            return true;
        }
    };
}

const invariant = error{
    read_out_of_range,
    write_out_of_range,
};

fn check_invariant(comptime size: u32, mirror: Mirror(size)) invariant!void {
    if (mirror.state.read >= size) {
        return invariant.read_out_of_range;
    }

    if (mirror.state.write >= size) {
        return invariant.write_out_of_range;
    }
}

test "mirror basic usage" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    try testing.expectEqual(0, mirror.len());

    const buf = [_]u8{ 1, 2, 3, 4 };
    var out_buf: [4]u8 = undefined;

    try testing.expect(mirror.write(&buf));
    try testing.expectEqual(state_t{ .read = 0, .write = 4 }, mirror.state);
    try testing.expectEqualSlices(u8, mirror.base[0..4], &buf);
    try check_invariant(4096, mirror);

    try testing.expect(mirror.read(&out_buf));
    try testing.expectEqual(state_t{ .read = 4, .write = 4 }, mirror.state);
    try testing.expectEqualSlices(u8, &buf, &out_buf);
    try check_invariant(4096, mirror);
}

test "mirror wrap around usage" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 4094, .write = 4094 };

    try testing.expectEqual(0, mirror.len());

    const buf = [_]u8{ 1, 2, 3, 4 };
    var out_buf: [4]u8 = undefined;

    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);

    try testing.expectEqual(state_t{ .read = 4094, .write = 2 }, mirror.state);
    try testing.expectEqualSlices(u8, mirror.base[4094..4098], &buf);

    try testing.expect(mirror.read(&out_buf));
    try check_invariant(4096, mirror);
    try testing.expectEqual(state_t{ .read = 2, .write = 2 }, mirror.state);
    try testing.expectEqualSlices(u8, &buf, &out_buf);
}

test "contiguos buffer view in plain case" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 17, .write = 17 };

    try testing.expectEqual(0, mirror.len());

    const buf = [_]u8{ 1, 2, 3, 4 };

    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);

    try testing.expectEqual(mirror.base[17..21], mirror.buffer());
}

test "contiguos buffer view in wrap around case" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 4094, .write = 4094 };

    try testing.expectEqual(0, mirror.len());

    const buf = [_]u8{ 1, 2, 3, 4 };

    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);

    try testing.expectEqual(mirror.base[4094..4098], mirror.buffer());
}

// you may have already read the data by .buffer()
test "intentional drop data" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 4094, .write = 4094 };
    try testing.expectEqual(0, mirror.len());

    const buf = [_]u8{ 0xfe, 0xed, 0xfa, 0xce };

    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);

    try testing.expectEqual(mirror.base[4094..4098], mirror.buffer());

    try testing.expect(mirror.drop(2));
    try check_invariant(4096, mirror);
}

test "mirror length" {
    var state = state_t{ .read = 0, .write = 0 };
    try testing.expectEqual(0, state.len(4096));
    try testing.expectEqual(4095, state.neg(4096));

    state = state_t{ .read = 0, .write = 4 };
    try testing.expectEqual(4, state.len(4096));
    try testing.expectEqual(4091, state.neg(4096));

    state = state_t{ .read = 4000, .write = 1 };
    try testing.expectEqual(97, state.len(4096));
    try testing.expectEqual(3998, state.neg(4096));

    state = state_t{ .read = 4000, .write = 1 };
    try testing.expectEqual(4193, state.len(0x2000));
    try testing.expectEqual(3998, state.neg(0x2000));
}
