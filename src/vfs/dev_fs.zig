const logger = std.log.scoped(.devfs);

const root = @import("root");
const std = @import("std");

const debug = @import("../debug.zig");
const vfs = @import("../vfs.zig");
const utils = @import("../utils.zig");
const ps2 = @import("../drivers/ps2.zig");
const ram_fs = @import("ram_fs.zig");

const tty_vtable: vfs.VNodeVTable = .{
    .read = TtyVNode.read,
    .write = TtyVNode.write,
};

var disk_number: usize = 1;

const BlockDeviceError = error{
    InputOutput,
};

const BlockDeviceVTable = struct {
    read_block: fn (self: *BlockDevice, block: usize, buffer: []u8) BlockDeviceError!void,
    write_block: fn (self: *BlockDevice, block: usize, buffer: []const u8) BlockDeviceError!void,
};

const BlockDevice = struct {
    vnode: vfs.VNode,
    vtable: *const BlockDeviceVTable,
    sector_size: usize,
    sector_count: usize,
    name: [24]u8 = undefined,

    const vnode_vtable: vfs.VNodeVTable = .{
        .read = BlockDevice.read,
        .write = BlockDevice.write,
    };

    fn iterateSectors(
        self: *@This(),
        buffer_in: anytype,
        disk_offset_in: usize,
        small_callback: anytype,
        large_callback: anytype,
    ) !void {
        if (buffer_in.len == 0) {
            return;
        }

        var first_sector = utils.alignDown(usize, disk_offset_in, self.sector_size) / self.sector_size;
        var last_sector = utils.alignDown(usize, disk_offset_in + buffer_in.len - 1, self.sector_size) / self.sector_size;

        if (first_sector == last_sector) {
            return small_callback(self, buffer_in, first_sector, disk_offset_in % self.sector_size);
        }

        var disk_offset = disk_offset_in;
        var buffer = buffer_in;

        if (!utils.isAligned(usize, disk_offset, self.sector_size)) {
            const step = utils.alignUp(usize, disk_offset, self.sector_size) - disk_offset;

            try small_callback(self, buffer[0..step], first_sector, self.sector_size - step);

            buffer = buffer[step..];
            disk_offset += step;
            first_sector += 1;
        }

        while (buffer.len >= self.sector_size) {
            try large_callback(self, buffer[0..self.sector_size], first_sector);

            buffer = buffer[self.sector_size..];
            disk_offset += self.sector_size;
            first_sector += 1;
        }

        if (buffer.len == 0) {
            return;
        }

        try small_callback(self, buffer, first_sector, 0);
    }

    fn doLargeRead(self: *BlockDevice, buffer: []u8, sector: usize) !void {
        return self.vtable.read_block(self, sector, buffer);
    }

    fn doLargeWrite(self: *BlockDevice, buffer: []const u8, sector: usize) !void {
        return self.vtable.write_block(self, sector, buffer);
    }

    fn doSmallRead(self: *BlockDevice, buffer: []u8, sector: usize, offset: usize) !void {
        var temp_buffer: [512]u8 = undefined;

        try self.vtable.read_block(self, sector, &temp_buffer);

        std.mem.copy(u8, buffer, temp_buffer[offset..][0..buffer.len]);
    }

    fn doSmallWrite(self: *BlockDevice, buffer: []const u8, sector: usize, offset: usize) !void {
        var temp_buffer: [512]u8 = undefined;

        try self.vtable.read_block(self, sector, &temp_buffer);

        std.mem.copy(u8, temp_buffer[offset..][0..buffer.len], buffer);

        try self.vtable.write_block(self, sector, &temp_buffer);
    }

    fn read(vnode: *vfs.VNode, buffer: []u8, offset: usize) vfs.ReadError!usize {
        const self = @fieldParentPtr(BlockDevice, "vnode", vnode);

        try self.iterateSectors(buffer, offset, doSmallRead, doLargeRead);

        return buffer.len;
    }

    fn write(vnode: *vfs.VNode, buffer: []const u8, offset: usize) vfs.WriteError!usize {
        const self = @fieldParentPtr(BlockDevice, "vnode", vnode);

        try self.iterateSectors(buffer, offset, doSmallWrite, doLargeWrite);

        return buffer.len;
    }
};

fn BlockDeviceWrapper(comptime T: type) type {
    return struct {
        block: BlockDevice,
        device: T,

        const block_vtable: BlockDeviceVTable = .{
            .read_block = @This().readBlock,
            .write_block = @This().writeBlock,
        };

        fn readBlock(block_dev: *BlockDevice, block: usize, buffer: []u8) BlockDeviceError!void {
            const self = @fieldParentPtr(@This(), "block", block_dev);

            try self.device.readBlock(block, buffer);
        }

        fn writeBlock(block_dev: *BlockDevice, block: usize, buffer: []const u8) BlockDeviceError!void {
            const self = @fieldParentPtr(@This(), "block", block_dev);

            try self.device.writeBlock(block, buffer);
        }
    };
}

const PartitionBlockDeviceWrapper = struct {
    block: BlockDevice,
    parent: *BlockDevice,
    start_block: usize,
    end_block: usize,

    const block_vtable: BlockDeviceVTable = .{
        .read_block = @This().readBlock,
        .write_block = @This().writeBlock,
    };

    fn readBlock(block_dev: *BlockDevice, block: usize, buffer: []u8) BlockDeviceError!void {
        const self = @fieldParentPtr(@This(), "block", block_dev);

        std.debug.assert(self.start_block + block < self.end_block);

        return self.parent.vtable.read_block(self.parent, self.start_block + block, buffer);
    }

    fn writeBlock(block_dev: *BlockDevice, block: usize, buffer: []const u8) BlockDeviceError!void {
        const self = @fieldParentPtr(@This(), "block", block_dev);

        std.debug.assert(self.start_block + block < self.end_block);

        return self.parent.vtable.write_block(self.parent, self.start_block + block, buffer);
    }
};

const TtyVNode = struct {
    vnode: vfs.VNode,

    fn read(vnode: *vfs.VNode, buffer: []u8, offset: usize) vfs.ReadError!usize {
        _ = vnode;
        _ = offset;

        while (true) {
            const event = ps2.getKeyboardEvent();

            if (!event.pressed) {
                continue;
            }

            const shift = ps2.keyboard_state.isShiftPressed();
            const ascii: u8 = switch (event.location) {
                .Number1 => if (shift) @as(u8, '!') else '1',
                .Number2 => if (shift) @as(u8, '@') else '2',
                .Number3 => if (shift) @as(u8, '#') else '3',
                .Number4 => if (shift) @as(u8, '$') else '4',
                .Number5 => if (shift) @as(u8, '%') else '5',
                .Number6 => if (shift) @as(u8, '^') else '6',
                .Number7 => if (shift) @as(u8, '&') else '7',
                .Number8 => if (shift) @as(u8, '*') else '8',
                .Number9 => if (shift) @as(u8, '(') else '9',
                .Number0 => if (shift) @as(u8, ')') else '0',
                .RightOf0 => if (shift) @as(u8, '_') else '-',
                .LeftOfBackspace => if (shift) @as(u8, '+') else '=',
                .Line1n1 => if (shift) @as(u8, 'Q') else 'q',
                .Line1n2 => if (shift) @as(u8, 'W') else 'w',
                .Line1n3 => if (shift) @as(u8, 'E') else 'e',
                .Line1n4 => if (shift) @as(u8, 'R') else 'r',
                .Line1n5 => if (shift) @as(u8, 'T') else 't',
                .Line1n6 => if (shift) @as(u8, 'Y') else 'y',
                .Line1n7 => if (shift) @as(u8, 'U') else 'u',
                .Line1n8 => if (shift) @as(u8, 'I') else 'i',
                .Line1n9 => if (shift) @as(u8, 'O') else 'o',
                .Line1n10 => if (shift) @as(u8, 'P') else 'p',
                .Line1n11 => if (shift) @as(u8, '{') else '[',
                .Line1n12 => if (shift) @as(u8, '}') else ']',
                .Line1n13 => if (shift) @as(u8, '|') else '\\',
                .Line2n1 => if (shift) @as(u8, 'A') else 'a',
                .Line2n2 => if (shift) @as(u8, 'S') else 's',
                .Line2n3 => if (shift) @as(u8, 'D') else 'd',
                .Line2n4 => if (shift) @as(u8, 'F') else 'f',
                .Line2n5 => if (shift) @as(u8, 'G') else 'g',
                .Line2n6 => if (shift) @as(u8, 'H') else 'h',
                .Line2n7 => if (shift) @as(u8, 'J') else 'j',
                .Line2n8 => if (shift) @as(u8, 'K') else 'k',
                .Line2n9 => if (shift) @as(u8, 'L') else 'l',
                .Line2n10 => if (shift) @as(u8, ':') else ';',
                .Line2n11 => if (shift) @as(u8, '"') else '\'',
                .Enter => return 0,
                .Line3n1 => if (shift) @as(u8, 'Z') else 'z',
                .Line3n2 => if (shift) @as(u8, 'X') else 'x',
                .Line3n3 => if (shift) @as(u8, 'C') else 'c',
                .Line3n4 => if (shift) @as(u8, 'V') else 'v',
                .Line3n5 => if (shift) @as(u8, 'B') else 'b',
                .Line3n6 => if (shift) @as(u8, 'N') else 'n',
                .Line3n7 => if (shift) @as(u8, 'M') else 'm',
                .Line3n8 => if (shift) @as(u8, '<') else ',',
                .Line3n9 => if (shift) @as(u8, '>') else '.',
                .Line3n10 => if (shift) @as(u8, '?') else '/',
                .Spacebar => @as(u8, ' '),
                else => continue,
            };

            logger.debug("{} => {c}", .{ event, ascii });

            buffer[0] = ascii;
            return 1;
        }
    }

    fn write(vnode: *vfs.VNode, buffer: []const u8, offset: usize) vfs.WriteError!usize {
        _ = vnode;
        _ = offset;

        const km_buffer = try root.allocator.dupe(u8, buffer);

        defer root.allocator.free(km_buffer);

        debug.print(km_buffer);

        return buffer.len;
    }
};

pub fn init(name: []const u8, parent: ?*vfs.VNode) !*vfs.VNode {
    const ramfs = try ram_fs.init(name, parent);
    const tty = try root.allocator.create(TtyVNode);

    ramfs.filesystem.name = "DevFS";

    tty.* = .{
        .vnode = .{
            .vtable = &tty_vtable,
            .filesystem = ramfs.filesystem,
            .name = "tty",
        },
    };

    try ramfs.insert(&tty.vnode);

    return ramfs;
}

pub fn addDiskBlockDevice(name: []const u8, device: anytype) !void {
    const WrappedDevice = BlockDeviceWrapper(@TypeOf(device));

    const dev = try vfs.resolve(null, "/dev", 0);
    const node = try root.allocator.create(WrappedDevice);
    const disk_id = @atomicRmw(usize, &disk_number, .Add, 1, .AcqRel);

    node.* = .{
        .block = .{
            .vnode = undefined,
            .vtable = &WrappedDevice.block_vtable,
            .sector_size = device.getSectorSize(),
            .sector_count = device.getSectorCount(),
        },
        .device = device,
    };

    node.block.vnode = .{
        .vtable = &BlockDevice.vnode_vtable,
        .filesystem = dev.filesystem,
        .name = try std.fmt.bufPrint(&node.block.name, "{s}{d}", .{ name, disk_id }),
    };

    try dev.insert(&node.block.vnode);
    try probePartitions(&node.block, node.block.sector_size);
}

const MbrHeader = extern struct {
    reserved0: [510]u8,
    magic: u16,
};

const GptHeader = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved14: [4]u8,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: std.os.uefi.Guid,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_of_partition_entry: u32,
    partition_entry_array_crc32: u32,
};

const GptPartitionEntry = extern struct {
    partition_type_guid: std.os.uefi.Guid,
    unique_partition_guid: std.os.uefi.Guid,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64,
    name: [36]u16,
};

fn probePartitions(device: *BlockDevice, sector_size: usize) !void {
    var buffer = try root.allocator.alloc(u8, sector_size * 2);

    _ = try device.vnode.read(buffer, 0);

    const dev = try vfs.resolve(null, "/dev", 0);
    const mbr_header = @ptrCast(*align(1) const MbrHeader, buffer);
    const gpt_header = @ptrCast(*align(1) const GptHeader, buffer[512..]);

    if (std.mem.eql(u8, &gpt_header.signature, "EFI PART") and gpt_header.revision == 0x10000) {
        var entry: GptPartitionEntry = undefined;

        for (utils.range(10)) |_, i| {
            _ = try device.vnode.read(
                std.mem.asBytes(&entry),
                gpt_header.partition_entry_lba * sector_size + i * gpt_header.size_of_partition_entry,
            );

            if (entry.starting_lba == 0) {
                break;
            }

            const part_node = try root.allocator.create(PartitionBlockDeviceWrapper);

            part_node.* = .{
                .block = .{
                    .vnode = undefined,
                    .vtable = &PartitionBlockDeviceWrapper.block_vtable,
                    .sector_size = device.sector_size,
                    .sector_count = entry.ending_lba - entry.starting_lba + 1,
                },
                .parent = device,
                .start_block = entry.starting_lba,
                .end_block = entry.ending_lba + 1,
            };

            part_node.block.vnode = .{
                .vtable = &BlockDevice.vnode_vtable,
                .filesystem = dev.filesystem,
                .name = try std.fmt.bufPrint(&part_node.block.name, "{s}p{d}", .{ device.vnode.name, i + 1 }),
            };

            try dev.insert(&part_node.block.vnode);

            logger.debug(
                "{}: Added partition with start LBA of {} and end LBA of {}",
                .{ part_node.block.vnode.getFullPath(), entry.starting_lba, entry.ending_lba },
            );
        }
    } else if (mbr_header.magic == 0xaa55) {
        logger.debug("{}: MBR partition table detected", .{device.vnode.getFullPath()});
    } else {
        logger.debug("{}: No partition table detected", .{device.vnode.getFullPath()});
    }
}
