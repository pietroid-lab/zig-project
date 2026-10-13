/// Verificações de consistência sobre os dados já decodificados do MBR.
const mbr_mod = @import("mbr.zig");

pub const DiagnosticKind = enum {
    invalid_signature,
    unexpected_boot_flag,
    zero_sector_count,
    beyond_image,
    includes_lba0,
    overlapping,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    /// Número da entrada, começando em 1. Zero quando não se aplica.
    partition_a: u8 = 0,
    partition_b: u8 = 0,
};

pub const Report = struct {
    diagnostics: [32]Diagnostic = undefined,
    len: usize = 0,

    fn add(self: *Report, kind: DiagnosticKind, partition_a: u8, partition_b: u8) void {
        // Quatro entradas produzem no máximo 23 diagnósticos com as regras atuais.
        if (self.len < self.diagnostics.len) {
            self.diagnostics[self.len] = .{
                .kind = kind,
                .partition_a = partition_a,
                .partition_b = partition_b,
            };
            self.len += 1;
        }
    }

    pub fn items(self: *const Report) []const Diagnostic {
        return self.diagnostics[0..self.len];
    }
}

fn isDataPartition(partition: mbr_mod.Partition) bool {
    return !partition.empty and !mbr_mod.isSpecialPartitionType(partition.type_code);
}

pub fn validate(mbr: *const mbr_mod.Mbr, image_size_bytes: u64) Report {
    var report: Report = .{};
    if (!mbr.signature_valid) report.add(.invalid_signature, 0, 0);

    for (mbr.partitions, 0..) |partition, index| {
        if (partition.empty) continue;
        const partition_number: u8 = @intCast(index + 1);

        if (partition.boot_flag != 0x00 and partition.boot_flag != 0x80) {
            report.add(.unexpected_boot_flag, partition_number, 0);
        }

        if (partition.sector_count == 0) {
            report.add(.zero_sector_count, partition_number, 0);
            continue;
        }

        // LBA 0 contém o próprio MBR e não deve ser incluído por uma partição de dados.
        if (partition.lba_start == 0) {
            report.add(.includes_lba0, partition_number, 0);
        }

        // O limite superior exclusivo evita subtrações e mantém a aritmética em u64.
        const end_lba_exclusive = @as(u64, partition.lba_start) + @as(u64, partition.sector_count);
        const end_byte_exclusive = end_lba_exclusive * @as(u64, mbr_mod.sector_size);
        if (end_byte_exclusive > image_size_bytes) {
            report.add(.beyond_image, partition_number, 0);
        }
    }

    // Partições estendidas e o MBR protetor GPT não são intervalos de dados comuns.
    for (mbr.partitions, 0..) |a, i| {
        if (!isDataPartition(a) or a.sector_count == 0) continue;
        const a_start = @as(u64, a.lba_start);
        const a_end = a_start + @as(u64, a.sector_count) - 1;

        for (mbr.partitions[i + 1 ..], i + 1..) |b, j| {
            if (!isDataPartition(b) or b.sector_count == 0) continue;
            const b_start = @as(u64, b.lba_start);
            const b_end = b_start + @as(u64, b.sector_count) - 1;
            if (a_start <= b_end and b_start <= a_end) {
                report.add(.overlapping, @intCast(i + 1), @intCast(j + 1));
            }
        }
    }

    return report;
}

fn makeMbr(partitions: []const struct { boot: u8, kind: u8, start: u32, count: u32 }) mbr_mod.Mbr {
    var bytes = [_]u8{0} ** mbr_mod.sector_size;
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    for (partitions, 0..) |p, index| {
        const start = mbr_mod.partition_table_offset + index * mbr_mod.partition_entry_size;
        bytes[start] = p.boot;
        bytes[start + 4] = p.kind;
        writeLe32(bytes[start + 8 ..][0..4], p.start);
        writeLe32(bytes[start + 12 ..][0..4], p.count);
    }
    return mbr_mod.parse(&bytes) catch unreachable;
}

fn writeLe32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

fn has(report: *const Report, kind: DiagnosticKind) bool {
    for (report.items()) |diagnostic| {
        if (diagnostic.kind == kind) return true;
    }
    return false;
}

test "avisa sobre flag de boot inesperada" {
    const mbr = makeMbr(&.{.{ .boot = 0x7F, .kind = 0x83, .start = 1, .count = 2 }});
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(has(&report, .unexpected_boot_flag));
}

test "detecta intervalos sobrepostos de partições de dados" {
    const mbr = makeMbr(&.{
        .{ .boot = 0, .kind = 0x83, .start = 1, .count = 4 },
        .{ .boot = 0, .kind = 0x07, .start = 4, .count = 3 },
    });
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(has(&report, .overlapping));
}

test "detecta partição que ultrapassa o fim da imagem" {
    const mbr = makeMbr(&.{.{ .boot = 0, .kind = 0x83, .start = 6, .count = 6 }});
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(has(&report, .beyond_image));
}

test "detecta entrada preenchida com zero setores" {
    const mbr = makeMbr(&.{.{ .boot = 0, .kind = 0x83, .start = 10, .count = 0 }});
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(has(&report, .zero_sector_count));
}

test "detecta partição de dados que inclui o setor MBR" {
    const mbr = makeMbr(&.{.{ .boot = 0, .kind = 0x83, .start = 0, .count = 1 }});
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(has(&report, .includes_lba0));
}

test "tipos especiais não são tratados como partições de dados comuns para sobreposição" {
    const mbr = makeMbr(&.{
        .{ .boot = 0, .kind = 0x0F, .start = 1, .count = 4 },
        .{ .boot = 0, .kind = 0x83, .start = 2, .count = 2 },
    });
    const report = validate(&mbr, 4096);
    try @import("std").testing.expect(!has(&report, .overlapping));
}
