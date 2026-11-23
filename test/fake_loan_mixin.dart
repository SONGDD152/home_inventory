import 'package:home_inventory/home_inventory.dart';

/// V3.7 借阅接口测试桩 mixin。
///
/// 测试假仓储通过 `with FakeLoanMixin` 获得借阅六方法的空实现，
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
}
