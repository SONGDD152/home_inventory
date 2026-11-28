import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'docx_writer.dart';
import 'domain.dart';
import 'inventory_repository.dart';

/// V4.2.3（+36 终审边界）：物品清单 Word（.docx）导出器——「文档导出」。
///
/// PM 终审边界：生活区/工作区各带「文档导出」，与 Excel 并列承载
/// 「所有的导出格式」（JSON 备份/恢复 + Excel 双表 + Word 清单）。
/// 生成走自研 [DocxWriter]（V4.0 起，零新增依赖）。
///
/// 内容三段：在库物品（含各位置数量）/ 借出中 / 回收站留底。
/// 纯读取不改库；文件名带域标识与日期，与 Excel/备份同口径。
class ItemDocxExporter {
  const ItemDocxExporter({required this.domain, this.fileWriter});

  /// 导出哪本账的清单（标题与文件名带域标识）。
  final InventoryDomain domain;

  /// 落盘注入（长按分享用）；生产默认 [defaultWrite] 临时目录，
  /// 测试注入截存字节（与 ExcelExporter.fileWriter 同构）。
  final Future<String> Function(Uint8List bytes)? fileWriter;

  /// 生产落盘实现：path_provider 临时目录 + File 写入。
  Future<String> defaultWrite(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file =
        File('${dir.path}${Platform.pathSeparator}${fileName(DateTime.now())}');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// 生成 docx 并落盘返回路径（长按分享用，与 Excel 分享链路同构）。
  Future<String> writeDocxFile(
      {required InventoryRepository repository}) async {
    final bytes = await build(repository: repository);
    final writer = fileWriter ?? defaultWrite;
    return writer(bytes);
  }

  /// 组装并生成 docx 字节。纯读取，不改库。
  Future<Uint8List> build({required InventoryRepository repository}) async {
    final rows = await repository.getAllItemsWithLocations();
    final loans = await repository.getAllLoans();
    final deleted = await repository.getDeletedItems();

    String two(int v) => v.toString().padLeft(2, '0');
    final now = DateTime.now();
    final today = '${now.year}-${two(now.month)}-${two(now.day)}';

    final lines = <DocxLine>[];

    // ---- 在库物品 ----
    lines.add(DocxLine('在库物品（${rows.length} 件）'));
    if (rows.isEmpty) {
      lines.add(const DocxLine('· 还没有记录'));
    }
    for (final row in rows) {
      final where = row.locations.isEmpty
          ? '无位置'
          : row.locations.map((loc) {
              final qty =
                  (loc.id != null ? row.quantityAt(loc.id!) : null) ?? 0;
              return '${loc.name} ×$qty';
            }).join('、');
      lines.add(DocxLine('· ${row.item.name}（$where）'));
    }

    // ---- 借出中 ----
    final openLoans =
        loans.where((l) => !l.isReturned && !l.isDeleted).toList();
    lines.add(const DocxLine(''));
    lines.add(DocxLine('借出中（${openLoans.length} 笔）'));
    if (openLoans.isEmpty) {
      lines.add(const DocxLine('· 没有借出中的记录'));
    }
    for (final loan in openLoans) {
      final due = DateTime.fromMillisecondsSinceEpoch(loan.dueAt);
      lines.add(DocxLine('· ${loan.itemName} 借给${loan.borrowerName}'
          ' ×${loan.quantity - loan.returnedQty}'
          '（到期 ${due.year}-${two(due.month)}-${two(due.day)}）'));
    }

    // ---- 回收站 ----
    lines.add(const DocxLine(''));
    lines.add(DocxLine('回收站留底（${deleted.length} 条）'));
    if (deleted.isEmpty) {
      lines.add(const DocxLine('· 回收站为空'));
    }
    for (final row in deleted) {
      final where = row.locations.isEmpty
          ? '无位置'
          : row.locations.map((l) => l.name).join('、');
      lines.add(DocxLine('· [回收站] ${row.item.name}（$where）'));
    }

    return DocxWriter.buildLines(
      title: '小本本-${domain.storageLabel}物品清单-$today',
      lines: lines,
    );
  }

  /// 导出文件名（与 Excel/备份同口径：带域标识与时间戳）。
  String fileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '小本本-${domain.storageLabel}物品清单-'
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.docx';
  }
}
