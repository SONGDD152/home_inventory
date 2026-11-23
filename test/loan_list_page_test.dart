// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_inventory/home_inventory.dart';

import 'item_list_page_test.dart' show FakeListRepository;

/// V3.7 借出管理页测试用假仓储：继承物品假仓储，借出方法注入内存数据。
class FakeLoanRepository extends FakeListRepository {
  final List<Loan> loans;
  final List<Borrower> borrowers;

  FakeLoanRepository({this.loans = const <Loan>[], this.borrowers = const <Borrower>[]})
      : super(const <ItemWithLocations>[]);

  @override
  Future<List<Loan>> getAllLoans() async => loans;

  @override
  Future<List<Borrower>> getActiveBorrowers() async => borrowers;

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

  testWidgets('借出页：已全部归还不再显示归还按钮', (tester) async {
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
    expect(find.text('已归还'), findsOneWidget);
    expect(find.byKey(const Key('loan_return_1')), findsNothing);
  });
}
