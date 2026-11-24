// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';

/// V3.6：回收站页面（全屏子页，从物品明细页右上角图标进入）。
///
/// 展示全部已删物品（is_deleted=1，按删除时间倒序），每条两个操作：
/// 「恢复」（软删物品行+删除时活跃关联行复活，位置关系还原；
/// 撞名失败提示）与「彻底删除」（红色，二次确认，物理清除不可恢复）。
/// 顶部「全部清空」一键物理清除回收站全部条目（二次确认）。
/// 空态「回收站为空」。
///
/// V3.8：新增「已删除的借出记录」区块——借出记录也可删除（PM 真机反馈：
/// 真机上被错误句式污染的借出记录没法清理），删除后进本回收站，
/// 可恢复或彻底删除；「全部清空」连带清空。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<ItemWithLocations>? _rows;
  List<Loan>? _loans;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final rows = await widget.repository.getDeletedItems();
      final loans = await widget.repository.getDeletedLoans();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loans = loans;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = const <ItemWithLocations>[];
        _loans = const <Loan>[];
        _error = '加载失败：$e';
      });
    }
  }

  /// 操作统一兜底：ArgumentError（Error 非 Exception）单独 catch，
  /// 文案展示 e.message（恢复撞名「已存在同名物品，恢复失败」走这里）。
  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败：${e.message ?? e}')),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('操作失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<bool> _confirm(String title, String content,
      {String confirmLabel = '确认'}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _restore(ItemWithLocations row) async {
    await _guard(() => widget.repository.restoreItem(row.item.id!));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已恢复「${row.item.name}」到物品明细。')),
    );
  }

  Future<void> _purgeItem(ItemWithLocations row) async {
    final confirmed = await _confirm(
      '彻底删除',
      '彻底删除「${row.item.name}」？\n其全部位置记录（含历史）将一并清除，'
          '此操作不可恢复。',
      confirmLabel: '彻底删除',
    );
    if (!confirmed || !mounted) return;
    await _guard(() => widget.repository.purgeItem(row.item.id!));
  }

  Future<void> _purgeAll() async {
    final confirmed = await _confirm(
      '全部清空',
      '将彻底删除回收站全部物品（含其位置记录），此操作不可恢复。',
      confirmLabel: '全部清空',
    );
    if (!confirmed || !mounted) return;
    await _guard(() => widget.repository.purgeAll());
  }

  String _deletedAtLabel(ItemWithLocations row) {
    final at = row.item.deletedAt;
    if (at == null) return '删除时间：—（历史记录）';
    final t = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '删除时间：${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows ?? const <ItemWithLocations>[];
    final loans = _loans ?? const <Loan>[];
    return Scaffold(
      appBar: AppBar(
        title: Text('回收站（${rows.length + loans.length}）'),
        actions: <Widget>[
          TextButton.icon(
            key: const Key('trash_purge_all'),
            onPressed: _busy || (rows.isEmpty && loans.isEmpty)
                ? null
                : _purgeAll,
            icon: const Icon(Icons.delete_forever, size: 18),
            label: const Text('全部清空'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
      body: _buildBody(rows, loans),
    );
  }

  Widget _buildBody(List<ItemWithLocations> rows, List<Loan> loans) {
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty && loans.isEmpty) {
      return const Center(
        child: Text(
          '回收站为空',
          key: Key('trash_empty'),
        ),
      );
    }
    return ListView(
      key: const Key('trash_list'),
      children: <Widget>[
        if (loans.isNotEmpty) ...<Widget>[
          _sectionHeader('已删除的借出记录（${loans.length}）'),
          for (final loan in loans) _buildLoanCard(loan),
        ],
        if (rows.isNotEmpty) ...<Widget>[
          _sectionHeader('已删除的物品（${rows.length}）'),
          for (final row in rows) _buildItemCard(row),
        ],
      ],
    );
  }

  /// 区块标题（纯文字，无图标）。
  Widget _sectionHeader(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: Color(0xff1b5e20),
        ),
      ),
    );
  }

  /// V3.8：已删除的借出记录卡片（恢复 / 彻底删除）。
  Widget _buildLoanCard(Loan loan) {
    final id = loan.id ?? 0;
    return Card(
      key: Key('trash_loan_$id'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '${loan.itemName} ×${loan.quantity}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '借给：${loan.borrowerName.isEmpty ? '—' : loan.borrowerName}'
              ' · 借出 ${_loanDate(loan.borrowedAt)}'
              ' · 已还 ${loan.returnedQty}/${loan.quantity}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                OutlinedButton.icon(
                  key: Key('trash_loan_restore_$id'),
                  onPressed: _busy ? null : () => _restoreLoan(loan),
                  icon: const Icon(Icons.restore, size: 18, color: Color(0xff1b5e20)),
                  label: const Text('恢复',
                      style: TextStyle(color: Color(0xff1b5e20))),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xffe8f5e9),
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(72, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: Key('trash_loan_purge_$id'),
                  onPressed: _busy ? null : () => _purgeLoan(loan),
                  icon: const Icon(Icons.delete_forever,
                      size: 18, color: Color(0xffc62828)),
                  label: const Text('彻底删除',
                      style: TextStyle(color: Color(0xffc62828))),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xfffdecea),
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(96, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// V3.8：恢复已删除的借出记录。
  Future<void> _restoreLoan(Loan loan) async {
    final id = loan.id;
    if (id == null) return;
    await _guard(() => widget.repository.restoreLoan(id));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已恢复借出记录：${loan.itemName} → ${loan.borrowerName}')),
    );
  }

  /// V3.8：彻底删除一条借出记录。
  Future<void> _purgeLoan(Loan loan) async {
    final id = loan.id;
    if (id == null) return;
    final confirmed = await _confirm(
      '彻底删除',
      '彻底删除「${loan.itemName} → ${loan.borrowerName}」这条借出记录？'
      '此操作不可恢复。',
      confirmLabel: '彻底删除',
    );
    if (!confirmed || !mounted) return;
    await _guard(() => widget.repository.purgeLoan(id));
  }

  /// 借出日期（本地显示，月/日）。
  String _loanDate(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month}/${t.day}';
  }
  /// V3.6：已删除的物品卡片（恢复 / 彻底删除）。
  Widget _buildItemCard(ItemWithLocations row) {
    // V3.6 补丁：单条操作改为「独立一行 + 文字标签」按钮。
    // 原实现把两个纯图标 IconButton 塞在 ListTile.trailing，三行长文本旁
    // 图标不显眼，真机验收反馈找不到按钮。文字标签 + 整行可见彻底解决。
    // key 全部保留，既有测试断言不破。
    // V3.6.1 布局优化（元宝批复落实）：
    // ① 元信息从两行压成单行（ellipsis），长按气泡给完整位置——防超长位置名误判；
    // ② 按钮从各占一半的描边大块改为右对齐 chip（浅绿/淡红填充底），
    //    危险操作（彻底删除）视觉权重低于安全操作（恢复）；
    // ③ 触控区硬锁 48dp（元宝驳回 42dp：危险操作偏安全侧）；
    // ④ 间距层级：物品名↔元信息(2) < 元信息↔按钮(8)，形成主体/附属层级。
    // 可见性防护同源复用：色写死在 Icon/Text 本体，不经主题继承；key 全保留。
    return Card(
      key: Key('trash_item_${row.item.name}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              row.item.name,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Tooltip(
              key: Key('trash_meta_${row.item.name}'),
              triggerMode: TooltipTriggerMode.longPress,
              message: row.locations.isEmpty
                  ? '无位置记录'
                  : '原位置：${row.locations.map((l) => l.name).join('、')}（含历史）',
              child: Text(
                row.locations.isEmpty
                    ? '${_deletedAtLabel(row)}（无位置记录）'
                    : '${_deletedAtLabel(row)} · 原位置：${row.locations.map((l) => l.name).join('、')}（含历史）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                OutlinedButton.icon(
                  key: Key('trash_restore_${row.item.name}'),
                  onPressed: _busy ? null : () => _restore(row),
                  // 色写死在 Icon/Text 本体（V3.5 吞色防护），填充底浅绿。
                  icon: const Icon(Icons.restore,
                      size: 18, color: Color(0xff1b5e20)),
                  label: const Text('恢复',
                      style: TextStyle(color: Color(0xff1b5e20))),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xffe8f5e9),
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(72, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  key: Key('trash_purge_${row.item.name}'),
                  onPressed: _busy ? null : () => _purgeItem(row),
                  // 危险操作：淡红填充底 + 深红字，对比度 4.92（AA 达标）；
                  // 视觉权重低于「恢复」的饱和绿，防喧宾夺主。
                  icon: const Icon(Icons.delete_forever,
                      size: 18, color: Color(0xffc62828)),
                  label: const Text('彻底删除',
                      style: TextStyle(color: Color(0xffc62828))),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: const Color(0xfffdecea),
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(96, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
