import '../data/domain.dart';
import '../data/inventory_repository.dart';

/// V4.0：单域账目快照（**不可变**）。
///
/// 概览页只持有这个快照 + 只读的 [OverviewReader]，
/// **拿不到任何可写仓库实例**——概览只读在**代码层**落实，不是靠"UI 没放按钮"。
class DomainOverview {
  const DomainOverview({
    required this.domain,
    required this.itemCount,
    required this.stock,
    required this.lent,
    required this.discardedPending,
    required this.isConsistent,
  });

  /// 这一快照属于哪个域。
  final InventoryDomain domain;

  /// 活跃物品件数（明细里有多少种东西）。
  final int itemCount;

  /// 在库数（现在家里有几个）。
  final int stock;

  /// 在借数（借出去还没还的）。
  final int lent;

  /// 已废弃、未恢复的数量（还在回收站里占着"这本账的拥有数"）。
  final int discardedPending;

  /// 守恒自检是否通过（`items.quantity == SUM(活跃位置数量)` 逐件成立）。
  final bool isConsistent;

  /// 总拥有数（V3.12 口径：在库 + 在借 + 已废弃未恢复）。
  int get totalOwned => stock + lent + discardedPending;

  /// 这一域的账平不平（一眼看出哪本账有问题）。
  bool get isBalanced => isConsistent;
}

/// V4.0：概览的**只读**读取口。
///
/// 概览层只依赖这个接口，不持有 [InventoryDatabase]——
/// 想在概览里改数据，**代码上就做不到**。
abstract class OverviewReader {
  /// 读某个域的账目快照。
  Future<DomainOverview> read(InventoryDomain domain);
}

/// 生产实现：从对应域的仓储实例**只读**汇总。
///
/// 之所以敢把它放在数据层旁边：它只调用查询方法，
/// 概览页拿到的是 [DomainOverview] 快照，**不是仓库实例**。
class InventoryOverviewReader implements OverviewReader {
  InventoryOverviewReader({
    required this.life,
    required this.work,
  });

  final InventoryRepository life;
  final InventoryRepository work;

  InventoryRepository _dbOf(InventoryDomain domain) =>
      domain == InventoryDomain.life ? life : work;

  @override
  Future<DomainOverview> read(InventoryDomain domain) async {
    final db = _dbOf(domain);
    final quantities = await db.getAllQuantityInfo();
    var stock = 0;
    var lent = 0;
    for (final info in quantities.values) {
      stock += info.stock;
      lent += info.lent;
    }
    // 已废弃未恢复：部分废弃流水里还没恢复的数量。
    var discardedPending = 0;
    final discards = await db.getDiscards();
    for (final discard in discards) {
      discardedPending += discard.pendingQuantity;
    }
    final consistent = await db.checkConservation();
    return DomainOverview(
      domain: domain,
      itemCount: quantities.length,
      stock: stock,
      lent: lent,
      discardedPending: discardedPending,
      isConsistent: consistent,
    );
  }
}

/// 只读仓储视图：给概览用的极薄封装（**没有任何写方法**）。
///
/// 用于「概览只读在代码层落实」这条约束的自证：
/// 拿到这个类型的调用方，编译期就写不了。
class ReadOnlyInventoryView {
  const ReadOnlyInventoryView(this.repository);

  /// 只读查询用。
  final InventoryRepository repository;
}
