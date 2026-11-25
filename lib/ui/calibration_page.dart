// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/inventory_repository.dart';
import '../data/item.dart';

/// V3.10「校准数量」清点页（PM 2026-11-24 补充要求 2）。
///
/// 背景：V3.7 引入数量后，录入的数量一直被丢弃，老库的 `items.quantity`
/// 恒为 1，跟真实家底对不上；V3.10 起数量才真正参与借还账。
/// 但**真实家底只存在于用户脑子里**，App 没法自己算出来——
/// 所以这个页面的做法是：让用户照着实物清点，填「家里一共几个」，
/// App 减掉借出去的那部分，写回真正的在库数。
///
/// 口径（与数据层 `calibrateQuantities` 一致）：
///  * 输入 = 总拥有数（家里一共几个）
///  * 写入 = 在库数 = 总拥有数 − 未归还借出数（下限 0）
///
/// 幂等：同样的清点值反复校准，结果不变；老物品、新物品同一套公式。
class CalibrationPage extends StatefulWidget {
  const CalibrationPage({super.key, required this.repository});

  final InventoryRepository repository;

  @override
  State<CalibrationPage> createState() => _CalibrationPageState();
}

class _CalibrationPageState extends State<CalibrationPage> {
  /// 待清点的物品：id → 物品名。
  final Map<int, String> _names = <int, String>{};

  /// 物品 id → 数量三口径。
  final Map<int, QuantityInfo> _infos = <int, QuantityInfo>{};

  /// 物品 id → 借走的人（用于提示「在借 2 个，给了张三、李四」）。
  final Map<int, List<String>> _borrowers = <int, List<String>>{};

  /// 物品 id → 用户填的「家里一共几个」。
  final Map<int, TextEditingController> _controllers =
      <int, TextEditingController>{};

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
    for (final c in _controllers.values) {
      c.dispose();
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
      setState(() {
        _names.clear();
        _infos.clear();
        _borrowers.clear();
        for (final c in _controllers.values) {
          c.dispose();
        }
        _controllers.clear();
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
          // 默认填当前账面总拥有数——用户只在需要时改成真实清点值。
          _controllers[id] = TextEditingController(text: '${info.total}');
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

  Future<void> _save() async {
    final totals = <int, int>{};
    for (final entry in _controllers.entries) {
      final text = entry.value.text.trim();
      final parsed = int.tryParse(text);
      if (parsed == null) {
        if (!mounted) return;
        setState(() {
          _error = '「${_names[entry.key] ?? ''}」的数量得填个数字。';
        });
        return;
      }
      if (parsed < 0) {
        if (!mounted) return;
        setState(() {
          _error = '「${_names[entry.key] ?? ''}」的数量不能是负数。';
        });
        return;
      }
      totals[entry.key] = parsed;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final report = await widget.repository.calibrateQuantities(totals: totals);
      if (!mounted) return;
      final detail = report.details.isEmpty ? '' : '\n${report.details.join('\n')}';
      setState(() {
        _saving = false;
        _error = null;
      });
      if (!mounted) return;
      // 回首页前把结果带回去，如实说明改了几件。
      Navigator.of(context).pop(
        report.isNoop ? '数量已经是对齐的，没有需要改的。' : '校准完成，改正了 ${report.changedCount} 件。$detail',
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
                        '照着实物清点，填「家里一共几个」。\n'
                        '借出去的会从在库里扣掉，填完点保存。',
                        style: TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
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
                Text(
                  '借给：${who.join('、')}',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Text('家里一共几个：', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: Key('calibration_field_$id'),
                      controller: _controllers[id],
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
