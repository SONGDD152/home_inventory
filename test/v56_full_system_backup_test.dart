// ignore_for_file: deprecated_member_use
/// V56：全系统备份（+34 / V4.2.1）——生活区 + 工作区**一份文件**。
///
/// 端到端实锤：双真库（ffi）各自造满全类型数据 → exportAll 一份 JSON →
/// 字符串往返（模拟落盘读回）→ 两个全新库 restoreAll → **每域 9 表
/// 逐行逐列比对**。已知允许差异只留一处：items.updated_at（时间戳）。
///
/// 互拒口径：单域文件进全系统入口 / 全系统文件进分区入口，都要明确拒 + 指路。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/data/inventory_database.dart';
import 'package:home_inventory/data/inventory_repository.dart';
import 'package:home_inventory/data/todo_state.dart';
import 'package:home_inventory/domain/full_system_backup.dart';

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
    tempDir = await Directory.systemTemp.createTemp('v56_fullsystem_');
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

  test('全系统往返：双库造满数据 → 一份 JSON → 双新库恢复 → 每域 9 表保真',
      () async {
    final lifeSrcPath = p.join(tempDir.path, 'life_src.db');
    final workSrcPath = p.join(tempDir.path, 'work_src.db');
    final lifeDstPath = p.join(tempDir.path, 'life_dst.db');
    final workDstPath = p.join(tempDir.path, 'work_dst.db');
    final lifeSrc = newDb(domain: InventoryDomain.life, path: lifeSrcPath);
    final workSrc = newDb(domain: InventoryDomain.work, path: workSrcPath);

    // ── 生活区造数（与工作区刻意不同，防串库）──
    await lifeSrc.addLocation('客厅');
    await lifeSrc.upsertItemLocation('梯子', 1, quantity: 4);
    await lifeSrc.upsertItemLocation('雨伞', 1, quantity: 2);
    await lifeSrc.lendItem('雨伞', '李四', quantity: 1, days: 3);
    final r1 = await lifeSrc.createReminder('交水电费',
        dueAt: DateTime(2026, 12, 1), repeatRule: 'monthly');
    await lifeSrc.setTodoStatus(
        TodoSourceType.scheduleReminder, r1, TodoStatus.inProgress);
    await lifeSrc.saveDailyReport('2026-11-28', '## 已完成\n- 收纳整理');

    // ── 工作区造数（含软删行，恢复收口语义一并锁）──
    await workSrc.addLocation('样品柜');
    await workSrc.upsertItemLocation('演示机', 1, quantity: 3);
    await workSrc.upsertItemLocation('拓展坞', 1, quantity: 1);
    final dockId = (await workSrc.findByName('拓展坞'))!.item.id!;
    await workSrc.deleteItem(dockId); // 软删一套
    final r2 = await workSrc.createReminder('交周报',
        detail: '周五前', dueAt: DateTime(2026, 12, 4), priority: 3);
    await workSrc.setNote(TodoSourceType.scheduleReminder, r2, '带数据');
    await workSrc.saveDailyReport('2026-11-28', '## 已完成\n- 周报');

    // ── 全系统导出 → JSON 字符串往返 ──
    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeSrc,
        InventoryDomain.work: workSrc,
      },
    );
    final backup = await service.exportAll();
    expect(backup['app'], 'home_inventory');
    expect(backup['kind'], 'full_system');
    expect(backup['formatVersion'], 1);
    final domains = backup['domains']! as Map<String, Object?>;
    expect(domains.keys.toSet(), <String>{'life', 'work'});
    expect((domains['life']! as Map<String, Object?>)['domain'], 'life');
    expect((domains['work']! as Map<String, Object?>)['domain'], 'work');
    final roundTrip = jsonDecode(jsonEncode(backup)) as Map<String, dynamic>;

    // ── 恢复到两个全新库 ──
    final lifeDst = newDb(domain: InventoryDomain.life, path: lifeDstPath);
    final workDst = newDb(domain: InventoryDomain.work, path: workDstPath);
    await lifeDst.open();
    await workDst.open();
    final restoreService = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeDst,
        InventoryDomain.work: workDst,
      },
    );
    await restoreService.restoreAll(roundTrip);

    // ── 每域 9 表逐行逐列比对 ──
    for (final table in tables) {
      final lifeBefore = await rawRows(lifeSrcPath, table);
      final lifeAfter = await rawRows(lifeDstPath, table);
      expect(lifeAfter.length, lifeBefore.length,
          reason: '[生活] $table 行数不一致：源 ${lifeBefore.length} '
              '恢复后 ${lifeAfter.length}');
      for (var i = 0; i < lifeBefore.length; i++) {
        final a = Map<String, Object?>.from(lifeBefore[i]);
        final b = Map<String, Object?>.from(lifeAfter[i]);
        if (table == 'items') {
          a.remove('updated_at');
          b.remove('updated_at');
        }
        expect(b, a,
            reason: '[生活] $table 第 ${i + 1} 行列不一致');
      }
      final workBefore = await rawRows(workSrcPath, table);
      final workAfter = await rawRows(workDstPath, table);
      expect(workAfter.length, workBefore.length,
          reason: '[工作] $table 行数不一致：源 ${workBefore.length} '
              '恢复后 ${workAfter.length}');
      for (var i = 0; i < workBefore.length; i++) {
        final a = Map<String, Object?>.from(workBefore[i]);
        final b = Map<String, Object?>.from(workAfter[i]);
        if (table == 'items') {
          a.remove('updated_at');
          b.remove('updated_at');
        }
        expect(b, a, reason: '[工作] $table 第 ${i + 1} 行列不一致');
      }
    }

    // ── 行数提示文案：逐域分行、有数可对 ──
    final text = restoreService.restoreResultText(roundTrip);
    expect(text, contains('生活区'));
    expect(text, contains('工作区'));
    expect(text, contains('物品 2 条'), reason: '生活区两件物品');
    expect(text, contains('物品 2 条'), reason: '工作区两件物品（含软删）');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('互拒①：单域备份文件进全系统入口 → 明确拒 + 指路分区入口', () async {
    final lifeSrc = newDb(domain: InventoryDomain.life);
    await lifeSrc.addLocation('客厅');
    final singleDomain = await lifeSrc.exportBackup();

    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeSrc,
      },
    );
    await expectLater(
      service.restoreAll(singleDomain),
      throwsA(predicate((e) =>
          e is ArgumentError &&
          '${e.message}'.contains('分区备份') &&
          '${e.message}'.contains('对应区域'))),
      reason: '单域文件不能静默当全系统恢复（会把另一本账留在原地）',
    );
  });

  test('互拒②：全系统备份文件进分区恢复入口 → 明确拒 + 指路全系统入口', () async {
    final lifeSrc = newDb(domain: InventoryDomain.life);
    final workSrc = newDb(domain: InventoryDomain.work);
    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeSrc,
        InventoryDomain.work: workSrc,
      },
    );
    final fullSystem = await service.exportAll();

    await expectLater(
      lifeSrc.restoreBackup(fullSystem),
      throwsA(predicate((e) =>
          e is ArgumentError && '${e.message}'.contains('全系统恢复'))),
      reason: '全系统文件进分区入口不能报「缺表」糊弄用户，要指路',
    );
  });

  test('校验：未知分区 key / 条目与位置不匹配 / 版本过高，全部拒绝', () async {
    final lifeSrc = newDb(domain: InventoryDomain.life);
    final workSrc = newDb(domain: InventoryDomain.work);
    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeSrc,
        InventoryDomain.work: workSrc,
      },
    );

    // ① 未知分区 key。
    final unknown = <String, Object?>{
      'app': 'home_inventory',
      'kind': 'full_system',
      'formatVersion': 1,
      'domains': <String, Object?>{
        'knowledge': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'knowledge',
          'schemaVersion': 13,
          'items': <Object?>[],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
      },
    };
    await expectLater(
      service.restoreAll(unknown),
      throwsA(predicate((e) =>
          e is ArgumentError && '${e.message}'.contains('不支持的分区'))),
      reason: '骨架版没有 knowledge 库，出现即视为非法文件',
    );

    // ② 条目与位置不匹配（key=life 放 work 的账）。
    final mismatched = <String, Object?>{
      'app': 'home_inventory',
      'kind': 'full_system',
      'formatVersion': 1,
      'domains': <String, Object?>{
        'life': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'work',
          'schemaVersion': 13,
          'items': <Object?>[],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
      },
    };
    await expectLater(
      service.restoreAll(mismatched),
      throwsA(predicate((e) =>
          e is ArgumentError && '${e.message}'.contains('不匹配'))),
      reason: '手改文件错位 = 覆盖另一本账级别的事故，必须拦',
    );

    // ③ 版本过高。
    final tooNew = <String, Object?>{
      'app': 'home_inventory',
      'kind': 'full_system',
      'formatVersion': 1,
      'domains': <String, Object?>{
        'life': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'life',
          'schemaVersion': InventoryDatabase.currentSchemaVersion + 1,
          'items': <Object?>[],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
      },
    };
    await expectLater(
      service.restoreAll(tooNew),
      throwsA(predicate((e) =>
          e is ArgumentError && '${e.message}'.contains('高于当前应用支持'))),
    );
  });

  test('校验前置：任一分区非法时，不落库（合法分区也不动）', () async {
    final lifeSrc = newDb(domain: InventoryDomain.life);
    final workSrc = newDb(domain: InventoryDomain.work);
    await lifeSrc.addLocation('客厅');
    await workSrc.addLocation('样品柜');
    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryDatabase>{
        InventoryDomain.life: lifeSrc,
        InventoryDomain.work: workSrc,
      },
    );

    // work 条目非法（版本过高），life 条目合法—— life 也必须原样不动。
    final poisoned = <String, Object?>{
      'app': 'home_inventory',
      'kind': 'full_system',
      'formatVersion': 1,
      'domains': <String, Object?>{
        'life': await lifeSrc.exportBackup(),
        'work': <String, Object?>{
          'app': 'home_inventory',
          'domain': 'work',
          'schemaVersion': 999,
          'items': <Object?>[],
          'locations': <Object?>[],
          'item_locations': <Object?>[],
        },
      },
    };
    await expectLater(
      service.restoreAll(poisoned),
      throwsA(isArgumentError),
    );
    final lifeRows = await rawRows(
      p.join(tempDir.path, '${InventoryDomain.life.id}_inventory.db'),
      'locations',
    );
    expect(lifeRows.length, 1, reason: '校验失败时任何分区都不得落库');
  });

  test('domains 口径：只收开放仓储能力的域，knowledge 永不出现在备份里', () {
    final service = FullSystemBackup(
      repositories: <InventoryDomain, InventoryRepository>{
        InventoryDomain.life: _StubRepo(),
        InventoryDomain.work: _StubRepo(),
      },
    );
    expect(service.domains.map((d) => d.id), <String>['life', 'work']);
  });
}

/// 最小桩仓储：只为实现接口（导出/恢复路径不走它）。
class _StubRepo implements InventoryDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} 未在本测试使用');
}
