import 'package:home_inventory/home_inventory.dart';

/// V3.7 借阅接口测试桩 mixin。
///
/// 测试假仓储通过 `with FakeLoanMixin` 获得借阅方法的空实现，
/// 无需各自重复样板；真实数据库行为由 inventory_database_test.dart 覆盖。
mixin FakeLoanMixin {
  Future<Loan> lendItem(String itemName, String borrowerName,
          {int quantity = 1, int? days}) async =>
      Loan(
        itemId: 0,
        itemName: itemName,
        borrowerName: borrowerName,
        quantity: quantity,
        borrowedAt: 1,
        dueAt: 1 + (days ?? 3) * 86400000,
      );

  Future<void> returnLoan(int loanId, {int? quantity}) async {}

  Future<void> updateLoanDue(int loanId, int days) async {}

  Future<List<Loan>> getAllLoans() async => const <Loan>[];

  Future<List<Borrower>> getActiveBorrowers() async => const <Borrower>[];

  Future<void> softDeleteBorrower(int id) async {}

  // V3.8：借出记录软删（回收站）相关。
  Future<List<Loan>> getDeletedLoans() async => const <Loan>[];

  Future<void> deleteLoan(int id) async {}

  Future<void> restoreLoan(int id) async {}

  Future<void> purgeLoan(int id) async {}

  // ---------- V3.10 数量打通 ----------
  //
  // 注意：Dart 的 `implements` **不继承接口的默认实现**，测试假仓储必须
  // 自己提供这些方法（或经本 mixin 补齐），否则调用会挂住/抛错。
  Future<QuantityInfo> getQuantityInfo(String itemName) async =>
      const QuantityInfo(stock: 0, lent: 0, available: 0);

  Future<Map<int, QuantityInfo>> getAllQuantityInfo() async =>
      const <int, QuantityInfo>{};

  Future<CalibrationReport> calibrateQuantities({
    Map<int, int> totals = const <int, int>{},
  }) async =>
      const CalibrationReport(changedCount: 0);

  /// V3.10：只改数量、不动位置。默认桩实现返回 0（不改任何东西）。
  Future<int> setItemQuantity(String itemName, int quantity,
          {bool additive = false}) async =>
      0;
}
