const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const Overlapper = @import("overlapper.zig").Overlapper;

pub const Error = std.os.MMapError || std.os.TruncateError || error{
    mem_fail,
};

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

        pub fn new() Error!Self {
            comptime var overlapper: Overlapper = switch (@import("builtin").link_libc) {
                true => Overlapper.libc,
                false => Overlapper.native,
            };

            const base = try overlapper.overlap(size);

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

        pub fn write_fd(self: *Self, fd: std.os.fd_t) !usize {
            const buf = self.buffer();

            const written = try std.os.write(fd, buf);

            self.state.read += @intCast(written);
            self.state.read &= MASK;

            return written;
        }

        pub fn read_fd(self: *Self, fd: std.os.fd_t) !usize {
            var end = (self.state.read + size - 1) & MASK;
            if (end < self.state.write) {
                end += size;
            }

            const r = try std.os.read(fd, self.base[self.state.write..end]);

            self.state.write += @intCast(r);
            self.state.write &= MASK;

            return r;
        }
    };
}

const invariant = error{ read_out_of_range, write_out_of_range, not_inverted, inverted, not_empty };

fn check_invariant(comptime size: u32, mirror: Mirror(size)) invariant!void {
    if (mirror.state.read >= size) {
        return invariant.read_out_of_range;
    }

    if (mirror.state.write >= size) {
        return invariant.write_out_of_range;
    }
}

const Orientation = enum {
    Std,
    Inv,
    Empty,

    fn check(self: @This(), comptime size: u32, mirror: Mirror(size)) invariant!void {
        switch (self) {
            .Std => {
                if (mirror.state.write < mirror.state.read) {
                    return invariant.inverted;
                }
            },

            .Inv => {
                if (mirror.state.read < mirror.state.write) {
                    return invariant.not_inverted;
                }
            },

            .Empty => {
                if (mirror.state.read != mirror.state.write) {
                    return invariant.not_empty;
                }
            },
        }
    }
};

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
    try Orientation.Std.check(4096, mirror);

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
    try Orientation.Inv.check(4096, mirror);

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
    try Orientation.Std.check(4096, mirror);

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
    try Orientation.Inv.check(4096, mirror);

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
    try Orientation.Inv.check(4096, mirror);

    try testing.expectEqual(mirror.base[4094..4098], mirror.buffer());

    try testing.expect(mirror.drop(2));
    try check_invariant(4096, mirror);
}

test "writting to fd" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    const mem_fd = try std.os.memfd_create("mirror-write", 0);
    defer std.os.close(mem_fd);

    const buf = [_]u8{ 0xfe, 0xed, 0xfa, 0xce };
    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);
    try Orientation.Std.check(4096, mirror);

    const len = try mirror.write_fd(mem_fd);
    try testing.expectEqual(4, len);
    try check_invariant(4096, mirror);
    try Orientation.Std.check(4096, mirror);

    try std.os.lseek_SET(mem_fd, 0);

    var mem_out: [16]u8 = undefined;

    const r = try std.os.read(mem_fd, &mem_out);

    try testing.expectEqual(4, r);

    try testing.expectEqualSlices(u8, &buf, mem_out[0..4]);
}

test "writting to fd in wrap around case" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 4094, .write = 4094 };

    const mem_fd = try std.os.memfd_create("mirror-write-wrap", 0);
    defer std.os.close(mem_fd);

    const buf = [_]u8{ 0xfe, 0xed, 0xfa, 0xce };
    try testing.expect(mirror.write(&buf));
    try check_invariant(4096, mirror);
    try Orientation.Inv.check(4096, mirror);

    const len = try mirror.write_fd(mem_fd);
    try testing.expectEqual(4, len);
    try check_invariant(4096, mirror);
    try Orientation.Empty.check(4096, mirror);

    try std.os.lseek_SET(mem_fd, 0);

    var mem_out: [16]u8 = undefined;

    const r = try std.os.read(mem_fd, &mem_out);

    try testing.expectEqual(4, r);

    try testing.expectEqualSlices(u8, &buf, mem_out[0..4]);
}

test "reading from fd" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    const mem_fd = try std.os.memfd_create("mirror-read", 0);
    defer std.os.close(mem_fd);

    const buf = [_]u8{ 0xfe, 0xed, 0xfa, 0xce };

    _ = try std.os.write(mem_fd, &buf);
    try std.os.lseek_SET(mem_fd, 0);

    const r = try mirror.read_fd(mem_fd);
    try check_invariant(0x1000, mirror);
    try Orientation.Std.check(0x1000, mirror);

    try testing.expectEqual(4, r);

    try testing.expectEqualSlices(u8, &buf, mirror.buffer());
}

test "reading from fd in wrap around case" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.state = state_t{ .read = 4094, .write = 4094 };
    const mem_fd = try std.os.memfd_create("mirror-read-wrap", 0);
    defer std.os.close(mem_fd);

    const buf = [_]u8{ 0xfe, 0xed, 0xfa, 0xce };

    _ = try std.os.write(mem_fd, &buf);
    try std.os.lseek_SET(mem_fd, 0);

    const r = try mirror.read_fd(mem_fd);
    try check_invariant(0x1000, mirror);
    try Orientation.Inv.check(0x1000, mirror);

    try testing.expectEqual(4, r);

    try testing.expectEqualSlices(u8, &buf, mirror.buffer());
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

test "mirror property" {
    var mirror = try Mirror(4096).new();
    defer mirror.close();

    mirror.base[0] = 0;
    try testing.expectEqual(0, mirror.base[0]);
    try testing.expectEqual(0, mirror.base[4096]);

    mirror.base[0] = 42;
    try testing.expectEqual(42, mirror.base[0]);
    try testing.expectEqual(42, mirror.base[4096]);
}
