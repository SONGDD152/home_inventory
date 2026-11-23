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

  /// V3.2：编辑物品名称（归一化+撞名校验，见 [InventoryDatabase.updateItem]）。
  Future<void> updateItem(int id, String name);

  /// V3.2：删除物品（V3.6 起为软删进回收站：物品行 is_deleted=1+deleted_at，
  /// 活跃关联行同步软删留底），详见 [InventoryDatabase.deleteItem]。
  Future<void> deleteItem(int id);

  /// V3.6：回收站——全部已删物品（is_deleted=1，deleted_at 倒序，NULL 排末尾），
  /// 每件物品附全部关联行对应的有效位置（含挪位历史，去重）。
  Future<List<ItemWithLocations>> getDeletedItems();

  /// V3.6：恢复回收站物品（撞名即抛 ArgumentError，不自动改名；
  /// "删除时活跃"的关联行复活，位置关系还原）。
  Future<void> restoreItem(int id);

  /// V3.6：彻底删除回收站物品（物理 DELETE 物品行+全部关联行，不可恢复）。
  Future<void> purgeItem(int id);

  /// V3.6：清空回收站（物理 DELETE 全部已删物品及其关联行，不可恢复）。
  Future<void> purgeAll();

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

  // ---------- V3.7 借阅管理 ----------

  /// 借出：物品 + 借阅人 + 数量 + 借期天数（默认 3 天）。
  /// 借阅人按名字复用活跃行；due_at 用 UTC 存储。
  /// 以下六个方法提供安全默认实现（返回空/无操作），使测试假仓储无需逐个实现；
  /// 生产 [InventoryDatabase] 全部 override 为真实数据库行为。
  Future<Loan> lendItem(String itemName, String borrowerName,
      {int quantity = 1, int? days}) =>
      throw UnimplementedError('lendItem 需由真实仓储实现');

  /// 归还：[quantity] 为空 = 全部；给定值 = 部分归还（累加 + 标 is_partial）。
  Future<void> returnLoan(int loanId, {int? quantity}) async {}

  /// 单笔改借期（天数从借出时刻起算）。
  Future<void> updateLoanDue(int loanId, int days) async {}

  /// 全部借出记录（含已还，借出时间倒序）。逾期由 UI 按 due_at 计算。
  Future<List<Loan>> getAllLoans() async => const <Loan>[];

  /// 活跃借阅人（未软删，名字排序）——借出时下拉去重来源。
  Future<List<Borrower>> getActiveBorrowers() async => const <Borrower>[];

  /// 软删借阅人（历史 loan 的 borrower_name 快照不受影响）。
  Future<void> softDeleteBorrower(int id) async {}
}
