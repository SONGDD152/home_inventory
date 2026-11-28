// ignore_for_file: deprecated_member_use
// V4.3.1（+38）P0 备份安全专项测试。
//
// P0-1 备份内档自动轮转：全系统备份本地保留最近 3 份，最旧物理删
//       （只删备份文件，不碰业务数据）；轮转发生时报一行日志。
// P0-2 备份导出前完整性校验：关键字段非空 + 外键指向存在；
//       坏数据 → 不生成备份文件，提示「数据异常，暂不备份，请联系排查」。
//       校验范围 = 本仓真实表清单（仓储 9 表 + 知识 6 表）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:home_inventory/home_inventory.dart';
import 'package:home_inventory/data/domain.dart';
import 'package:home_inventory/domain/backup_archiver.dart';
import 'package:home_inventory/domain/backup_integrity.dart';
import 'package:home_inventory/domain/full_system_backup.dart';
import 'package:home_inventory/ui/full_system_backup_panel.dart';

import 'fake_loan_mixin.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  // ---------- P0-1：内档轮转 ----------

  group('BackupArchiver 轮转', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('v61_archiver_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    BackupArchiver archiver() => BackupArchiver(
          directoryResolver: () async => dir,
        );

    test('连续归档 4 份 → 本地只剩最近 3 份，最旧一份被物理删并留日志', () async {
      final a = archiver();
      for (var day = 20; day <= 23; day++) {
        await a.archiveAndRotate('{"day": $day}',
            now: DateTime(2026, 11, day, 9, 0, day - 20));
      }

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      expect(files, hasLength(3), reason: 'PM 口径：本地保留最近 3 份');
      final names = files.map((f) => f.uri.pathSegments.last).toList();
      expect(names.join(','), isNot(contains('20261120')),
          reason: '最旧一份被自动删除');
      expect(names.join(','), contains('20261123'),
          reason: '最新一份保留');

      // 内容保真：最后归档的 JSON 完整落盘。
      final newest =
          File(p.join(dir.path, names.last)).readAsStringSync();
      expect(jsonDecode(newest)['day'], 23);
    });

    test('轮转返回被删文件名（轮转日志用）；未超份数返回 null', () async {
      final a = archiver();
      final deleted = await a.archiveAndRotate('{"n": 1}',
          now: DateTime(2026, 11, 20, 9, 0, 0));
      expect(deleted, isNull, reason: '只 1 份，没到轮转线');

      final second = await a.archiveAndRotate('{"n": 2}',
          now: DateTime(2026, 11, 21, 9, 0, 0));
      expect(second, isNull, reason: '2 份仍未超');

      final third = await a.archiveAndRotate('{"n": 3}',
          now: DateTime(2026, 11, 22, 9, 0, 0));
      expect(third, isNull, reason: '恰好 3 份不轮转');

      final fourth = await a.archiveAndRotate('{"n": 4}',
          now: DateTime(2026, 11, 23, 9, 0, 0));
      expect(fourth, isNotNull, reason: '第 4 份触发轮转，返回被删的最旧文件名');
      expect(fourth, contains('20261120'));
    });

    test('轮转只删备份文件：目录里非 json 文件一字不动', () async {
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('keep me');
      final a = archiver();
      for (var day = 20; day <= 24; day++) {
        await a.archiveAndRotate('{"day": $day}',
            now: DateTime(2026, 11, day, 9, 0, 0));
      }
      expect(File(p.join(dir.path, 'readme.txt')).readAsStringSync(),
          'keep me', reason: '红线：轮转只动备份 .json 文件');
    });
  });

  // ---------- P0-2：完整性校验 ----------

  group('BackupIntegrity 校验', () {
    late Directory tempDir;
    late InventoryDatabase db;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('v61_integrity_');
      db = InventoryDatabase(
        databaseFactory: databaseFactoryFfi,
        databasePath: p.join(tempDir.path, 'inventory.db'),
        version: InventoryDatabase.currentSchemaVersion,
      );
    });

    tearDown(() async {
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('正常账导出 → 校验零问题（真实 ffi 库全量导出）', () async {
      final locationId = await db.addLocation('阳台');
      await db.upsertItemLocation('梯子', locationId, quantity: 2);
      final loan = await db.lendItem('梯子', '张三');
      await db.returnLoan(loan.id!,
          returnedAt: DateTime.now().toUtc().millisecondsSinceEpoch);

      final backup = await db.exportBackup();
      expect(BackupIntegrity.validateInventoryBackup(backup), isEmpty,
          reason: '正常账不得误报');
    });

    test('外键悬空：loans 指向不存在的物品 → 校验报出', () async {
      final locationId = await db.addLocation('次卧床上');
      await db.upsertItemLocation('指甲刀', locationId, quantity: 1);
      final backup = await db.exportBackup();
      final loans = (backup['loans'] as List)
          .map((r) => Map<String, Object?>.from(r as Map))
          .toList();
      // PM 验收口径：故意造一条坏数据（外键指向不存在的物品）。
      loans.add(<String, Object?>{
        'id': 999,
        'item_id': 424242,
        'item_name': '幽灵物品',
        'borrower_name': '张三',
        'quantity': 1,
        'returned_qty': 0,
        'borrowed_at': 1,
        'due_at': 2,
        'is_partial': 0,
        'is_deleted': 0,
        'updated_at': 1,
      });
      backup['loans'] = loans;

      final issues = BackupIntegrity.validateInventoryBackup(backup);
      expect(issues, isNotEmpty);
      expect(issues.join('；'), contains('指向不存在的物品'));
    });

    test('数量穿账：returned_qty 超过 quantity → 校验报出', () async {
      final backup = await db.exportBackup();
      backup['loans'] = <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'item_id': 1,
          'item_name': '梯子',
          'borrower_name': '张三',
          'quantity': 1,
          'returned_qty': 5,
          'borrowed_at': 1,
          'due_at': 2,
          'is_partial': 0,
          'is_deleted': 0,
          'updated_at': 1,
        },
      ];
      final issues = BackupIntegrity.validateInventoryBackup(backup);
      expect(issues.join('；'), contains('超出借出数'));
    });

    test('ensureValid：坏数据抛 ArgumentError，文案 = PM 口径', () {
      final bad = <String, Object?>{
        'items': <Object?>[
          <String, Object?>{'id': 1, 'name': '', 'quantity': 1},
        ],
      };
      expect(
        () => BackupIntegrity.ensureValid(bad, knowledge: false),
        throwsArgumentError,
      );
      try {
        BackupIntegrity.ensureValid(bad, knowledge: false);
      } on ArgumentError catch (e) {
        expect(e.message as String, contains('数据异常，暂不备份'));
        expect(e.message as String, contains('请联系排查'));
      }
    });

    test('知识域：node parent_id / entry node_id 悬空 → 校验报出', () {
      final bad = <String, Object?>{
        'knowledge_nodes': <Object?>[
          <String, Object?>{
            'id': 1, 'parent_id': null, 'title': '文学',
            'node_type': 'subject', 'is_deleted': 0,
          },
          <String, Object?>{
            'id': 2, 'parent_id': 424242, 'title': '唐诗',
            'node_type': 'topic', 'is_deleted': 0,
          },
        ],
        'knowledge_entries': <Object?>[
          <String, Object?>{'node_id': 999, 'core_summary': '孤儿条目'},
        ],
      };
      final issues = BackupIntegrity.validateKnowledgeBackup(bad);
      expect(issues.join('；'), contains('parent_id=424242 指向不存在'));
      expect(issues.join('；'), contains('node_id=999 指向不存在'));
    });
  });

  // ---------- P0-2：导出链路拦截（坏数据不生成文件） ----------

  testWidgets('全系统导出：坏数据 → 提示数据异常，网关零写入', (tester) async {
    final gateway = _RecordingGateway();
    final badRepo = _BadDataRepo();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FullSystemBackupPanel(
          service: FullSystemBackup(
            repositories: <InventoryDomain, InventoryRepository>{
              InventoryDomain.life: badRepo,
            },
          ),
          gateway: gateway,
          archiver: BackupArchiver(
              directoryResolver: () async =>
                  await Directory.systemTemp.createTemp('v61_panel_')),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('full_export_backup')));
    await tester.pumpAndSettle();

    expect(gateway.saveCalls, isEmpty,
        reason: '校验不通过 → 不生成备份文件');
    expect(find.textContaining('数据异常，暂不备份'), findsOneWidget);
  });
}

/// 造坏数据的假仓储：导出带一条外键悬空的借出记录。
class _BadDataRepo with FakeLoanMixin implements InventoryRepository {
  @override
  Future<Map<String, Object?>> exportBackup() async => <String, Object?>{
        'app': 'home_inventory',
        'domain': 'life',
        'schemaVersion': InventoryDatabase.currentSchemaVersion,
        'items': <Object?>[
          <String, Object?>{
            'id': 1, 'name': '梯子', 'is_deleted': 0,
            'created_at': 1, 'updated_at': 1, 'quantity': 1,
          },
        ],
        'locations': <Object?>[],
        'item_locations': <Object?>[],
        'loans': <Object?>[
          <String, Object?>{
            'id': 1,
            'item_id': 424242,
            'item_name': '梯子',
            'borrower_name': '张三',
            'quantity': 1,
            'returned_qty': 0,
            'borrowed_at': 1,
            'due_at': 2,
            'is_partial': 0,
            'is_deleted': 0,
            'updated_at': 1,
          },
        ],
      };

  // 其余接口补空桩。
  @override
  Future<ItemWithLocations?> findByName(String name) async => null;
  @override
  Future<List<Location>> getAllLocations() async => const <Location>[];
  @override
  Future<List<ItemWithLocations>> getAllItemsWithLocations() async =>
      const <ItemWithLocations>[];
  @override
  Future<void> updateItem(int id, String name) async {}
  @override
  Future<void> deleteItem(int id) async {}
  @override
  Future<List<ItemWithLocations>> getDeletedItems() async =>
      const <ItemWithLocations>[];
  @override
  Future<RestoreOutcome> restoreItem(int id) async =>
      RestoreOutcome(itemName: '', merged: false);
  @override
  Future<void> purgeItem(int id) async {}
  @override
  Future<void> purgeAll() async {}
  @override
  Future<void> updateLocation(int id, {String? name, String? remark}) async {}
  @override
  Future<void> deleteLocation(int id) async {}
  @override
  Future<int> addLocation(String name, {String? remark}) async => 1;
  @override
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false}) async {
    throw UnimplementedError();
  }

  @override
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) async =>
      throw UnimplementedError();
  @override
  Future<void> restoreBackup(Map<String, Object?> data) async {}
}

/// 记录型网关：断言「不生成文件」。
class _RecordingGateway implements BackupGateway {
  final List<String> saveCalls = <String>[];

  @override
  Future<String> writeBackupFile(String json) async => '/tmp/fake.json';

  @override
  Future<void> shareFile(String path) async {}

  @override
  Future<String?> saveBytesToDevice(String fileName, dynamic bytes) async {
    saveCalls.add(fileName);
    return '/tmp/$fileName';
  }

  @override
  Future<String?> pickBackupFile() async => null;

  @override
  Future<String> readBackupFile(String path) async => '{}';
}
