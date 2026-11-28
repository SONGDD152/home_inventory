// V54：备份往返保真测试（V4.1.6 演练打回：旧包导出 → 新包恢复，
// 工作区日程等数据丢失）。
//
// 端到端实锤：真库（ffi）造满全类型数据 → exportBackup → JSON 字符串
// 往返（模拟文件落盘/读回）→ 新库 restoreBackup → **9 张表逐行逐列比对**。
// 已知允许差异只留一处：items.updated_at 被恢复收口 _syncItemTotal 重写
// （时间戳语义，账面数据不变）。
library;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/home_inventory.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  final opened = <InventoryDatabase>[];

  InventoryDatabase newDb({required InventoryDomain domain, String? path}) {
    final instance = InventoryDatabase(
      databaseFactory: databaseFactoryFfi,
      databasePath: path ?? p.join(tempDir.path, '${domain.id}_inventory.db'),
      version: 13,
      domain: domain,
    );
    opened.add(instance);
    return instance;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('v54_roundtrip_');
  });

  tearDown(() async {
    for (final instance in opened) {
      await instance.close();
    }
    opened.clear();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// raw 直开库文件读整表（绕过模型层，专抓「模型没认领的列」）。
  Future<List<Map<String, Object?>>> rawRows(
    String path,
    String table,
  ) async {
    final db = await databaseFactoryFfi.openDatabase(path);
    try {
      return await db.query(table, orderBy: 'id ASC');
    } finally {
      await db.close();
    }
  }

  test('工作区全类型数据：导出 → 恢复 → 9 表逐行逐列保真', () async {
    final srcPath = p.join(tempDir.path, 'work_src.db');
    final dstPath = p.join(tempDir.path, 'work_dst.db');
    final src = newDb(domain: InventoryDomain.work, path: srcPath);

    // ── 造数：仓储账 ──
    await src.addLocation('储物柜');
    await src.addLocation('阳台');
    await src.upsertItemLocation('梯子', 1, quantity: 3);
    await src.upsertItemLocation('梯子', 2, quantity: 2); // 多位置
    await src.upsertItemLocation('电钻', 1, quantity: 1);
    await src.setLocationQuantity('梯子', 1, 5);
    // 软删一套（物品+关联，回收站语义）。
    final drillId = (await src.findByName('电钻'))!.item.id!;
    await src.deleteItem(drillId);

    // ── 借出账 ──
    await src.lendItem('梯子', '张三', quantity: 2, days: 5);

    // ── 废弃流水 ──
    await src.discardQuantity('梯子', 1, locationId: 1);

    // ── 日程/提醒（丢失重灾区）──
    final r1 = await src.createReminder('交周报',
        detail: '周五前', dueAt: DateTime(2026, 12, 4), priority: 3);
    final r2 = await src.createReminder('交水电费',
        dueAt: DateTime(2026, 12, 1), repeatRule: 'monthly');
    final r3 = await src.createReminder('盘点仓库', dueAt: DateTime(2026, 11, 20));
    await src.markDone(TodoSourceType.scheduleReminder, r3); // 完成 → 三态行
    await src.setTodoStatus(
        TodoSourceType.scheduleReminder, r1, TodoStatus.inProgress);
    await src.setNote(TodoSourceType.scheduleReminder, r2, '余额不足再提醒');
    await src.removeReminder(r3); // 再软删一条，回收站语义

    // ── 日报存档 ──
    await src.saveDailyReport('2026-11-28', '## 已完成\n- 盘点仓库',
        sourceSnapshot: 'snapshot-x');

    // ── 导出 → JSON 字符串往返（模拟落盘读回）──
    final backup = await src.exportBackup();
    expect(backup['domain'], 'work');
    expect(backup['schemaVersion'], 13);
    final roundTrip =
        jsonDecode(jsonEncode(backup)) as Map<String, dynamic>;

    // ── 恢复到全新工作库 ──
    final dst = newDb(domain: InventoryDomain.work, path: dstPath);
    await dst.open();
    await dst.restoreBackup(roundTrip);

    // ── 9 表逐行逐列比对 ──
    const tables = <String>[
      'items',
      'locations',
      'item_locations',
      'borrowers',
      'loans',
      'item_discards',
      'reminders',
      'daily_reports',
      'todo_states',
    ];
    for (final table in tables) {
      final before = await rawRows(srcPath, table);
      final after = await rawRows(dstPath, table);
      expect(after.length, before.length,
          reason: '$table 行数不一致：源 ${before.length} 恢复后 ${after.length}');
      for (var i = 0; i < before.length; i++) {
        final a = Map<String, Object?>.from(before[i]);
        final b = Map<String, Object?>.from(after[i]);
        // 已知唯一允许差异：items.updated_at 被恢复收口重写（时间戳）。
        if (table == 'items') {
          a.remove('updated_at');
          b.remove('updated_at');
        }
        expect(b, a,
            reason: '$table 第 ${i + 1} 行（id=${before[i]['id']}）列不一致');
      }
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('导出行字段 == 表全部列（模型不许吞列）', () async {
    final srcPath = p.join(tempDir.path, 'work_cols.db');
    final src = newDb(domain: InventoryDomain.work, path: srcPath);
    await src.addLocation('阳台');
    await src.upsertItemLocation('梯子', 1);
    await src.createReminder('交周报', dueAt: DateTime(2026, 12, 4));
    final backup = await src.exportBackup();

    final rawDb = await databaseFactoryFfi.openDatabase(srcPath);
    final tableCols = <String, List<String>>{};
    // 只断言造过数的表（本库只造了这四张，空表覆盖断言空转无意义）。
    const covered = <String>[
      'items', 'locations', 'item_locations', 'reminders',
    ];
    try {
      for (final t in covered) {
        final cols = await rawDb.rawQuery(
            'PRAGMA table_info($t)', const <Object?>[]);
        tableCols[t] =
            cols.map((c) => c['name'] as String).toList(growable: false);
      }
    } finally {
      await rawDb.close();
    }

    for (final entry in tableCols.entries) {
      final rows = (backup[entry.key] as List).cast<Map>();
      expect(rows, isNotEmpty,
          reason: '${entry.key} 应有造数行，否则覆盖断言空转');
      expect(rows.first.keys.toSet(), entry.value.toSet(),
          reason: '${entry.key} 导出行字段必须与表列完全一致，'
              '缺列/多列都会在恢复时静默丢数据');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
