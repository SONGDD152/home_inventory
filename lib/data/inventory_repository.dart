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

  /// V3.6/V3.9：恢复回收站物品。
  ///
  /// V3.6 旧口径是"撞名即抛 ArgumentError"；V3.9 按 PM 拍板改为
  /// **合并数量**：明细里已有同名物品时，把回收站这件的数量累加到
  /// 同名物品上、位置关联一并并过去，返回 [RestoreOutcome] 说明
  /// 是否发生了合并与合并后总数（供 UI 如实回显）。
  ///
  /// "删除时活跃"的关联行复活，位置关系还原。
  Future<RestoreOutcome> restoreItem(int id);

  /// V3.6：彻底删除回收站物品（物理 DELETE 物品行+全部关联行，不可恢复）。
  Future<void> purgeItem(int id);

  /// V3.6：清空回收站（物理 DELETE 全部已删物品及其关联行，不可恢复）。
  Future<void> purgeAll();

  /// V3：编辑位置名称/备注。
  Future<void> updateLocation(int id, {String? name, String? remark});

  /// V3：软删除位置。
  Future<void> deleteLocation(int id);

  /// V3：新增/命中一条物品-位置记录，可选保存原文 rawText。
  ///
  /// V3.10：新增 [quantity] 与 [additive]——
  ///  * [quantity] 为 null = 不带数量，物品数量保持原样；
  ///  * [additive] false = **覆盖**（PM 拍板③）；true = **累加**（补充要求1）。
  Future<UpsertResult> upsertItemLocation(String itemName, int locationId,
      {String? rawText, int? quantity, bool additive = false});

  /// 整体挪（V3.2 旧语义的兼容名）：把物品记到新位置并软删其他位置关联，
  /// 目标位置拿走全部数量、**总数不变**。不带数量的「挪到」走这里。
  ///
  /// V3.11 元宝批复第 1 条：挪位拆两个方法，禁止靠参数分流。
  /// 带数量的「挪 N 个」必须显式走 [moveItemPartial]。
  Future<MoveResult> moveItem(String itemName, int locationId,
          {String? rawText}) =>
      moveItemWhole(itemName, locationId, rawText: rawText);

  /// V3.11：整体挪的语义化命名（与 [moveItem] 等价），UI 主链路用。
  Future<MoveResult> moveItemWhole(String itemName, int toLocationId,
          {String? rawText}) =>
      throw UnimplementedError('moveItemWhole 需由真实仓储实现');

  /// V3.11：部分挪——从 [fromLocationId] 挪 [quantity] 个到 [toLocationId]，
  /// 总数不变；源位库存不足抛 ArgumentError（元宝批复第 4 条）。
  Future<MoveResult> moveItemPartial(
    String itemName,
    int fromLocationId,
    int toLocationId, {
    required int quantity,
    String? rawText,
  }) =>
      throw UnimplementedError('moveItemPartial 需由真实仓储实现');

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
          {int quantity = 1, int? days, int? fromLocationId}) =>
      throw UnimplementedError('lendItem 需由真实仓储实现');

  /// 归还：[quantity] 为空 = 全部；给定值 = 部分归还（累加 + 标 is_partial）。
  /// [toLocationId] 为归还落点（UI 弹窗问），未指定优先回借出源位置，
  /// 再回退主位置（V4.3.1 位置恢复口径）。
  /// [returnedAt] 精确归还时间（UTC 毫秒，UI 弹窗默认当前可改），不传落当前。
  Future<void> returnLoan(int loanId,
      {int? quantity, int? toLocationId, int? returnedAt}) async {}

  /// 单笔改借期（天数从借出时刻起算）。
  Future<void> updateLoanDue(int loanId, int days) async {}

  /// 全部借出记录（未软删，含已还，借出时间倒序）。逾期由 UI 按 due_at 计算。
  /// V3.8：已软删（进回收站）的记录不在此返回。
  Future<List<Loan>> getAllLoans() async => const <Loan>[];

  /// V4.3.1（+38 借出补丁）：某物品全部未还清的借出记录（未软删）。
  ///
  /// 位置查询合并借出状态的唯一数据源，与借出管理页同查 loans 一张表
  /// （PM 红线：查询结果与借出管理页数据同源，不各查各的）。
  /// 没有未还借出时返回空列表。
  Future<List<Loan>> getActiveLoansForItem(String itemName) async =>
      const <Loan>[];

  /// V3.8：回收站——已软删的借出记录（删除时间倒序）。
  Future<List<Loan>> getDeletedLoans() async => const <Loan>[];

  /// V3.8：软删借出记录（进回收站，可恢复）。
  Future<void> deleteLoan(int id) async {}

  /// V3.8：恢复已软删的借出记录。
  Future<void> restoreLoan(int id) async {}

  /// V3.8：彻底删除借出记录（物理删除，不可恢复）。
  Future<void> purgeLoan(int id) async {}

  /// 活跃借阅人（未软删，名字排序）——借出时下拉去重来源。
  Future<List<Borrower>> getActiveBorrowers() async => const <Borrower>[];

  /// 软删借阅人（历史 loan 的 borrower_name 快照不受影响）。
  Future<void> softDeleteBorrower(int id) async {}

  // ---------- V3.10 数量打通 ----------

  /// 单件物品的数量三口径（在库 / 在借 / 可借）。
  /// 未记录过的物品返回全 0。
  /// 口径：`items.quantity` = 在库数（借出即扣、归还即加），可借数 = 在库数。
  Future<QuantityInfo> getQuantityInfo(String itemName) async =>
      const QuantityInfo(stock: 0, lent: 0, available: 0);

  /// 全部活跃物品的数量三口径（按物品 id 索引，明细页用）。
  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async =>
      const <int, QuantityInfo>{};

  /// 「校准数量」工具（PM 2026-11-24 补充要求 2）：按用户实物清点把数量改准。
  ///
  /// [totals] = 物品 id → 用户清点的「家里一共几个」（总拥有数）。
  /// 写入的**在库数 = 总拥有数 − 未归还借出数**（下限 0）。
  /// 幂等：同样的清点值反复校准，结果不变。
  /// 传空 [totals] = 只体检、不写库。
  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
    Map<int, Map<int, int>> locationTotals = const <int, Map<int, int>>{},
  }) async =>
      const CalibrationReport(changedCount: 0);

  /// V3.10：只改数量，**不动位置**。
  ///
  /// 与 [moveItem] 分开：`moveItem` 是挪位语义，会软删物品的其他位置关联。
  /// [additive] 为 true = 「又添了 N 个」（在库数 += N）；否则 = 纠正数量（直接覆盖）。
  /// 物品没记录过 → 抛 ArgumentError。返回改完后的在库数。
  Future<int> setItemQuantity(String itemName, int quantity,
          {bool additive = false}) async =>
      0;

  /// V3.11：只改**某个位置**的数量（元宝批复第 3 条：弹窗选「某位置 N 个」时走这里，
  /// 不动用户没提的位置）。返回改完后的在库总数。
  Future<int> setLocationQuantity(
    String itemName,
    int locationId,
    int quantity, {
    bool additive = false,
  }) async =>
      0;

  // ---------- V3.12 部分废弃 ----------

  /// 部分废弃：把某位置的 [quantity] 个移出明细，其余留在明细里。
  ///
  /// 数量 == 在库总数时自动转整件废弃（物品进回收站）；位置数量不够
  /// 抛 ArgumentError 且**不改任何数量**。
  Future<DiscardOutcome> discardQuantity(
    String itemName,
    int quantity, {
    required int locationId,
    DiscardSource sourceType = DiscardSource.inStock,
  }) async =>
      throw UnimplementedError('discardQuantity 需由真实仓储实现');

  /// 恢复一条废弃流水：[toLocationId] 是恢复落点（PM 口径：恢复时问位置）。
  /// [quantity] 为空 = 恢复全部未恢复的数量。
  Future<ItemDiscard> restoreDiscard(int discardId, int toLocationId,
          {int? quantity}) async =>
      throw UnimplementedError('restoreDiscard 需由真实仓储实现');

  /// 废弃流水列表（默认只返回还有待恢复数量的）。
  Future<List<ItemDiscard>> getDiscards({bool includeRestored = false}) async =>
      const <ItemDiscard>[];

  /// 彻底删除一条废弃流水（物理清除，不可恢复）。
  Future<void> purgeDiscard(int discardId) async {}

  /// V3.12：数量守恒自检（`items.quantity == SUM(活跃位置数量)` 逐件成立）。
  /// 测试与诊断用；生产每次写操作后也会在 debug 模式自检。
  Future<bool> checkConservation() async => true;
}
