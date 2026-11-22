import 'item.dart';

/// 界面依赖的仓储接口。
///
/// 生产由 [InventoryDatabase] 实现（真实 sqflite 数据库）；
/// 测试可注入内存实现，从而在 headless widget test 里避免 ffi 数据库 I/O
/// 与测试事件循环的死锁（数据层本身由独立测试用真实数据库覆盖）。
abstract class InventoryRepository {
  Future<List<Location>> getAllLocations();

  /// V3：新增位置，可选备注。
  Future<int> addLocation(String name, {String? remark});

  /// V3：编辑位置名称/备注。
  Future<void> updateLocation(int id, {String? name, String? remark});

  /// V3：软删除位置。
  Future<void> deleteLocation(int id);

  /// V3：新增/命中一条物品-位置记录，可选保存原文 rawText。
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText});

  /// 挪位语义（V3.2，UI 主链路）：把物品记到新位置并软删其他位置关联，
  /// 详见 [InventoryDatabase.moveItem]。
  Future<MoveResult> moveItem(String itemName, int locationId,
      {String? rawText});

  Future<ItemWithLocations?> findByName(String name);

  /// 物品明细页：全部未删除物品及各自全部未删除位置，按物品名排序。
  Future<List<ItemWithLocations>> getAllItemsWithLocations();

  /// 备份导出：三张表全量行（含软删），JSON 可序列化结构。
  Future<Map<String, Object?>> exportBackup();

  /// 备份恢复：事务内清空三表后按备份重插（保留原 id）。
  /// 非 `home_inventory` 备份或版本高于当前库时抛 ArgumentError。
  Future<void> restoreBackup(Map<String, Object?> data);
}
