/// Decodificação do setor Master Boot Record (MBR).
/// Este módulo não realiza I/O: recebe bytes e interpreta os campos manualmente.

pub const sector_size: usize = 512;
pub const partition_table_offset: usize = 446;
pub const partition_entry_size: usize = 16;
pub const partition_count: usize = 4;

pub const Partition = struct {
    boot_flag: u8,
    chs_start: [3]u8,
    type_code: u8,
    chs_end: [3]u8,
    lba_start: u32,
    sector_count: u32,
    /// Só é true se todos os 16 bytes da entrada forem zero.
    empty: bool,
};

pub const Mbr = struct {
    disk_signature: u32,
    signature_valid: bool,
    partitions: [partition_count]Partition,
};

pub fn readLe32(bytes: []const u8) u32 {
    // Os chamadores passam uma fatia de pelo menos 4 bytes.
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

pub fn parse(bytes: []const u8) error{TruncatedSector}!Mbr {
    if (bytes.len < sector_size) return error.TruncatedSector;

    var partitions: [partition_count]Partition = undefined;
    for (0..partition_count) |index| {
        const start = partition_table_offset + index * partition_entry_size;
        const raw = bytes[start .. start + partition_entry_size];
        var empty = true;
        for (raw) |byte| {
            if (byte != 0) {
                empty = false;
                break;
            }
        }

        partitions[index] = .{
            .boot_flag = raw[0],
            .chs_start = .{ raw[1], raw[2], raw[3] },
            .type_code = raw[4],
            .chs_end = .{ raw[5], raw[6], raw[7] },
            .lba_start = readLe32(raw[8..12]),
            .sector_count = readLe32(raw[12..16]),
            .empty = empty,
        };
    }

    return .{
        .disk_signature = readLe32(bytes[440..444]),
        .signature_valid = bytes[510] == 0x55 and bytes[511] == 0xAA,
        .partitions = partitions,
    };
}

/// Nome amigável para alguns códigos históricos do tipo MBR.
/// O código é uma indicação, não uma confirmação do sistema de arquivos.
pub fn typeName(code: u8) []const u8 {
    return switch (code) {
        0x01 => "FAT12",
        0x04 => "FAT16 (menor que 32 MiB)",
        0x05 => "partição estendida (CHS)",
        0x06 => "FAT16",
        0x07 => "HPFS/NTFS/exFAT",
        0x0B => "FAT32 (CHS)",
        0x0C => "FAT32 (LBA)",
        0x0E => "FAT16 (LBA)",
        0x0F => "partição estendida (LBA)",
        0x82 => "Linux swap",
        0x83 => "Linux",
        0x85 => "partição estendida Linux",
        0xEE => "MBR protetor de GPT",
        else => "desconhecido",
    };
}

pub fn isSpecialPartitionType(code: u8) bool {
    return code == 0x05 or code == 0x0F or code == 0x85 or code == 0xEE;
}

fn writeLe32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn freshSector() [sector_size]u8 {
    var bytes = [_]u8{0} ** sector_size;
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    return bytes;
}

fn setEntry(bytes: *[sector_size]u8, index: usize, boot_flag: u8, type_code: u8, lba_start: u32, sectors: u32) void {
    const start = partition_table_offset + index * partition_entry_size;
    bytes[start] = boot_flag;
    bytes[start + 4] = type_code;
    writeLe32(bytes[start + 8 ..][0..4], lba_start);
    writeLe32(bytes[start + 12 ..][0..4], sectors);
}

test "converte little-endian para 2048" {
    try @import("std").testing.expectEqual(@as(u32, 2048), readLe32(&[_]u8{ 0x00, 0x08, 0x00, 0x00 }));
}

test "MBR válido sem partições" {
    const bytes = freshSector();
    const parsed = try parse(&bytes);
    try @import("std").testing.expect(parsed.signature_valid);
    try @import("std").testing.expectEqual(@as(u32, 0), parsed.disk_signature);
    for (parsed.partitions) |partition| try @import("std").testing.expect(partition.empty);
}

test "decodifica uma partição válida" {
    var bytes = freshSector();
    setEntry(&bytes, 0, 0x80, 0x83, 2048, 204800);
    const parsed = try parse(&bytes);
    const partition = parsed.partitions[0];
    try @import("std").testing.expect(!partition.empty);
    try @import("std").testing.expectEqual(@as(u8, 0x80), partition.boot_flag);
    try @import("std").testing.expectEqual(@as(u8, 0x83), partition.type_code);
    try @import("std").testing.expectEqual(@as(u32, 2048), partition.lba_start);
    try @import("std").testing.expectEqual(@as(u32, 204800), partition.sector_count);
}

test "interpreta as quatro entradas da tabela" {
    var bytes = freshSector();
    for (0..partition_count) |index| {
        setEntry(&bytes, index, 0, 0x83, @as(u32, @intCast(index + 1)), 1);
    }
    const parsed = try parse(&bytes);
    for (parsed.partitions, 0..) |partition, index| {
        try @import("std").testing.expect(!partition.empty);
        try @import("std").testing.expectEqual(@as(u32, @intCast(index + 1)), partition.lba_start);
    }
}

test "assinatura inválida é reconhecida sem impedir a decodificação" {
    var bytes = freshSector();
    bytes[511] = 0;
    const parsed = try parse(&bytes);
    try @import("std").testing.expect(!parsed.signature_valid);
}

test "setor truncado é rejeitado" {
    const bytes = [_]u8{0} ** (sector_size - 1);
    try @import("std").testing.expectError(error.TruncatedSector, parse(&bytes));
}

test "uma entrada com campos preenchidos não é considerada vazia" {
    var bytes = freshSector();
    setEntry(&bytes, 0, 0, 0, 0, 1);
    const parsed = try parse(&bytes);
    try @import("std").testing.expect(!parsed.partitions[0].empty);
}
