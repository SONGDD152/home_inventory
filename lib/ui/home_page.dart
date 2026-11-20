// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';

/// 家庭仓储 APP 第一版界面：单页分块，录入 + 精确名称查询。
///
/// 范围边界（产品与技术负责人已确认）：
///  * 三张表：物品 / 位置 / 关联；位置从已有位置中选，可新增位置；
///  * 只认精确名称，不做语义解析；不做删除、语音、多端同步；
///  * 单人本地。
///
/// [repository] 由外部注入，便于测试注入内存实现（见 InventoryRepository）。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.repository, this.title = '家庭仓储'});

  final InventoryRepository repository;
  final String title;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _newLocationController = TextEditingController();
  final TextEditingController _queryController = TextEditingController();

  List<Location> _locations = <Location>[];
  int? _selectedLocationId;
  String? _notice;
  ItemWithLocations? _result;
  bool _busy = false;

  static const String _emptyName = '请填写物品名称';
  static const String _emptyLocation = '请填写存放位置';
  static const String _needLocation = '请先选择或新增一个位置';
  static const String _notFoundPrefix = '没找到「';

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _newLocationController.dispose();
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    final locations = await widget.repository.getAllLocations();
    if (!mounted) return;
    setState(() {
      _locations = locations;
      // 默认选中第一个，减少一步操作；没有位置时留空。
      _selectedLocationId ??= locations.isEmpty ? null : locations.first.id;
    });
  }

  Future<void> _addLocation() async {
    final name = _newLocationController.text;
    if (name.trim().isEmpty) {
      _show(_emptyLocation);
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await widget.repository.addLocation(name);
      if (!mounted) return;
      _newLocationController.clear();
      await _loadLocations();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selectedLocationId = id;
        _notice = '已添加位置：${name.trim()}';
        _result = null;
      });
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = e.name == '位置名称' ? _emptyLocation : '$e';
      });
    }
  }

  Future<void> _save() async {
    final name = _nameController.text;
    if (name.trim().isEmpty) {
      _show(_emptyName);
      return;
    }
    final locationId = _selectedLocationId;
    if (locationId == null) {
      _show(_needLocation);
      return;
    }

    setState(() => _busy = true);
    try {
      final result =
          await widget.repository.upsertItemLocation(name, locationId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = result.created ? '已记下：$name → ${_locationName(locationId)}' : '这条已经记过了';
      });
      _nameController.clear();
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = e.name == '物品名称' ? _emptyName : '$e';
      });
    }
  }

  Future<void> _query() async {
    final name = _queryController.text;
    if (name.trim().isEmpty) {
      _show(_emptyName);
      return;
    }

    setState(() => _busy = true);
    final found = await widget.repository.findByName(name);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = found;
      _notice = found == null ? '$_notFoundPrefix${name.trim()}」' : null;
    });
  }

  String _locationName(int id) =>
      _locations.where((l) => l.id == id).map((l) => l.name).firstOrNull ?? '';

  void _show(String message) {
    setState(() {
      _notice = message;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('记下物品',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              key: const Key('name_field'),
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '物品名称',
                hintText: '例如：梯子',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text('选择存放位置：', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final location in _locations)
                  ChoiceChip(
                    key: Key('location_chip_${location.id}'),
                    label: Text(location.name),
                    selected: _selectedLocationId == location.id,
                    onSelected: _busy
                        ? null
                        : (_) => setState(
                              () => _selectedLocationId = location.id,
                            ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('new_location_field'),
                    controller: _newLocationController,
                    decoration: const InputDecoration(
                      labelText: '新增位置',
                      hintText: '例如：储物间',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const Key('add_location_button'),
                  onPressed: _busy ? null : _addLocation,
                  child: const Text('添加位置'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('save_button'),
              onPressed: _busy ? null : _save,
              child: const Text('记下'),
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 8),
            const Text('找东西',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              key: const Key('query_field'),
              controller: _queryController,
              decoration: const InputDecoration(
                labelText: '物品名称（精确）',
                hintText: '例如：梯子',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _query(),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const Key('query_button'),
              onPressed: _busy ? null : _query,
              child: const Text('查找'),
            ),
            if (_notice != null) ...[
              const SizedBox(height: 12),
              Text(_notice!, key: const Key('notice')),
            ],
            if (_result != null) ...[
              const SizedBox(height: 8),
              Text('「${_result!.item.name}」放在：',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final location in _result!.locations)
                ListTile(
                  key: Key('result_location_${location.id}'),
                  leading: const Icon(Icons.place_outlined),
                  title: Text(location.name),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
