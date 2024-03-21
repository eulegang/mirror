const std = @import("std");
const tag = @import("builtin").os.tag;

pub const Error = std.os.MMapError || std.os.TruncateError || error{
    mem_fail,
};

pub const Overlapper = enum {
    libc,
    native,

    pub fn overlap(comptime self: @This(), comptime size: usize) Error![]align(std.mem.page_size) u8 {
        switch (self) {
            .libc => {
                const fd = std.c.shm_open("mirror\x00", @bitCast(std.c.O{
                    .ACCMODE = .RDWR,
                    .CREAT = true,
                    .CLOEXEC = true,
                }), 0o0644);

                defer _ = std.c.close(fd);
                defer _ = std.c.shm_unlink("mirror\x00");

                if (fd == -1) {
                    return Error.mem_fail;
                }

                try std.os.ftruncate(fd, size);

                return map_region(size, fd);
            },

            .native => {
                switch (tag) {
                    .linux => {
                        const fd = std.os.memfd_create("mirror", std.os.MFD.CLOEXEC) catch return Error.mem_fail;
                        defer std.os.close(fd);

                        try std.os.ftruncate(fd, size);

                        return map_region(size, fd);
                    },

                    else => unreachable,
                }
            },
        }
    }
};

fn map_region(comptime size: usize, fd: std.os.fd_t) Error![]align(std.mem.page_size) u8 {
    const base = try std.os.mmap(
        null,
        2 * size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        .{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        },
        -1,
        0,
    );

    _ = try std.os.mmap(
        @ptrCast(base),
        size,
        std.os.PROT.READ | std.os.PROT.WRITE,
        .{
            .TYPE = .SHARED,
            .FIXED = true,
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
            .TYPE = .SHARED,
            .FIXED = true,
        },
        fd,
        0,
    );

    return base;
}
