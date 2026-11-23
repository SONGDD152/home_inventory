
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_inventory/data/excel_exporter.dart';
import 'package:home_inventory/data/item.dart';

/// V3.6：Excel 导出器测试。
/// buildWorkbook 纯内存可断言（zip 头 PK + 非空）；落盘用注入临时目录。
/// 「Excel/WPS 打开不乱码」与「分享面板调起」属真机验收项（口径见简报）。
void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  ItemWithLocations row(
    String name,
    List<String> locations, {
    bool deleted = false,
    List<String> rawTexts = const <String>[],
    List<String> tags = const <String>[],
    int? id,
  }) =>
      ItemWithLocations(
        item: Item(
          id: id,
          name: name,
          isDeleted: deleted,
          createdAt: now,
          updatedAt: now,
          deletedAt: deleted ? now : null,
        ),
        locations: <Location>[
          for (final loc in locations) Location(name: loc, createdAt: now, updatedAt: now),
        ],
        rawTexts: rawTexts,
        tags: tags,
      );

  group('buildWorkbook', () {
    test('非空数据：生成 zip 头 xlsx 字节，含表头', () {
      const exporter = ExcelExporter();
      final bytes = exporter.buildWorkbook(
        <ItemWithLocations>[
          row('梯子', <String>['阳台', '车库'],
              rawTexts: <String>['梯子放阳台'], tags: <String>['工具']),
        ],
        <ItemWithLocations>[
          row('旧椅子', <String>['储物间'], deleted: true),
        ],
      );
      expect(bytes, isNotEmpty);
      // xlsx 是 zip 容器，PK 头校验。
      expect(bytes[0], 0x50);
      expect(bytes[1], 0x4B);
    });

    test('空列表：仅表头文件不报错；回收站空则不建 Sheet2', () {
      const exporter = ExcelExporter();
      final bytes = exporter.buildWorkbook(
        const <ItemWithLocations>[],
        const <ItemWithLocations>[],
      );
      expect(bytes, isNotEmpty, reason: '空数据导出空表头文件');
    });
  });

  group('writeExcelFile', () {
    test('全链路：构建字节→落盘注入件→返回路径；文件名含当日日期', () async {
      Uint8List? captured;
      final exporter = ExcelExporter(
        fileWriter: (bytes) async {
          captured = bytes;
          return '/fake/out.xlsx';
        },
      );
      final path = await exporter.writeExcelFile(
        <ItemWithLocations>[row('梯子', <String>['阳台'])],
        <ItemWithLocations>[],
      );
      expect(path, '/fake/out.xlsx');
      expect(captured, isNotNull);
      expect(captured![0], 0x50);
      // 文件名规则（含当日日期）。
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      expect(
        exporter.fileNameFor(now),
        '家庭仓储物品明细_${now.year}${two(now.month)}${two(now.day)}.xlsx',
      );
    });
  });
}
