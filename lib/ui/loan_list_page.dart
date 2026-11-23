// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/inventory_database.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';

/// 借出管理页（V3.7，元宝决策③A：仓储抽屉二级入口，不动五模块底栏）。
///
/// 顶部红色逾期横幅（逾期条数 + 最紧急一条，点击过滤逾期项）；
/// 下方借出明细列表（含全部/逾期过滤切换）。
/// 支持：新借出（物品 + 借阅人 + 数量 + 天数）、全部/部分归还、
/// 单笔改借期、软删借阅人（长按借阅人标签）。
/// 借阅人来源：历史去重下拉 + 手填，不做独立管理页。
class LoanListPage extends StatefulWidget {
  const LoanListPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<LoanListPage> createState() => _LoanListPageState();
}

class _LoanListPageState extends State<LoanListPage> {
  List<Loan> _loans = <Loan>[];
  List<Borrower> _borrowers = <Borrower>[];
  bool _loading = true;
  bool _busy = false;
  bool _overdueOnly = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final loans = await widget.repository.getAllLoans();
    final borrowers = await widget.repository.getActiveBorrowers();
    if (!mounted) return;
    setState(() {
      _loans = loans;
      _borrowers = borrowers;
      _loading = false;
    });
  }

  int get _nowMs => DateTime.now().toUtc().millisecondsSinceEpoch;

  List<Loan> get _overdueLoans =>
      _loans.where((l) => l.isOverdue(_nowMs)).toList(growable: false);

  List<Loan> get _visibleLoans =>
      _overdueOnly ? _overdueLoans : _loans;

  @override
  Widget build(BuildContext context) {
    final overdue = _overdueLoans;
    return Scaffold(
      appBar: AppBar(
        title: const Text('借出管理'),
        actions: <Widget>[
          IconButton(
            key: const Key('loan_add'),
            icon: const Icon(Icons.add),
            tooltip: '新借出',
            onPressed: _busy ? null : _showLendDialog,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('loan_add_fab'),
        onPressed: _busy ? null : _showLendDialog,
        tooltip: '新借出',
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                if (overdue.isNotEmpty) _buildOverdueBanner(overdue),
                _buildFilterBar(),
                Expanded(
                  child: _visibleLoans.isEmpty
                      ? Center(
                          key: const Key('loan_empty'),
                          child: Text(
                            _overdueOnly ? '没有逾期借出' : '暂无借出记录，点右下角 + 新增',
                            style: const TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _visibleLoans.length,
                          itemBuilder: (context, index) =>
                              _buildLoanTile(_visibleLoans[index]),
                        ),
                ),
              ],
            ),
    );
  }

  /// 逾期横幅：显示条数 + 最紧急一条（到期最早），点击过滤逾期项。
  Widget _buildOverdueBanner(List<Loan> overdue) {
    final mostUrgent = overdue.reduce((a, b) => a.dueAt < b.dueAt ? a : b);
    return InkWell(
      key: const Key('loan_overdue_banner'),
      onTap: () => setState(() => _overdueOnly = true),
      child: Container(
        width: double.infinity,
        color: const Color(0xffc62828),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          '${overdue.length} 条借出已逾期 · 最紧急：${mostUrgent.itemName}'
          '（${_formatDate(mostUrgent.dueAt)}到期）',
          style: const TextStyle(color: Colors.white, fontSize: 13.5),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: <Widget>[
          ChoiceChip(
            key: const Key('loan_filter_all'),
            label: const Text('全部'),
            selected: !_overdueOnly,
            onSelected: (_) => setState(() => _overdueOnly = false),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('loan_filter_overdue'),
            label: const Text('逾期'),
            selected: _overdueOnly,
            onSelected: (_) => setState(() => _overdueOnly = true),
          ),
        ],
      ),
    );
  }

  Widget _buildLoanTile(Loan loan) {
    final overdue = loan.isOverdue(_nowMs);
    final status = loan.isReturned
        ? '已归还'
        : (overdue ? '逾期' : '借出中');
    final statusColor = loan.isReturned
        ? const Color(0xff1b5e20)
        : (overdue ? const Color(0xffc62828) : const Color(0xff1565c0));
    return Card(
      key: Key('loan_item_${loan.id ?? loan.itemName}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${loan.itemName} ×${loan.quantity}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(status,
                    style: TextStyle(color: statusColor, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 4),
            GestureDetector(
              onLongPress: loan.borrowerName.isEmpty
                  ? null
                  : () => _confirmSoftDeleteBorrower(loan.borrowerName),
              child: Text(
                '借给：${loan.borrowerName.isEmpty ? '—' : loan.borrowerName}'
                ' · 借出 ${_formatDate(loan.borrowedAt)}'
                ' · 到期 ${_formatDate(loan.dueAt)}'
                ' · 已还 ${loan.returnedQty}/${loan.quantity}'
                '${loan.isPartial ? '（部分）' : ''}',
                style: const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
              ),
            ),
            if (!loan.isReturned) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    key: Key('loan_due_${loan.id ?? loan.itemName}'),
                    onPressed: _busy ? null : () => _showDueDialog(loan),
                    child: const Text('改借期'),
                  ),
                  const SizedBox(width: 8),
                  if (loan.returnedQty < loan.quantity)
                    TextButton(
                      key: Key('loan_partial_${loan.id ?? loan.itemName}'),
                      onPressed: _busy ? null : () => _returnLoan(loan, partial: true),
                      child: const Text('还1个'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: Key('loan_return_${loan.id ?? loan.itemName}'),
                    onPressed: _busy ? null : () => _returnLoan(loan),
                    child: const Text('全部归还'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- 交互 ----------

  Future<void> _showLendDialog() async {
    final itemController = TextEditingController();
    final borrowerController = TextEditingController();
    final quantityController = TextEditingController(text: '1');
    final daysController = TextEditingController(
        text: '${InventoryDatabase.defaultLoanDays}');
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新借出'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  key: const Key('lend_item_field'),
                  controller: itemController,
                  decoration: const InputDecoration(labelText: '物品名'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? '请填物品名' : null,
                ),
                TextFormField(
                  key: const Key('lend_borrower_field'),
                  controller: borrowerController,
                  decoration: InputDecoration(
                    labelText: '借阅人',
                    helperText: _borrowers.isEmpty
                        ? '历史借阅人会自动出现在这里'
                        : '历史：${_borrowers.map((b) => b.name).join('、')}',
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? '请填借阅人' : null,
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        key: const Key('lend_quantity_field'),
                        controller: quantityController,
                        decoration: const InputDecoration(labelText: '数量'),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return (n == null || n < 1) ? '至少 1' : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        key: const Key('lend_days_field'),
                        controller: daysController,
                        decoration: const InputDecoration(labelText: '借期（天）'),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return (n == null || n < 1) ? '至少 1' : null;
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('lend_confirm'),
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.of(context).pop(true);
              }
            },
            child: const Text('借出'),
          ),
        ],
      ),
    );
    if (result != true || !mounted) return;

    setState(() => _busy = true);
    await widget.repository.lendItem(
      normalizeName(itemController.text),
      normalizeName(borrowerController.text),
      quantity: int.tryParse(quantityController.text) ?? 1,
      days: int.tryParse(daysController.text),
    );
    if (!mounted) return;
    await _reload();
    setState(() => _busy = false);
  }

  Future<void> _showDueDialog(Loan loan) async {
    final controller = TextEditingController(
        text: '${InventoryDatabase.defaultLoanDays}');
    final result = await showDialog<int?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('改借期：${loan.itemName}'),
        content: TextField(
          key: const Key('loan_due_days_field'),
          controller: controller,
          decoration: const InputDecoration(labelText: '借期（天，从借出日算）'),
          keyboardType: TextInputType.number,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text)),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null || result < 1 || !mounted) return;
    setState(() => _busy = true);
    await widget.repository.updateLoanDue(loan.id!, result);
    if (!mounted) return;
    await _reload();
    setState(() => _busy = false);
  }

  Future<void> _returnLoan(Loan loan, {bool partial = false}) async {
    setState(() => _busy = true);
    await widget.repository.returnLoan(loan.id!, quantity: partial ? 1 : null);
    if (!mounted) return;
    await _reload();
    setState(() => _busy = false);
  }

  Future<void> _confirmSoftDeleteBorrower(String name) async {
    final matched = _borrowers.where((b) => b.name == name);
    if (matched.isEmpty) return;
    final borrower = matched.first;
    if (borrower.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除借阅人「$name」？'),
        content: const Text('只删除借阅人，历史借出记录仍保留当时名字。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await widget.repository.softDeleteBorrower(borrower.id!);
    if (!mounted) return;
    await _reload();
    setState(() => _busy = false);
  }

  String _formatDate(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month}/${t.day}';
  }
}
