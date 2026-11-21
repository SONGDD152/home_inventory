// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';

/// 物品明细页：只读浏览全部物品及其位置，支持按物品名/位置名过滤；
/// AppBar 内提供备份导出（系统分享）与恢复（文件选择器 + 确认框）。
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

  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

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

  // ---------- 备份导出 ----------

  Future<void> _exportBackup() async {
    setState(() => _busy = true);
    try {
      final backup = await widget.repository.exportBackup();
      final path = await _gateway
          .writeBackupFile(const JsonEncoder.withIndent('  ').convert(backup));
      await _gateway.shareFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // 路径分隔符双兼容（Windows \ 与 POSIX /），只取文件名展示。
          content: Text('备份已生成：${path.split('/').last.split('\\').last}'),
        ),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  // ---------- 备份恢复 ----------

  Future<void> _startRestore() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复备份'),
        content: const Text(
          '将从备份文件覆盖当前全部数据。\n\n'
          '建议先点「导出备份」留存当前数据，'
          '再选择要恢复的 .json 文件。',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('restore_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('restore_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('选择文件并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final path = await _gateway.pickBackupFile();
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final raw = await _gateway.readBackupFile(path);
      final data = jsonDecode(raw) as Map<String, dynamic>;
      await widget.repository.restoreBackup(data);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('恢复完成。')),
      );
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：不是有效的备份 JSON（${e.message}）')),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：$e')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final rows = _filtered();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            key: const Key('export_backup'),
            onPressed: _busy ? null : _exportBackup,
            tooltip: '导出备份',
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            key: const Key('restore_backup'),
            onPressed: _busy ? null : _startRestore,
            tooltip: '恢复备份',
            icon: const Icon(Icons.restore),
          ),
        ],
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
          trailing: Text('${row.locations.length} 处'),
        );
      },
    );
  }
}
