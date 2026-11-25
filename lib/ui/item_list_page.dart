// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/excel_exporter.dart';
import '../data/inventory_repository.dart';
import '../data/item.dart';
import '../data/normalize.dart';
import 'backup_actions.dart';
import 'trash_page.dart';

/// 物品明细页：浏览全部物品及其位置，支持按物品名/位置名过滤；
/// V3.2 起每条物品支持编辑（改名）与删除；
/// V3.6 起删除统一为**软删进回收站**（左滑或按钮，二次确认后
/// 物品行与"删除时活跃"关联行留底，可在回收站恢复），不再物理清除；
/// 右上角回收站入口 + 底部「导出Excel」；
/// 备份导出/恢复入口在**底部固定操作区**（不再放右上角图标，
/// 避免边缘/安全区吞掉入口），完整说明见独立「数据备份与恢复」页。
class ItemListPage extends StatefulWidget {
  const ItemListPage({
    super.key,
    required this.repository,
    this.gateway,
    this.exporter,
    this.title = '物品明细',
  });

  final InventoryRepository repository;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// V3.6：Excel 导出器；生产默认 [ExcelExporter]，测试注入临时目录实现。
  final ExcelExporter? exporter;

  final String title;

  @override
  State<ItemListPage> createState() => _ItemListPageState();
}

class _ItemListPageState extends State<ItemListPage> {
  final TextEditingController _searchController = TextEditingController();

  List<ItemWithLocations>? _rows;
  String? _error;
  bool _busy = false;

  /// V3.10：数量三口径（按物品 id 索引）。
  Map<int, QuantityInfo> _quantities = const <int, QuantityInfo>{};

  /// V3.10（PM 拍板①）：借空的物品默认折叠，勾选「含已借出」才显示。
  bool _showLentOut = false;

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
      final quantities = await widget.repository.getAllQuantityInfo();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _quantities = quantities;
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

  /// V3.10：某件物品的数量信息（没有则按 1 个处理）。
  QuantityInfo _quantityOf(ItemWithLocations row) {
    final id = row.item.id;
    if (id == null) {
      return QuantityInfo(stock: row.item.quantity, lent: 0, available: row.item.quantity);
    }
    return _quantities[id] ??
        QuantityInfo(stock: row.item.quantity, lent: 0, available: row.item.quantity);
  }

  /// 过滤：物品名或任一位置名包含关键词（归一化后 contains，与存储同源）。
  ///
  /// V3.10（PM 拍板①）：借空的物品（在库数 = 0）默认不显示，
  /// 勾选「含已借出」才列出——它们并没有丢，只是全借出去了。
  List<ItemWithLocations> _filtered() {
    final rows = _rows ?? const <ItemWithLocations>[];
    final keyword = normalizeName(_searchController.text);
    var result = rows;
    if (keyword.isNotEmpty) {
      result = result
          .where((row) =>
              normalizeName(row.item.name).contains(keyword) ||
              row.locations
                  .any((loc) => normalizeName(loc.name).contains(keyword)))
          .toList(growable: false);
    }
    if (!_showLentOut) {
      result = result
          .where((row) => _quantityOf(row).stock > 0)
          .toList(growable: false);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            key: const Key('trash_entry'),
            tooltip: '回收站',
            icon: const Icon(Icons.restore_from_trash_outlined),
            onPressed: _busy ? null : _openTrash,
          ),
        ],
      ),
      // 底部固定操作区：导出/恢复不再依赖右上角图标，SafeArea 兜住手势区。
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: BackupActions(
            repository: widget.repository,
            gateway: widget.gateway,
            onRestored: _reload,
            onExportExcel: _saveExcel,
            onShareExcel: _shareExcel,
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
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: <Widget>[
                // V3.10（PM 拍板①）：借空的物品默认折叠，勾这个才显示。
                FilterChip(
                  key: const Key('detail_show_lent_out'),
                  label: const Text('含已借出'),
                  selected: _showLentOut,
                  onSelected: (v) => setState(() => _showLentOut = v),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _rows == null
                        ? '加载中…'
                        : '共 ${rows.length} 件物品 · ${_filteredRecordCount(rows)} 条存放记录',
                    key: const Key('detail_stats'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(rows)),
        ],
      ),
    );
  }

  int _filteredRecordCount(List<ItemWithLocations> rows) =>
      rows.fold(0, (n, r) => n + r.locations.length);

  /// V3.10：列表项标题——物品名 + 数量 + 借出标注。
  ///
  /// 「梯子 ×3」表示家里有 3 个；「梯子 ×2（在借 1）」表示 2 个在家、
  /// 1 个借出去了。全借空时显示「×0（全借出）」。
  String _itemTitle(ItemWithLocations row) {
    final q = _quantityOf(row);
    final name = row.item.name;
    if (q.lent > 0) {
      return '$name ×${q.stock}（在借 ${q.lent}）';
    }
    if (q.stock > 1) {
      return '$name ×${q.stock}';
    }
    return name;
  }

  // ---------- V3.6 回收站 / Excel 导出 ----------

  Future<void> _openTrash() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TrashPage(repository: widget.repository),
        fullscreenDialog: false,
      ),
    );
    // 回收站内恢复/彻底删除后，返回明细页刷新列表与统计。
    await _reload();
  }

  /// V3.7：借出明细导出数据（loans + 物品 id→位置名映射）。
  /// 复用明细页已加载的 _rows 构造映射，避免额外全表查询。
  Future<({List<Loan> loans, Map<int, String> locationByItem})>
      _loanExportData() async {
    final loans = await widget.repository.getAllLoans();
    final locationByItem = <int, String>{};
    for (final row in _rows ?? const <ItemWithLocations>[]) {
      final id = row.item.id;
      if (id == null) continue;
      locationByItem[id] = row.locations.isEmpty
          ? '（无位置）'
          : row.locations.map((l) => l.name).join('、');
    }
    return (loans: loans, locationByItem: locationByItem);
  }

  /// V3.6.1：点击导出 Excel = 直接保存到手机（SAF）。
  /// 工作簿字节直接从 buildWorkbook 取（无需落临时盘），写用户所选位置。
  Future<void> _saveExcel() async {
    final gateway = widget.gateway ?? SystemBackupGateway();
    setState(() => _busy = true);
    try {
      final exporter = widget.exporter ?? const ExcelExporter();
      final activeRows = _rows ?? const <ItemWithLocations>[];
      final deletedRows = await widget.repository.getDeletedItems();
      final loanData = await _loanExportData();
      final bytes = exporter.buildWorkbook(activeRows, deletedRows,
          loans: loanData.loans, locationByItem: loanData.locationByItem);
      final fileName = exporter.fileNameFor(DateTime.now());
      final saved = await gateway.saveBytesToDevice(fileName, bytes);
      if (!mounted) return;
      if (saved == null) {
        // 用户取消：静默。
        setState(() => _busy = false);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$fileName')),
      );
    } catch (_) {
      // 兜住 Error + Exception（磁盘满/权限/ROM 拒绝），失败必须明确提示。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法保存，请改用分享（长按导出按钮）')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  /// V3.6.1：长按 Excel = 走原系统分享面板（生成 xlsx 后 shareFile）。
  Future<void> _shareExcel() async {
    final gateway = widget.gateway ?? SystemBackupGateway();
    setState(() => _busy = true);
    try {
      final activeRows = _rows ?? const <ItemWithLocations>[];
      final deletedRows = await widget.repository.getDeletedItems();
      final loanData = await _loanExportData();
      final path = await (widget.exporter ?? const ExcelExporter())
          .writeExcelFile(activeRows, deletedRows,
              loans: loanData.loans,
              locationByItem: loanData.locationByItem);
      await gateway.shareFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel 已生成：${path.split('/').last}')),
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

  // ---------- V3.2 编辑 / V3.6 软删（决策点①A：语义统一进回收站） ----------

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除物品'),
        content: Text('确定删除物品「${row.item.name}」吗？\n'
            '删除后可在回收站查看或恢复。'),
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
        // V3.6：左滑软删（决策点①A：与删除按钮同语义，均进回收站）。
        // confirmDismiss 必须 await 二次确认防误触；确认后走 deleteItem
        // 并整体刷新（统计数字随之更新）。
        return Dismissible(
          key: Key('swipe_item_${row.item.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('删除',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                SizedBox(width: 8),
                Icon(Icons.delete_outline, color: Colors.white),
              ],
            ),
          ),
          confirmDismiss: (direction) async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('删除物品'),
                content: Text(
                    '确定删除物品「${row.item.name}」吗？\n删除后可在回收站恢复。'),
                actions: <Widget>[
                  TextButton(
                    key: const Key('swipe_delete_cancel'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    key: const Key('swipe_delete_confirm'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            );
            if (confirmed != true || !mounted) return false;
            await widget.repository.deleteItem(row.item.id!);
            await _reload();
            return true;
          },
          child: ListTile(
            key: Key('detail_item_${row.item.name}'),
            // V3.10：标题带上数量——「梯子 ×3」，借出的另标注。
            title: Text(_itemTitle(row)),
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
          ),
        );
      },
    );
  }
}
