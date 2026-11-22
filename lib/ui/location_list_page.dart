// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';

/// 位置管理页（V3.1 导航新增）：位置列表 + 新增 + 改名/备注 + 删除。
///
/// 复用数据层既有 API（addLocation/updateLocation/deleteLocation），
/// 归一化仍由仓储边界负责；删除为软删，二次确认后执行。
class LocationListPage extends StatefulWidget {
  const LocationListPage({
    super.key,
    required this.repository,
    this.title = '位置管理',
  });

  final InventoryRepository repository;

  final String title;

  @override
  State<LocationListPage> createState() => _LocationListPageState();
}

class _LocationListPageState extends State<LocationListPage> {
  List<Location>? _locations;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final locations = await widget.repository.getAllLocations();
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _locations = const <Location>[];
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
    } on ArgumentError catch (e) {
      // 仓储校验（如归一化后名称为空）抛 ArgumentError（Error 非 Exception）。
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

  // ---------- 新增 ----------

  Future<void> _addLocation() async {
    final controller = TextEditingController();
    final remarkController = TextEditingController();
    final ok = await _formDialog(
      title: '添加位置',
      confirmText: '添加',
      fields: <_FieldSpec>[
        _FieldSpec(
          key: 'location_name_field',
          controller: controller,
          label: '位置名称',
          hint: '例如：储物间',
        ),
        _FieldSpec(
          key: 'location_remark_field',
          controller: remarkController,
          label: '备注（可选）',
          hint: '例如：阳台柜子第二层',
        ),
      ],
    );
    if (!ok || !mounted) return;
    final name = controller.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('位置名称不能为空。')),
      );
      return;
    }
    final remark =
        remarkController.text.trim().isEmpty ? null : remarkController.text.trim();
    await _guard(() => widget.repository.addLocation(name, remark: remark));
  }

  // ---------- 编辑（改名 + 备注） ----------

  Future<void> _editLocation(Location location) async {
    final controller = TextEditingController(text: location.name);
    final remarkController = TextEditingController(text: location.remark ?? '');
    final ok = await _formDialog(
      title: '编辑位置',
      confirmText: '保存',
      fields: <_FieldSpec>[
        _FieldSpec(
          key: 'location_name_field',
          controller: controller,
          label: '位置名称',
          hint: null,
        ),
        _FieldSpec(
          key: 'location_remark_field',
          controller: remarkController,
          label: '备注',
          hint: null,
        ),
      ],
    );
    if (!ok || !mounted) return;
    final name = controller.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('位置名称不能为空。')),
      );
      return;
    }
    await _guard(() => widget.repository.updateLocation(
          location.id!,
          name: name,
          remark: remarkController.text.trim(),
        ));
  }

  // ---------- 删除 ----------

  Future<void> _deleteLocation(Location location) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除位置'),
        content: Text('确定删除位置「${location.name}」吗？\n'
            '物品记录不会被删除，但该位置将不再显示；\n'
            '相关位置记录将一并移除（V3.2 联动清理）。'),
        actions: <Widget>[
          TextButton(
            key: const Key('location_delete_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const Key('location_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _guard(() => widget.repository.deleteLocation(location.id!));
  }

  // ---------- 表单对话框 ----------

  Future<bool> _formDialog({
    required String title,
    required String confirmText,
    required List<_FieldSpec> fields,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final spec in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  key: Key(spec.key),
                  controller: spec.controller,
                  decoration: InputDecoration(
                    labelText: spec.label,
                    hintText: spec.hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_location_fab'),
        onPressed: _busy ? null : _addLocation,
        icon: const Icon(Icons.add),
        label: const Text('添加位置'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_locations == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_locations!.isEmpty) {
      return const Center(
        child: Text(
          '还没有位置。点右下角「添加位置」，或回首页说一句"XX放YY"自动创建。',
          key: Key('location_empty'),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      key: const Key('location_list'),
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: _locations!.length,
      itemBuilder: (context, index) {
        final location = _locations![index];
        return ListTile(
          key: Key('location_item_${location.name}'),
          leading: const Icon(Icons.place_outlined),
          title: Text(location.name),
          subtitle: (location.remark == null || location.remark!.isEmpty)
              ? null
              : Text(location.remark!),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                key: Key('location_edit_${location.name}'),
                tooltip: '编辑',
                icon: const Icon(Icons.edit_outlined),
                onPressed: _busy ? null : () => _editLocation(location),
              ),
              IconButton(
                key: Key('location_delete_${location.name}'),
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : () => _deleteLocation(location),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FieldSpec {
  const _FieldSpec({
    required this.key,
    required this.controller,
    required this.label,
    required this.hint,
  });

  final String key;
  final TextEditingController controller;
  final String label;
  final String? hint;
}
