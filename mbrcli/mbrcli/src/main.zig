const std = @import("std");
const mbr_mod = @import("mbr.zig");
const validation = @import("validation.zig");

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.debug.print("Erro: não foi possível ler os argumentos do terminal.\n", .{});
        return 1;
    };

    if (args.len != 2) {
        std.debug.print("Uso: mbrcli caminho/para/disco.img\n", .{});
        return 2;
    }

    const image_path = args[1];
    const cwd = std.Io.Dir.cwd();

    // Pré-verificação do caminho evita abrir diretórios e dispositivos especiais.
    const path_stat = cwd.statFile(init.io, image_path, .{}) catch |err| {
        std.debug.print("Erro: não foi possível consultar '{s}': {s}.\n", .{ image_path, @errorName(err) });
        return 1;
    };
    if (path_stat.kind != .file) {
        std.debug.print("Erro: '{s}' não é um arquivo regular. Dispositivos e outros tipos de arquivo não são aceitos.\n", .{image_path});
        return 1;
    }

    const file = cwd.openFile(init.io, image_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Erro: não foi possível abrir '{s}' para leitura: {s}.\n", .{ image_path, @errorName(err) });
        return 1;
    };
    defer file.close(init.io);

    // Revalida o descritor antes de ler, caso o caminho tenha mudado após o stat.
    const file_stat = file.stat(init.io) catch |err| {
        std.debug.print("Erro: não foi possível consultar o tamanho de '{s}': {s}.\n", .{ image_path, @errorName(err) });
        return 1;
    };
    if (file_stat.kind != .file) {
        std.debug.print("Erro: '{s}' não aponta para um arquivo regular. Nada foi lido.\n", .{image_path});
        return 1;
    }
    if (file_stat.size < @as(u64, mbr_mod.sector_size)) {
        std.debug.print("Erro: '{s}' tem {d} bytes; uma imagem MBR precisa ter pelo menos 512 bytes.\n", .{ image_path, file_stat.size });
        return 1;
    }

    var sector: [mbr_mod.sector_size]u8 = undefined;
    const bytes_read = file.readPositionalAll(init.io, &sector, 0) catch |err| {
        std.debug.print("Erro: falha ao ler os primeiros 512 bytes de '{s}': {s}.\n", .{ image_path, @errorName(err) });
        return 1;
    };
    if (bytes_read != sector.len) {
        std.debug.print("Erro: leitura incompleta do setor MBR em '{s}' ({d}/512 bytes).\n", .{ image_path, bytes_read });
        return 1;
    }

    const parsed = mbr_mod.parse(&sector) catch {
        std.debug.print("Erro: setor MBR truncado.\n", .{});
        return 1;
    };

    printReport(image_path, &parsed, file_stat.size);
    return 0;
}

fn printReport(image_path: []const u8, parsed: *const mbr_mod.Mbr, image_size: u64) void {
    std.debug.print("MBR Inspector\nArquivo: {s}\nTamanho da imagem: {d} bytes\n", .{ image_path, image_size });
    if (parsed.signature_valid) {
        std.debug.print("Assinatura: válida (55 AA)\n", .{});
    } else {
        std.debug.print("Assinatura: INVÁLIDA (esperado 55 AA nos offsets 510–511)\n", .{});
    }
    std.debug.print("Identificador do disco: 0x{X:0>8}\n\n", .{parsed.disk_signature});

    var occupied_count: usize = 0;
    for (parsed.partitions, 0..) |partition, index| {
        if (partition.empty) {
            std.debug.print("Partição {d}: vazia\n", .{index + 1});
            continue;
        }
        occupied_count += 1;
        const boot_text = if (partition.boot_flag == 0x80) "sim" else if (partition.boot_flag == 0) "não" else "flag inválida";
        std.debug.print("\nPartição {d}\n", .{index + 1});
        std.debug.print("  Inicializável: {s} (flag 0x{X:0>2})\n", .{ boot_text, partition.boot_flag });
        std.debug.print("  Tipo: 0x{X:0>2} ({s})\n", .{ partition.type_code, mbr_mod.typeName(partition.type_code) });
        if (partition.type_code == 0xEE) {
            std.debug.print("  Observação: MBR protetor; a tabela GPT não é interpretada por este programa.\n", .{});
        } else if (partition.type_code == 0x05 or partition.type_code == 0x0F or partition.type_code == 0x85) {
            std.debug.print("  Observação: partição estendida; a cadeia de EBRs não é interpretada por este programa.\n", .{});
        }
        std.debug.print("  LBA inicial: {d}\n", .{partition.lba_start});
        std.debug.print("  Setores: {d}\n", .{partition.sector_count});
        const offset_bytes = @as(u64, partition.lba_start) * @as(u64, mbr_mod.sector_size);
        const size_bytes = @as(u64, partition.sector_count) * @as(u64, mbr_mod.sector_size);
        std.debug.print("  Offset inicial: {d} bytes\n", .{offset_bytes});
        std.debug.print("  Tamanho: {d} bytes ({d:.4} MiB)\n", .{ size_bytes, @as(f64, @floatFromInt(size_bytes)) / 1048576.0 });
        if (partition.sector_count > 0) {
            const end_lba = @as(u64, partition.lba_start) + @as(u64, partition.sector_count) - 1;
            std.debug.print("  LBA final inclusivo: {d}\n", .{end_lba});
        } else {
            std.debug.print("  LBA final inclusivo: não aplicável (zero setores)\n", .{});
        }
    }
    if (occupied_count == 0) std.debug.print("\nNenhuma entrada de partição ocupada.\n", .{});

    const diagnostics = validation.validate(parsed, image_size);
    std.debug.print("\nVerificações de consistência\n", .{});
    if (diagnostics.len == 0) {
        std.debug.print("Nenhum aviso encontrado.\n", .{});
        return;
    }
    for (diagnostics.items()) |diagnostic| {
        switch (diagnostic.kind) {
            .invalid_signature => std.debug.print("  AVISO: assinatura MBR ausente ou incorreta.\n", .{}),
            .unexpected_boot_flag => std.debug.print("  AVISO: partição {d} tem flag de boot inesperada (0x{X:0>2}); valores convencionais: 0x00 e 0x80.\n", .{ diagnostic.partition_a, parsed.partitions[diagnostic.partition_a - 1].boot_flag }),
            .zero_sector_count => std.debug.print("  AVISO: partição {d} está preenchida, mas declara zero setores.\n", .{diagnostic.partition_a}),
            .beyond_image => std.debug.print("  AVISO: partição {d} termina além do fim da imagem.\n", .{diagnostic.partition_a}),
            .includes_lba0 => std.debug.print("  AVISO: partição {d} inclui o LBA 0, que contém o próprio MBR.\n", .{diagnostic.partition_a}),
            .overlapping => std.debug.print("  AVISO: partições {d} e {d} têm intervalos LBA sobrepostos.\n", .{ diagnostic.partition_a, diagnostic.partition_b }),
        }
    }
}
