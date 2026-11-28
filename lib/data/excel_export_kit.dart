import 'dart:typed_data';

import 'domain.dart';
import 'excel_exporter.dart';
import 'inventory_repository.dart';
import 'item.dart';

/// V4.2.3（+36 终审边界）：Excel 导出套件——从物品明细页**原样搬入**数据
/// 数据管理签，供生活区/工作区各一份导出。
///
/// PM 终审边界：「物品明细页底部的『导出 Excel』按钮撤掉，导入导出功能
/// 统一收归数据管理签，不双头、不散落」。本套件承载的取数与组装链路与
/// 明细页原有逻辑**一字不差**（activeRows / 回收站双表 / 借出明细 /
/// 废弃流水 Sheet），只是调用方从明细页换成数据管理签——不重写、只搬家。
class ExcelExportKit {
  const ExcelExportKit({required this.domain, this.exporter});

  /// 导出哪本账的 Excel（文件名带域标识）。
  final InventoryDomain domain;

  /// Excel 导出器；生产默认按域构建，测试注入临时目录实现。
  final ExcelExporter? exporter;

  ExcelExporter _exporter() => exporter ?? ExcelExporter(domain: domain);

  /// 借出明细导出数据（loans + 物品 id→位置名映射）。
  ///
  /// 与明细页 `_loanExportData` 同口径：物品无位置记「（无位置）」，
  /// 多位置用「、」连接。
  Future<({List<Loan> loans, Map<int, String> locationByItem})>
      _loanExportData({
    required InventoryRepository repository,
    required List<ItemWithLocations> rows,
  }) async {
    final loans = await repository.getAllLoans();
    final locationByItem = <int, String>{};
    for (final row in rows) {
      final id = row.item.id;
      if (id == null) continue;
      locationByItem[id] = row.locations.isEmpty
          ? '（无位置）'
          : row.locations.map((l) => l.name).join('、');
    }
    return (loans: loans, locationByItem: locationByItem);
  }

  /// 组装全部导出数据并产出工作簿字节（点击导出=保存到手机用）。
  Future<Uint8List> buildWorkbookBytes({
    required InventoryRepository repository,
  }) async {
    final activeRows = await repository.getAllItemsWithLocations();
    final deletedRows = await repository.getDeletedItems();
    final loanData = await _loanExportData(
        repository: repository, rows: activeRows);
    // V3.12：废弃流水一并导出（新增「废弃流水」Sheet）。
    final discards = await repository.getDiscards(includeRestored: true);
    return _exporter().buildWorkbook(activeRows, deletedRows,
        loans: loanData.loans,
        locationByItem: loanData.locationByItem,
        discards: discards);
  }

  /// 生成 xlsx 落临时盘并返回路径（长按分享用）。
  Future<String> writeWorkbookFile({
    required InventoryRepository repository,
  }) async {
    final activeRows = await repository.getAllItemsWithLocations();
    final deletedRows = await repository.getDeletedItems();
    final loanData = await _loanExportData(
        repository: repository, rows: activeRows);
    // V3.12：废弃流水一并导出。
    final discards = await repository.getDiscards(includeRestored: true);
    return _exporter().writeExcelFile(activeRows, deletedRows,
        loans: loanData.loans,
        locationByItem: loanData.locationByItem,
        discards: discards);
  }

  /// 导出文件名（带域标识与时间戳）。
  String fileName(DateTime now) =>
      _exporter().fileNameForDomain(now, domain);
}
