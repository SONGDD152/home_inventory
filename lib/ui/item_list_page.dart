// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';
import 'backup_actions.dart';

/// 物品明细页：浏览全部物品及其位置，支持按物品名/位置名过滤；
/// V3.2 起每条物品支持编辑（改名）与删除（二次确认，物理清除其位置记录）；
/// 备份导出/恢复入口在**底部固定操作区**（不再放右上角图标，
/// 避免边缘/安全区吞掉入口），完整说明见独立「数据备份与恢复」页。
class ItemListPage extends StatefulWidget {
  const ItemListPage({
    super.key,
    required this.repository,
    this.gateway,
    this.title = '物品明细',
  });

  final InventoryRepository repository;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  final String title;

  @override
  State<ItemListPage> createState() => _ItemListPageState();
}

class _ItemListPageState extends State<ItemListPage> {
  final TextEditingController _searchController = TextEditingController();

  List<ItemWithLocations>? _rows;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final rows = await widget.repository.getAllItemsWithLocations();
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

  /// 过滤：物品名或任一位置名包含关键词（归一化后 contains，与存储同源）。
  List<ItemWithLocations> _filtered() {
    final rows = _rows ?? const <ItemWithLocations>[];
    final keyword = normalizeName(_searchController.text);
    if (keyword.isEmpty) return rows;
    return rows
        .where((row) =>
            normalizeName(row.item.name).contains(keyword) ||
            row.locations
                .any((loc) => normalizeName(loc.name).contains(keyword)))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      // 底部固定操作区：导出/恢复不再依赖右上角图标，SafeArea 兜住手势区。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BackupActions(
            repository: widget.repository,
            gateway: widget.gateway,
            onRestored: _reload,
            compact: true,
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              key: const Key('detail_search'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜物品名或位置名',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _rows == null
                    ? '加载中…'
                    : '共 ${rows.length} 件物品 · ${_filteredRecordCount(rows)} 条存放记录',
                key: const Key('detail_stats'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Expanded(child: _buildBody(rows)),
        ],
      ),
    );
  }

  int _filteredRecordCount(List<ItemWithLocations> rows) =>
      rows.fold(0, (n, r) => n + r.locations.length);

  // ---------- V3.2 编辑/删除 ----------

  /// 操作统一兜底：校验类错误是 ArgumentError（Error 非 Exception），
  /// 必须 on ArgumentError 单独 catch，文案展示 e.message（沿用惯例）。
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

  Future<void> _editItem(ItemWithLocations row) async {
    final controller = TextEditingController(text: row.item.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑物品'),
        content: TextField(
          key: const Key('item_edit_name_field'),
          controller: controller,
          decoration: const InputDecoration(
            labelText: '物品名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = controller.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('物品名称不能为空。')),
      );
      return;
    }
    await _guard(() => widget.repository.updateItem(row.item.id!, name));
  }

  Future<void> _deleteItem(ItemWithLocations row) async {
    final n = row.locations.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除物品'),
        content: Text('确定删除物品「${row.item.name}」吗？\n'
            '将同时清除它在 $n 处的位置记录（含历史记录），此操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            key: const Key('item_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('item_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _guard(() => widget.repository.deleteItem(row.item.id!));
  }

  Widget _buildBody(List<ItemWithLocations> rows) {
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_rows == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      final allEmpty = (_rows ?? const <ItemWithLocations>[]).isEmpty;
      return Center(
        child: Text(
          allEmpty ? '还没有记录。回首页说一句"XX放YY"试试。' : '没有匹配的物品。换个关键词试试。',
          key: const Key('detail_empty'),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      key: const Key('detail_list'),
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        return ListTile(
          key: Key('detail_item_${row.item.name}'),
          title: Text(row.item.name),
          subtitle: row.locations.isEmpty
              ? const Text('（没有有效位置）')
              : Text(
                  row.locations.map((loc) => loc.name).join('、'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('${row.locations.length} 处'),
              IconButton(
                key: Key('item_edit_${row.item.name}'),
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _busy ? null : () => _editItem(row),
              ),
              IconButton(
                key: Key('item_delete_${row.item.name}'),
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : () => _deleteItem(row),
              ),
            ],
          ),
        );
      },
    );
  }
}
