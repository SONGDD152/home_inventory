// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

import 'item_list_page_test.dart' show FakeListRepository;

/// V3.7 借出管理页测试用假仓储：继承物品假仓储，借出方法注入内存数据。
/// V3.8：借出记录软删（删除/恢复）在内存里真做，便于端到端断言。
class FakeLoanRepository extends FakeListRepository {
  final List<Loan> loans;
  final List<Borrower> borrowers;

  FakeLoanRepository(
      {this.loans = const <Loan>[],
      this.borrowers = const <Borrower>[],
      List<ItemWithLocations> items = const <ItemWithLocations>[]})
      : super(items);

  @override
  Future<List<Loan>> getAllLoans() async =>
      loans.where((l) => !l.isDeleted).toList(growable: false);

  @override
  Future<List<Borrower>> getActiveBorrowers() async => borrowers;

  @override
  Future<List<Loan>> getDeletedLoans() async =>
      loans.where((l) => l.isDeleted).toList(growable: false);

  @override
  Future<Loan> lendItem(String itemName, String borrowerName,
          {int quantity = 1, int? days}) async =>
      Loan(
        itemId: 1,
        itemName: itemName,
        borrowerName: borrowerName,
        quantity: quantity,
        borrowedAt: 1000,
        dueAt: 1000 + (days ?? 3) * 86400000,
      );

  @override
  Future<void> deleteLoan(int id) async {
    final idx = loans.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = loans[idx];
    loans[idx] = Loan(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      borrowerName: old.borrowerName,
      quantity: old.quantity,
      returnedQty: old.returnedQty,
      borrowedAt: old.borrowedAt,
      dueAt: old.dueAt,
      returnedAt: old.returnedAt,
      isPartial: old.isPartial,
      isDeleted: true,
      deletedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> restoreLoan(int id) async {
    final idx = loans.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    final old = loans[idx];
    loans[idx] = Loan(
      id: old.id,
      itemId: old.itemId,
      itemName: old.itemName,
      borrowerName: old.borrowerName,
      quantity: old.quantity,
      returnedQty: old.returnedQty,
      borrowedAt: old.borrowedAt,
      dueAt: old.dueAt,
      returnedAt: old.returnedAt,
      isPartial: old.isPartial,
    );
  }
}

void main() {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch;

  Widget buildPage(List<Loan> loans) => MaterialApp(
        home: LoanListPage(
          repository: FakeLoanRepository(
            loans: loans,
            borrowers: <Borrower>[
              Borrower(id: 1, name: '张三', createdAt: 1, updatedAt: 1),
            ],
          ),
        ),
      );

  testWidgets('借出页：无借出显示空态，右下角新增按钮存在', (tester) async {
    await tester.pumpWidget(buildPage(const <Loan>[]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_empty')), findsOneWidget);
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
  });

  testWidgets('借出页：有逾期借出时顶部红色横幅显示条数+最紧急一条', (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 2,
        borrowedAt: now - 10 * 86400000,
        dueAt: now - 5 * 86400000, // 逾期 5 天
      ),
      Loan(
        id: 2,
        itemId: 2,
        itemName: '充电器',
        borrowerName: '李四',
        quantity: 1,
        borrowedAt: now - 10 * 86400000,
        dueAt: now - 1 * 86400000, // 逾期 1 天（更紧急）
      ),
    ];
    await tester.pumpWidget(buildPage(loans));
    await tester.pumpAndSettle();

    final banner = find.byKey(const Key('loan_overdue_banner'));
    expect(banner, findsOneWidget);
    expect(find.descendant(of: banner, matching: find.textContaining('2 条借出已逾期')),
        findsOneWidget);
    expect(find.descendant(of: banner, matching: find.textContaining('梯子')),
        findsOneWidget, reason: '最紧急=到期最早（逾期最久）那条');
  });

  testWidgets('借出页：点逾期横幅过滤到逾期项', (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 1,
        borrowedAt: now - 10 * 86400000,
        dueAt: now - 5 * 86400000,
      ),
      Loan(
        id: 2,
        itemId: 2,
        itemName: '充电器',
        borrowerName: '李四',
        quantity: 1,
        borrowedAt: now - 2 * 86400000,
        dueAt: now + 5 * 86400000, // 未逾期
        returnedAt: null,
      ),
    ];
    await tester.pumpWidget(buildPage(loans));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_item_1')), findsOneWidget);
    expect(find.byKey(const Key('loan_item_2')), findsOneWidget);

    await tester.tap(find.byKey(const Key('loan_overdue_banner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_item_1')), findsOneWidget);
    expect(find.byKey(const Key('loan_item_2')), findsNothing,
        reason: '未逾期的被过滤掉');
  });

  testWidgets('借出页：未还清显示部分归还与全部归还按钮', (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 3,
        returnedQty: 1,
        isPartial: true,
        borrowedAt: now - 2 * 86400000,
        dueAt: now + 1 * 86400000,
      ),
    ];
    await tester.pumpWidget(buildPage(loans));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_partial_1')), findsOneWidget);
    expect(find.byKey(const Key('loan_return_1')), findsOneWidget);
    expect(find.byKey(const Key('loan_due_1')), findsOneWidget);
    expect(find.textContaining('已还 1/3'), findsOneWidget);
  });

  testWidgets('借出页：已归还默认不再挂着（PM：不该一直挂着），切「全部」可见且无归还按钮',
      (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 1,
        returnedQty: 1,
        borrowedAt: now - 5 * 86400000,
        dueAt: now - 2 * 86400000,
        returnedAt: now - 3 * 86400000,
      ),
    ];
    await tester.pumpWidget(buildPage(loans));
    await tester.pumpAndSettle();
    // V3.8：默认「在借」视图——已归还的记录不显示在列表里。
    expect(find.text('已归还'), findsNothing);
    expect(find.byKey(const Key('loan_item_1')), findsNothing);
    expect(find.byKey(const Key('loan_empty')), findsOneWidget);

    // 切「全部」→ 历史可查；已还清不显示归还按钮。
    await tester.tap(find.byKey(const Key('loan_filter_all')));
    await tester.pumpAndSettle();
    expect(find.text('已归还'), findsOneWidget);
    expect(find.byKey(const Key('loan_return_1')), findsNothing);
  });

  // ===== V3.8 真机验收打回修复 =====

  testWidgets('V3.8：右下角按钮带「新借出」文字标签（PM：绿色按钮没有标签）',
      (tester) async {
    await tester.pumpWidget(buildPage(const <Loan>[]));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_add_fab')), findsOneWidget);
    expect(find.text('新借出'), findsOneWidget);
  });

  testWidgets('V3.8：FAB 底色/前景色写死在本体（可见性回归锁，绕开 M3 继承链）',
      (tester) async {
    await tester.pumpWidget(buildPage(const <Loan>[]));
    await tester.pumpAndSettle();
    final fab = tester.widget<FloatingActionButton>(
        find.byKey(const Key('loan_add_fab')));
    expect(fab.backgroundColor, const Color(0xff1b5e20));
    expect(fab.foregroundColor, Colors.white);
    // 图标颜色也写死在 Icon 本体（V3.5 ☰ 不渲染的同源防护）。
    final icon = tester.widget<Icon>(find.descendant(
      of: find.byKey(const Key('loan_add_fab')),
      matching: find.byType(Icon),
    ));
    expect(icon.color, Colors.white);
  });

  testWidgets('V3.8：借出记录显示物品位置标签', (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 1,
        borrowedAt: now,
        dueAt: now + 86400000,
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: LoanListPage(
        repository: FakeLoanRepository(
          loans: loans,
          items: <ItemWithLocations>[
            ItemWithLocations(
              item: Item(id: 1, name: '梯子', createdAt: 1, updatedAt: 1),
              locations: <Location>[
                Location(id: 1, name: '阳台', createdAt: 1, updatedAt: 1),
              ],
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('位置：阳台'), findsOneWidget);
  });

  testWidgets('V3.8：删除借出记录有二次确认，确认后从列表消失', (tester) async {
    final loans = <Loan>[
      Loan(
        id: 1,
        itemId: 1,
        itemName: '梯子',
        borrowerName: '张三',
        quantity: 1,
        borrowedAt: now,
        dueAt: now + 86400000,
      ),
    ];
    await tester.pumpWidget(buildPage(loans));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_delete_1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('loan_delete_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('loan_delete_confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('loan_delete_confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('loan_item_1')), findsNothing,
        reason: '删除后不再挂在列表里');
    expect(find.byKey(const Key('loan_empty')), findsOneWidget);
  });
}
