import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

import 'item.dart';

/// V3.6：物品明细 Excel 导出器（决策点⑤A 列头口径）。
///
/// 职责单一：把「正常明细 + 回收站」两份数据装进 xlsx 工作簿并落盘，
/// 返回文件路径供调用方走 [BackupGateway.shareFile] 等分享链路。
/// 不依赖 Flutter Widget，纯 Dart 可测（测试注入临时目录）。
///
/// 列头（每列均有真实数据来源，不造假列）：
///   物品名 / 存放位置（多个「、」连接）/ 记账原文（raw_text，
///   「梯子放阳台」）/ 标签（tags）/ 更新时间；
///   回收站 Sheet 追加「删除时间」列（deleted_at，NULL 显示 —）。
///
/// 家庭级数据量（<1000 行）主线程同步生成，不强制 Isolate。
/// 空列表导出仅含表头的文件，不报错。
class ExcelExporter {
  const ExcelExporter({this.fileWriter});

  /// 字节落盘函数；生产默认 [defaultWrite]（path_provider 临时目录 + File），
  /// 测试注入内存假件（widget 假异步环境禁止真实文件 IO）。
  final Future<String> Function(Uint8List bytes)? fileWriter;

  static const String sheetActive = '物品明细';
  static const String sheetDeleted = '回收站';
  /// V3.7：借出明细 Sheet。
  static const String sheetLoans = '借出明细';
  /// V3.12：废弃流水 Sheet（只废了几个的那些）。
  static const String sheetDiscards = '废弃流水';

  /// 生成工作簿字节。已删物品为空时不创建回收站 Sheet。
  /// [loans] V3.7：借出记录，非空时创建第三张「借出明细」Sheet。
  /// [locationByItem] 物品 id → 位置名（借出明细的「位置」列）。
  /// [discards] V3.12：部分废弃流水，非空时创建「废弃流水」Sheet。
  Uint8List buildWorkbook(
    List<ItemWithLocations> activeRows,
    List<ItemWithLocations> deletedRows, {
    List<Loan> loans = const <Loan>[],
    Map<int, String> locationByItem = const <int, String>{},
    List<ItemDiscard> discards = const <ItemDiscard>[],
  }) {
    final excel = Excel.createExcel();

    final active = excel[sheetActive];
    _writeSheet(active, activeRows, includeDeletedAt: false);
    // 清理 excel 包自带的默认空表（改名法更稳：先建自定义表再删默认表）。
    if (excel.tables.containsKey('Sheet1') && sheetActive != 'Sheet1') {
      excel.delete('Sheet1');
    }

    if (deletedRows.isNotEmpty) {
      final deleted = excel[sheetDeleted];
      _writeSheet(deleted, deletedRows, includeDeletedAt: true);
    }

    if (loans.isNotEmpty) {
      _writeLoanSheet(excel[sheetLoans], loans, locationByItem);
    }

    if (discards.isNotEmpty) {
      _writeDiscardSheet(excel[sheetDiscards], discards);
    }
    return Uint8List.fromList(excel.encode()!);
  }

  /// 生成文件并落盘，返回绝对路径。
  /// 文件名：家庭仓储物品明细_YYYYMMDD.xlsx（当日日期）。
  /// 落盘走 [fileWriter]（注入）或 [defaultWrite]（生产）。
  Future<String> writeExcelFile(
    List<ItemWithLocations> activeRows,
    List<ItemWithLocations> deletedRows, {
    List<Loan> loans = const <Loan>[],
    Map<int, String> locationByItem = const <int, String>{},
    List<ItemDiscard> discards = const <ItemDiscard>[],
  }) async {
    final bytes = buildWorkbook(activeRows, deletedRows,
        loans: loans, locationByItem: locationByItem, discards: discards);
    final writer = fileWriter ?? defaultWrite;
    return writer(bytes);
  }

  /// 当日导出文件名。
  String fileNameFor(DateTime now) {
    return '家庭仓储物品明细_'
        '${now.year}${_two(now.month)}${_two(now.day)}.xlsx';
  }

  /// 生产落盘实现：path_provider 临时目录 + File 写入。
  Future<String> defaultWrite(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final name = fileNameFor(DateTime.now());
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  // ---------- 内部：装 Sheet ----------

  void _writeSheet(
    Sheet sheet,
    List<ItemWithLocations> rows, {
    required bool includeDeletedAt,
  }) {
    // 表头（加粗）。
    final headers = <String>[
      '物品名',
      '存放位置',
      '记账原文',
      '标签',
      '更新时间',
      if (includeDeletedAt) '删除时间',
    ];
    sheet.appendRow(<CellValue?>[
      for (final h in headers) TextCellValue(h),
    ]);
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(
        columnIndex: c,
        rowIndex: 0,
      ));
      cell.cellStyle = CellStyle(bold: true, fontFamily: 'Calibri');
    }
    _fitColumnWidths(sheet, headers.length);

    // 数据行（原始语句保持 raw_text 原样；时间统一 yyyy-MM-dd HH:mm）。
    for (final row in rows) {
      final locations = row.locations.isEmpty
          ? '（无位置记录）'
          : row.locations.map((loc) => loc.name).join('、');
      final rawTexts = row.rawTexts.isEmpty
          ? ''
          : row.rawTexts.toSet().join('；');
      final tags = row.tags
          .where((t) => t.trim().isNotEmpty)
          .toSet()
          .join('、');
      final values = <Object?>[
        row.item.name,
        locations,
        rawTexts,
        tags,
        _formatTime(row.item.updatedAt),
        if (includeDeletedAt)
          row.item.deletedAt == null
              ? '—'
              : _formatTime(row.item.deletedAt!),
      ];
      sheet.appendRow(<CellValue?>[
        for (final v in values) TextCellValue(v.toString()),
      ]);
    }
  }

  /// V3.7 借出明细 Sheet。列头按元宝批复口径固定：
  /// 物品名 / 借阅人 / 借出数量 / 已还数量 / 借出日 / 到期日 / 状态 / 位置。
  /// 既有双 Sheet 列头不受影响（独立方法，回归锁住）。
  void _writeLoanSheet(
    Sheet sheet,
    List<Loan> loans,
    Map<int, String> locationByItem,
  ) {
    final headers = <String>[
      '物品名', '借阅人', '借出数量', '已还数量',
      '借出日', '到期日', '状态', '位置',
    ];
    sheet.appendRow(<CellValue?>[for (final h in headers) TextCellValue(h)]);
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(
          columnIndex: c, rowIndex: 0));
      cell.cellStyle = CellStyle(bold: true, fontFamily: 'Calibri');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final loan in loans) {
      final status = loan.isReturned
          ? '已归还'
          : (loan.isOverdue(nowMs) ? '逾期' : '借出中');
      final location = locationByItem[loan.itemId] ?? '—';
      final values = <Object?>[
        loan.itemName,
        loan.borrowerName.isEmpty ? '—' : loan.borrowerName,
        loan.quantity,
        loan.returnedQty,
        _formatDate(loan.borrowedAt),
        _formatDate(loan.dueAt),
        status,
        location,
      ];
      sheet.appendRow(<CellValue?>[
        for (final v in values) TextCellValue(v.toString()),
      ]);
    }
    _fitColumnWidths(sheet, headers.length);
  }

  String _formatDate(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${_two(t.month)}-${_two(t.day)}';
  }

  /// V3.12：废弃流水 Sheet。列头：
  /// 物品名 / 废弃数量 / 已恢复 / 待恢复 / 来源 / 原位置 / 废弃时间。
  void _writeDiscardSheet(Sheet sheet, List<ItemDiscard> discards) {
    final headers = <String>[
      '物品名', '废弃数量', '已恢复', '待恢复', '来源', '原位置', '废弃时间',
    ];
    sheet.appendRow(<CellValue?>[for (final h in headers) TextCellValue(h)]);
    for (var c = 0; c < headers.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(
          columnIndex: c, rowIndex: 0));
      cell.cellStyle = CellStyle(bold: true, fontFamily: 'Calibri');
    }
    for (final d in discards) {
      final values = <Object?>[
        d.itemName,
        d.quantity,
        d.restoredQuantity,
        d.pendingQuantity,
        d.sourceType == DiscardSource.onLoan ? '借出的那批' : '在库的那批',
        (d.locationName == null || d.locationName!.isEmpty)
            ? '—'
            : d.locationName,
        _formatTime(d.discardedAt),
      ];
      sheet.appendRow(<CellValue?>[
        for (final v in values) TextCellValue(v.toString()),
      ]);
    }
    _fitColumnWidths(sheet, headers.length);
  }

  /// 列宽按内容估算（中文按 2 个单位计），设上限避免超宽列。
  void _fitColumnWidths(Sheet sheet, int columnCount) {
    for (var c = 0; c < columnCount; c++) {
      var maxLen = 4.0;
      for (final row in sheet.rows) {
        if (c >= row.length) continue;
        final v = row[c]?.value;
        if (v == null) continue;
        final text = v.toString();
        var width = 0.0;
        for (final rune in text.runes) {
          width += rune > 0x2E7F ? 2.0 : 1.0; // CJK 宽字符按 2 计。
        }
        if (width > maxLen) maxLen = width;
      }
      sheet.setColumnWidth(c, (maxLen + 2).clamp(8.0, 60.0));
    }
  }

  String _two(int v) => v.toString().padLeft(2, '0');
  String _formatTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }
}
