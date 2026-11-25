// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';

/// V3.11「校准数量」清点页（元宝批复第 5 条：按位置分别清点，不降级）。
///
/// 每件物品列出它的所有位置，每个位置各填「这里有几个」（默认当前值）；
/// 可以当场新增位置行（发现车库还有 1 个）。底部实时显示
/// 「加起来 N · 在借 M · 一共 N+M」。保存后逐位置写数量，
/// 总数由数据层 _syncItemTotal 自动求和——在借数只展示、不重复扣减。
class CalibrationPage extends StatefulWidget {
  const CalibrationPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<CalibrationPage> createState() => _CalibrationPageState();
}

/// 一行位置输入：可能是已有位置（有 locationId），也可能是新加的（name 手填）。
class _PosRow {
  _PosRow({this.locationId, required this.name, required this.controller});
  final int? locationId;
  final String name;
  final TextEditingController controller;
}

class _CalibrationPageState extends State<CalibrationPage> {
  /// 物品 id → 位置输入行。
  final Map<int, List<_PosRow>> _rowsByItem = <int, List<_PosRow>>{};

  final Map<int, String> _names = <int, String>{};
  final Map<int, QuantityInfo> _infos = <int, QuantityInfo>{};
  final Map<int, List<String>> _borrowers = <int, List<String>>{};

  /// 新增位置行用的名字控制器：item id → 控制器列表（与 _rowsByItem 末尾对应）。
  final Map<int, List<TextEditingController>> _newNameControllers =
      <int, List<TextEditingController>>{};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final rows in _rowsByItem.values) {
      for (final r in rows) {
        r.controller.dispose();
      }
    }
    for (final cs in _newNameControllers.values) {
      for (final c in cs) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.getAllItemsWithLocations();
      final infos = await widget.repository.getAllQuantityInfo();
      final loans = await widget.repository.getAllLoans();
      if (!mounted) return;
      final borrowers = <int, List<String>>{};
      for (final loan in loans) {
        final outstanding = loan.quantity - loan.returnedQty;
        if (outstanding <= 0) continue;
        final row = rows.where((r) => r.item.name == loan.itemName).firstOrNull;
        final id = row?.item.id;
        if (id == null) continue;
        (borrowers[id] ??= <String>[]).add('${loan.borrowerName}（$outstanding 个）');
      }
      // 释放旧控制器。
      for (final rs in _rowsByItem.values) {
        for (final r in rs) {
          r.controller.dispose();
        }
      }
      for (final cs in _newNameControllers.values) {
        for (final c in cs) {
          c.dispose();
        }
      }
      _rowsByItem.clear();
      _newNameControllers.clear();

      setState(() {
        _names.clear();
        _infos.clear();
        _borrowers.clear();
        for (final row in rows) {
          final id = row.item.id;
          if (id == null) continue;
          _names[id] = row.item.name;
          final info = infos[id] ??
              QuantityInfo(
                stock: row.item.quantity,
                lent: 0,
                available: row.item.quantity,
              );
          _infos[id] = info;
          _borrowers[id] = borrowers[id] ?? const <String>[];

          final posRows = <_PosRow>[];
          for (final loc in row.locations) {
            final qty = (loc.id != null ? row.quantityAt(loc.id!) : null) ??
                row.item.quantity;
            posRows.add(_PosRow(
              locationId: loc.id,
              name: loc.name,
              controller: TextEditingController(text: '$qty'),
            ));
          }
          // 位置数量为 0 或没有任何位置时，仍给一行可填。
          if (posRows.isEmpty) {
            posRows.add(_PosRow(
              name: '',
              controller: TextEditingController(text: '0'),
            ));
            _newNameControllers[id] = <TextEditingController>[
              TextEditingController(),
            ];
          } else {
            _newNameControllers[id] = <TextEditingController>[];
          }
          _rowsByItem[id] = posRows;
        }
        _loading = false;
        _error = null;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// 现有行之和（不含新增行）。
  int _sumFor(int itemId) {
    var sum = 0;
    for (final r in _rowsByItem[itemId] ?? const <_PosRow>[]) {
      sum += int.tryParse(r.controller.text.trim()) ?? 0;
    }
    return sum;
  }

  void _addPositionRow(int itemId) {
    setState(() {
      _rowsByItem[itemId]!.add(_PosRow(
        name: '',
        controller: TextEditingController(text: '0'),
      ));
      _newNameControllers[itemId]!.add(TextEditingController());
    });
  }

  Future<void> _save() async {
    final locationTotals = <int, Map<int, int>>{};
    // 新增位置：item id → (位置名, 数量)。
    final newPositions = <int, List<_NewPos>>{};
    for (final entry in _rowsByItem.entries) {
      final id = entry.key;
      final nameControllers = _newNameControllers[id] ?? const <TextEditingController>[];
      final map = <int, int>{};
      var newIndex = 0;
      for (final r in entry.value) {
        final qty = int.tryParse(r.controller.text.trim());
        if (qty == null || qty < 0) {
          if (!mounted) return;
          setState(() {
            _error = '「${_names[id] ?? ''}」的位置数量得填非负整数。';
          });
          return;
        }
        if (r.locationId != null) {
          map[r.locationId!] = qty;
        } else {
          // 新增位置：名字必填。
          final typed = newIndex < nameControllers.length
              ? nameControllers[newIndex].text.trim()
              : '';
          newIndex++;
          if (typed.isEmpty) {
            if (!mounted) return;
            setState(() {
              _error = '「${_names[id] ?? ''}」新增的位置要填名字。';
            });
            return;
          }
          (newPositions[id] ??= <_NewPos>[]).add(_NewPos(typed, qty));
        }
      }
      if (map.isNotEmpty) locationTotals[id] = map;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // 先建新位置，拿到 id 后并入 locationTotals。
      for (final entry in newPositions.entries) {
        for (final np in entry.value) {
          final locId = await widget.repository.addLocation(np.name);
          (locationTotals[entry.key] ??= <int, int>{})[locId] = np.qty;
        }
      }
      final report = await widget.repository.calibrateQuantities(
        locationTotals: locationTotals,
      );
      if (!mounted) return;
      final detail = report.details.isEmpty ? '' : '\n${report.details.join('\n')}';
      setState(() => _saving = false);
      if (!mounted) return;
      Navigator.of(context).pop(
        report.isNoop
            ? '数量已经是对齐的，没有需要改的。'
            : '校准完成，改正了 ${report.changedCount} 件。$detail',
      );
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '校准失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('校准数量'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _names.isEmpty
              ? Center(child: Text(_error!))
              : Column(
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '这页是干嘛的：老版本记的数量不准，照家里实物数一遍，把数量改对。\n'
                        '怎么填：每件东西下面按位置分开填「这里有几个」（借出去没在家的不算）。\n'
                        '发现东西还在别处？点「＋加个位置」补一行。\n'
                        '最底下会实时算好「加起来 N · 在借 M · 一共 N+M」，核对无误点保存。\n'
                        '填得比原来少？少的那几个会自动进回收站（还能恢复），不会凭空消失。',
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(_error!,
                            style: const TextStyle(color: Colors.red)),
                      ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: _rows(),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: FilledButton(
                          key: const Key('calibration_save'),
                          onPressed: _saving ? null : _save,
                          child: Text(_saving ? '保存中…' : '保存校准'),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  List<Widget> _rows() {
    final ids = _names.keys.toList()..sort();
    if (ids.isEmpty) {
      return <Widget>[
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('还没有录入任何物品。')),
        ),
      ];
    }
    return ids.map((id) {
      final info = _infos[id] ?? const QuantityInfo(stock: 0, lent: 0, available: 0);
      final who = _borrowers[id] ?? const <String>[];
      final rows = _rowsByItem[id] ?? const <_PosRow>[];
      final newNameControllers =
          _newNameControllers[id] ?? const <TextEditingController>[];
      final sum = _sumFor(id);
      return Card(
        key: Key('calibration_row_$id'),
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _names[id] ?? '',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '当前账面：在库 ${info.stock} 个'
                '${info.lent > 0 ? ' · 在借 ${info.lent} 个' : ''}',
                style: const TextStyle(fontSize: 12),
              ),
              if (who.isNotEmpty)
                Text('借给：${who.join('、')}',
                    style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              for (final row in rows)
                _positionField(id, row, newNameControllers),
              TextButton.icon(
                key: Key('calibration_add_position_$id'),
                onPressed: () => _addPositionRow(id),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('＋加个位置'),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xfff0f7ff),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '加起来 $sum 个'
                  '${info.lent > 0 ? ' · 在借 ${info.lent} 个 · 一共 ${sum + info.lent} 个' : ' · 没借出去'}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  key: Key('calibration_sum_$id'),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  /// 单个位置输入行。已有位置显示名字，新增位置显示可编辑名字框。
  Widget _positionField(
    int itemId,
    _PosRow row,
    List<TextEditingController> newNameControllers,
  ) {
    final isNew = row.locationId == null;
    // 新增行对应的名字控制器按出现顺序取。
    final order = _rowsByItem[itemId]!
        .where((r) => r.locationId == null)
        .toList()
        .indexOf(row);
    final nameController = isNew && order < newNameControllers.length
        ? newNameControllers[order]
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 96,
            child: isNew
                ? TextField(
                    key: Key('calibration_newpos_name_${itemId}_$order'),
                    controller: nameController,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: '位置名',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  )
                : Text(row.name,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          const Text('放', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          SizedBox(
            width: 64,
            child: TextField(
              key: Key('calibration_field_${itemId}_${row.locationId ?? 'new$order'}'),
              controller: row.controller,
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}), // 实时刷新合计
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text('个', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _NewPos {
  const _NewPos(this.name, this.qty);
  final String name;
  final int qty;
}
