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
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<ItemWithLocations>? _rows;
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
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = const <ItemWithLocations>[];
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
    return Scaffold(
      appBar: AppBar(
        title: Text('回收站（${rows.length}）'),
        actions: <Widget>[
          TextButton.icon(
            key: const Key('trash_purge_all'),
            onPressed: _busy || rows.isEmpty ? null : _purgeAll,
            icon: const Icon(Icons.delete_forever, size: 18),
            label: const Text('全部清空'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      ),
      body: _buildBody(rows),
    );
  }

  Widget _buildBody(List<ItemWithLocations> rows) {
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      return const Center(
        child: Text(
          '回收站为空',
          key: Key('trash_empty'),
        ),
      );
    }
    return ListView.builder(
      key: const Key('trash_list'),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        // V3.6 补丁：单条操作改为「独立一行 + 文字标签」按钮。
        // 原实现把两个纯图标 IconButton 塞在 ListTile.trailing，三行长文本旁
        // 图标不显眼，真机验收反馈找不到按钮。文字标签 + 整行可见彻底解决。
        // key 全部保留，既有测试断言不破。
        return Card(
          key: Key('trash_item_${row.item.name}'),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  row.item.name,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  row.locations.isEmpty
                      ? '${_deletedAtLabel(row)}\n（无位置记录）'
                      : '${_deletedAtLabel(row)}\n原位置：${row.locations.map((l) => l.name).join('、')}（含历史）',
                  style: const TextStyle(fontSize: 12.5, color: Color(0xff607d8b)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: Key('trash_restore_${row.item.name}'),
                        onPressed: _busy ? null : () => _restore(row),
                        // 补丁（真机可见性缺陷）：色写死在 Icon/Text 本体，
                        // 不经主题继承链——与 V3.5 三道杠同类问题，主题色
                        // 被吞会让图标/文字与背景同色、指尖能按但肉眼看不见。
                        icon: const Icon(Icons.restore,
                            size: 18, color: Color(0xff1b5e20)),
                        label: const Text('恢复',
                            style: TextStyle(color: Color(0xff1b5e20))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xff1b5e20)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: Key('trash_purge_${row.item.name}'),
                        onPressed: _busy ? null : () => _purgeItem(row),
                        icon: const Icon(Icons.delete_forever,
                            size: 18, color: Color(0xffc62828)),
                        label: const Text('彻底删除',
                            style: TextStyle(color: Color(0xffc62828))),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xffc62828)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
