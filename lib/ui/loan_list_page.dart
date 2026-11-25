// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

import '../data/inventory_database.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';

/// 借出管理页（V3.7，元宝决策③A：仓储抽屉二级入口，不动五模块底栏）。
///
/// 顶部红色逾期横幅（逾期条数 + 最紧急一条，点击过滤逾期项）；
/// 下方借出明细列表（V3.8 默认只看在借——已归还的不再挂着，
/// PM 真机反馈「已归还的这条信息应该就没有了」；「全部」里仍可查历史）。
/// 支持：新借出（物品 + 借阅人 + 数量 + 天数）、全部/部分归还、
/// 单笔改借期、删除借出记录（进回收站，可撤销/恢复）、
/// 软删借阅人（长按借阅人标签）。
/// 每条记录显示物品当前位置标签（PM 真机反馈：归还的物品没有位置标签）。
/// 借阅人来源：历史去重下拉 + 手填，不做独立管理页。
class LoanListPage extends StatefulWidget {
  const LoanListPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<LoanListPage> createState() => _LoanListPageState();
}

/// 列表筛选档位：只看在借 / 全部（含已归还）/ 只看逾期。
enum _LoanFilter { active, all, overdue }

class _LoanListPageState extends State<LoanListPage> {
  List<Loan> _loans = <Loan>[];
  List<Borrower> _borrowers = <Borrower>[];
  /// 物品 id → 位置名列表（当前位置标签来源）。
  Map<int, List<String>> _locations = <int, List<String>>{};
  /// 物品名 → 位置名列表（改名/快照对不上时的兜底）。
  Map<String, List<String>> _locationsByName = <String, List<String>>{};
  /// V3.10：物品 id → 数量三口径（显示"家里还有几个"）。
  Map<int, QuantityInfo> _quantities = <int, QuantityInfo>{};
  bool _loading = true;
  bool _busy = false;
  _LoanFilter _filter = _LoanFilter.active;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final loans = await widget.repository.getAllLoans();
    final borrowers = await widget.repository.getActiveBorrowers();
    final items = await widget.repository.getAllItemsWithLocations();
    // V3.10：数量三口径（家里几个 / 借出几个 / 还能借几个）。
    final quantities = await widget.repository.getAllQuantityInfo();
    if (!mounted) return;
    final locations = <int, List<String>>{};
    final byName = <String, List<String>>{};
    for (final row in items) {
      final names = row.locations.map((l) => l.name).toSet().toList()..sort();
      byName[row.item.name] = names;
      final id = row.item.id;
      if (id == null) continue;
      locations[id] = names;
    }
    setState(() {
      _loans = loans;
      _borrowers = borrowers;
      _locations = locations;
      _locationsByName = byName;
      _quantities = quantities;
      _loading = false;
    });
  }

  int get _nowMs => DateTime.now().toUtc().millisecondsSinceEpoch;

  List<Loan> get _overdueLoans =>
      _loans.where((l) => l.isOverdue(_nowMs)).toList(growable: false);

  /// V3.8：默认只看未还清（在借）的记录——已归还的不再挂在列表里。
  List<Loan> get _visibleLoans {
    switch (_filter) {
      case _LoanFilter.active:
        return _loans.where((l) => !l.isReturned).toList(growable: false);
      case _LoanFilter.overdue:
        return _overdueLoans;
      case _LoanFilter.all:
        return _loans;
    }
  }

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
      // V3.8 真机修复：原实现用 FloatingActionButton + 纯 Icon，
      // 真机上按钮渲染成一块浅绿色方块、加号完全没出来，也没有文字标签
      // （PM 反馈「有个绿色的按钮，但是没有标签」）。现在改为 extended 形态
      // 并把前景色/文字色写死在本体上，绕开 M3 样式继承链。
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('loan_add_fab'),
        onPressed: _busy ? null : _showLendDialog,
        tooltip: '新借出',
        backgroundColor: const Color(0xff1b5e20),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add, color: Colors.white, size: 22),
        label: const Text(
          '新借出',
          style: TextStyle(color: Colors.white, fontSize: 14),
        ),
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
                            _emptyText,
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

  /// 空态文案（随筛选档位变化）。
  String get _emptyText {
    switch (_filter) {
      case _LoanFilter.active:
        return '没有在借的东西，点右下角「新借出」记一笔';
      case _LoanFilter.overdue:
        return '没有逾期借出';
      case _LoanFilter.all:
        return '暂无借出记录，点右下角「新借出」记一笔';
    }
  }

  /// 逾期横幅：显示条数 + 最紧急一条（到期最早），点击过滤逾期项。
  Widget _buildOverdueBanner(List<Loan> overdue) {
    final mostUrgent = overdue.reduce((a, b) => a.dueAt < b.dueAt ? a : b);
    return InkWell(
      key: const Key('loan_overdue_banner'),
      onTap: () => setState(() => _filter = _LoanFilter.overdue),
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
            key: const Key('loan_filter_active'),
            label: const Text('在借'),
            selected: _filter == _LoanFilter.active,
            onSelected: (_) => setState(() => _filter = _LoanFilter.active),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('loan_filter_all'),
            label: const Text('全部'),
            selected: _filter == _LoanFilter.all,
            onSelected: (_) => setState(() => _filter = _LoanFilter.all),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('loan_filter_overdue'),
            label: const Text('逾期'),
            selected: _filter == _LoanFilter.overdue,
            onSelected: (_) => setState(() => _filter = _LoanFilter.overdue),
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
    final locations =
        _locations[loan.itemId] ?? _locationsByName[loan.itemName] ?? const <String>[];
    // V3.10：账实一目了然——家里还有几个、还有几个借出去没还。
    // （可借数 = 在库数，不再单独显示，免得两个一样的数字让人犯迷糊。）
    final q = _quantities[loan.itemId];
    final stockText = q == null
        ? null
        : (q.lent > 0
            ? '家里还有 ${q.stock} 个 · 借出 ${q.lent} 个未还'
            : '家里共 ${q.stock} 个');
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
                // V3.8：删除借出记录（进回收站，可撤销）。文字按钮无图标，
                // 触控区 48dp，危险操作色写死。
                TextButton(
                  key: Key('loan_delete_${loan.id ?? loan.itemName}'),
                  onPressed: _busy ? null : () => _confirmDeleteLoan(loan),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xffc62828),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(48, 40),
                  ),
                  child: const Text(
                    '删除',
                    style: TextStyle(color: Color(0xffc62828), fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // V3.8：位置标签——PM 真机反馈「归还的物品没有位置标签」。
            Text(
              locations.isEmpty ? '位置：未记录' : '位置：${locations.join('、')}',
              style: const TextStyle(fontSize: 12.5, color: Color(0xff37474f)),
            ),
            // V3.10：账实一目了然——家里还有几个、还能借几个。
            if (stockText != null) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                stockText,
                style: const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
              ),
            ],
            const SizedBox(height: 2),
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

  /// V3.8：删除借出记录 → 软删进回收站，Snackbar 提供「撤销」。
  Future<void> _confirmDeleteLoan(Loan loan) async {
    final id = loan.id;
    if (id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除借出记录？'),
        content: Text(
          '「${loan.itemName} → ${loan.borrowerName}」这条借出记录会移进回收站，'
          '可在回收站恢复。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('loan_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    await widget.repository.deleteLoan(id);
    if (!mounted) return;
    await _reload();
    setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除借出记录：${loan.itemName} → ${loan.borrowerName}'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => _restoreLoan(id),
        ),
      ),
    );
  }

  /// 撤销删除（从回收站恢复）。
  Future<void> _restoreLoan(int id) async {
    await widget.repository.restoreLoan(id);
    if (!mounted) return;
    await _reload();
  }

  Future<void> _showLendDialog() async {
    final itemController = TextEditingController();
    final borrowerController = TextEditingController();
    final quantityController = TextEditingController(text: '1');
    final daysController = TextEditingController(
        text: '${InventoryDatabase.defaultLoanDays}');
    final formKey = GlobalKey<FormState>();

    // V3.10：可借数（按物品名异步查）。
    // 提示与校验都依赖这两个值，用 ValueNotifier 局部刷新对话框。
    final dialogState = ValueNotifier<int?>(null);
    final missingNotifier = ValueNotifier<bool>(false);

    Future<void> refreshAvailability(String name) async {
      final key = normalizeName(name);
      if (key.isEmpty) {
        dialogState.value = null;
        missingNotifier.value = false;
        return;
      }
      final info = await widget.repository.getQuantityInfo(key);
      final exists = await widget.repository.findByName(key);
      dialogState.value = exists == null ? null : info.available;
      missingNotifier.value = exists == null;
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
        title: const Text('新借出'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ValueListenableBuilder<int?>(
                  valueListenable: dialogState,
                  builder: (context, avail, _) {
                    return ValueListenableBuilder<bool>(
                      valueListenable: missingNotifier,
                      builder: (context, missing, __) {
                        return TextFormField(
                          key: const Key('lend_item_field'),
                          controller: itemController,
                          // V3.10：填了物品名就提示可借几个，超借当场拦。
                          onChanged: (v) => refreshAvailability(v),
                          decoration: InputDecoration(
                            labelText: '物品名',
                            helperText: missing
                                ? '还没记录过这件东西，请先在明细里记一笔'
                                : (avail != null ? '可借 $avail 个' : null),
                            helperStyle: TextStyle(
                              fontSize: 12,
                              color: missing ? Colors.red : null,
                            ),
                          ),
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return '请填物品名';
                            if (missing) return '还没记录过这件东西，请先记一笔';
                            return null;
                          },
                        );
                      },
                    );
                  },
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
                      child: ValueListenableBuilder<int?>(
                        valueListenable: dialogState,
                        builder: (context, avail, _) => TextFormField(
                          key: const Key('lend_quantity_field'),
                          controller: quantityController,
                          decoration: const InputDecoration(labelText: '数量'),
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            if (n == null || n < 1) return '至少 1';
                            // V3.10（PM 拍板②）：借超拦截，不允许负数。
                            if (avail != null && n > avail) {
                              return '最多借 $avail 个';
                            }
                            return null;
                          },
                        ),
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
      ),
    );
    if (result != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.repository.lendItem(
        normalizeName(itemController.text),
        normalizeName(borrowerController.text),
        quantity: int.tryParse(quantityController.text) ?? 1,
        days: int.tryParse(daysController.text),
      );
    } on ArgumentError catch (e) {
      // V3.10：借超 / 没记录过 —— 友好中文提示，不弹技术错误。
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message is String ? e.message : '借出没成功，什么都没改。'),
        ),
      );
      return;
    }
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
