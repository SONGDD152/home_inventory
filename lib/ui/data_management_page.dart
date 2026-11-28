// ignore_for_file: deprecated_member_use
// Flutter 3.50 将 material.dart 标记为 deprecated，Material 组件本版本仍可用。
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/backup_gateway.dart';
import '../data/domain.dart';
import '../data/excel_export_kit.dart';
import '../data/excel_exporter.dart';
import '../data/inventory_repository.dart';
import '../data/item_docx_exporter.dart';
import '../domain/full_system_backup.dart';
import 'backup_page.dart';
import 'full_system_backup_panel.dart';

/// V4.2.3（+36 终审边界）：数据管理签内容——**整页纵向滚动，四区模块**。
///
/// PM 终审边界（2026-11-28 拍板）：
/// - 概览页「日程」签右侧新增「数据管理」签，为数据导入导出的**唯一集散入口**；
/// - 签内布局**整页纵向滚动**：四区模块（系统区/生活区/工作区/知识区）
///   从上到下依次排列，**不做横向切页、不做顶部 tab 切换、不弹新页**；
/// - 抽屉「数据管理」入口撤掉（不再双入口），原「数据备份与恢复」入口
///   改为跳转到本签；
/// - 物品明细页底部「导出 Excel」按钮撤掉（Excel 导出收归生活/工作区）；
/// - 系统区 = 全系统备份/恢复（**三域 JSON：生活+工作+知识**，+34 行为
///   一字不改：校验前置、长按分享、逐域分行提示、误装互拒指路）；
/// - 生活/工作区 = 分区备份/恢复 + Excel 导出 + Word 文档导出；
/// - 知识区 = 备份/恢复**通道**（+35 不建库不接 Writer，按钮置灰提示，
///   知识库功能版建库后启用）；
/// - 日报导出**不归本签**（日报走自己的导出按钮）。
///
/// 写边界：本视图由组合根构建并注入概览页（概览只收 Widget 不持仓储），
/// 全部写操作走各区块既有链路（BackupActions/FullSystemBackupPanel），
/// 逻辑一行没重写。
class DataManagementView extends StatefulWidget {
  const DataManagementView({
    super.key,
    required this.lifeRepository,
    this.workRepository,
    this.gateway,
    this.onRestored,
    this.fullSystem,
    this.excelExporter,
    this.wordFileWriter,
  });

  /// 生活区仓储（生活区备份/恢复/Excel/Word 的对象）。
  final InventoryRepository lifeRepository;

  /// 工作区仓储；null = 工作区未启用（单域模式，工作区显示提示）。
  final InventoryRepository? workRepository;

  /// 备份交互网关；生产默认系统实现，测试注入假网关。
  final BackupGateway? gateway;

  /// 恢复成功后的回调（V4.1.7 铁律：恢复=清空重灌，首页必须刷新）。
  final Future<void> Function()? onRestored;

  /// V4.2.1（+34）：全系统备份服务；null = 系统区显示提示
  /// （单域注入时的行为，与旧 BackupPage 同口径）。
  final FullSystemBackup? fullSystem;

  /// Excel 导出器；生产默认按域构建，测试注入临时目录实现。
  final ExcelExporter? excelExporter;

  /// Word 落盘注入（长按分享用，与 excelExporter 同构）。
  final Future<String> Function(Uint8List bytes)? wordFileWriter;

  @override
  State<DataManagementView> createState() => _DataManagementViewState();
}

class _DataManagementViewState extends State<DataManagementView> {
  bool _busy = false;

  BackupGateway get _gateway => widget.gateway ?? SystemBackupGateway();

  // ---- 生活区 / 工作区：Excel 与 Word 导出（点击=保存，长按=分享） ----

  Future<void> _saveExcel(InventoryRepository repository,
      InventoryDomain domain) async {
    setState(() => _busy = true);
    try {
      final kit = ExcelExportKit(domain: domain, exporter: widget.excelExporter);
      final bytes = await kit.buildWorkbookBytes(repository: repository);
      final fileName = kit.fileName(DateTime.now());
      final saved = await _gateway.saveBytesToDevice(fileName, bytes);
      if (!mounted) return;
      if (saved == null) {
        setState(() => _busy = false);
        return; // 用户取消：静默。
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$fileName')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法保存，请改用分享（长按导出按钮）')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _shareExcel(InventoryRepository repository,
      InventoryDomain domain) async {
    setState(() => _busy = true);
    try {
      final kit = ExcelExportKit(domain: domain, exporter: widget.excelExporter);
      final path = await kit.writeWorkbookFile(repository: repository);
      await _gateway.shareFile(path);
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

  Future<void> _saveWord(
      InventoryRepository repository, InventoryDomain domain) async {
    setState(() => _busy = true);
    try {
      final exporter = ItemDocxExporter(domain: domain);
      final bytes = await exporter.build(repository: repository);
      final fileName = exporter.fileName(DateTime.now());
      final saved = await _gateway.saveBytesToDevice(fileName, bytes);
      if (!mounted) return;
      if (saved == null) {
        setState(() => _busy = false);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存：$fileName')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法保存，请改用分享（长按导出按钮）')),
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
  }

  Future<void> _shareWord(
      InventoryRepository repository, InventoryDomain domain) async {
    setState(() => _busy = true);
    try {
      final exporter = ItemDocxExporter(
        domain: domain,
        fileWriter: widget.wordFileWriter,
      );
      final path = await exporter.writeDocxFile(repository: repository);
      await _gateway.shareFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文档已生成：${path.split('/').last}')),
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

  // ---- 区块构建 ----

  Widget _sectionHeader(String title, {String? note}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        if (note != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(note,
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  /// 生活/工作区通用区块：分区备份/恢复（BackupPageBody 原样复用）
  /// + Excel 导出 + Word 文档导出。
  Widget _domainSection({
    required InventoryDomain domain,
    required InventoryRepository repository,
  }) {
    final tag = domain.id;
    return Container(
      key: Key('data_section_$tag'),
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // label 已含「区」字（生活区/工作区），直接用，不再拼。
          _sectionHeader(domain.label,
              note: '本区账本的备份/恢复，以及 Excel、Word 文档导出。'),
          // 分区备份主体：与旧 BackupPage 分区形态一字不差（fullSystem=null）。
          BackupPageBody(
            repository: repository,
            gateway: widget.gateway,
            domain: domain,
            onRestored: widget.onRestored,
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: GestureDetector(
                  key: Key('data_${tag}_excel_export'),
                  onLongPress:
                      _busy ? null : () => _shareExcel(repository, domain),
                  child: FilledButton.tonalIcon(
                    onPressed:
                        _busy ? null : () => _saveExcel(repository, domain),
                    icon: const Icon(Icons.table_view),
                    label: const Text('导出 Excel'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  key: Key('data_${tag}_word_export'),
                  onLongPress:
                      _busy ? null : () => _shareWord(repository, domain),
                  child: FilledButton.tonalIcon(
                    onPressed:
                        _busy ? null : () => _saveWord(repository, domain),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('导出 Word'),
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '长按导出按钮可分享给好友',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fullSystem = widget.fullSystem;
    final workRepo = widget.workRepository;
    return SingleChildScrollView(
      key: const Key('data_management_scroll'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ---- 区①：系统区（全系统备份，推荐）----
          Container(
            key: Key('data_section_system'),
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _sectionHeader('系统区 · 全系统备份（推荐）',
                    note: '生活+工作+知识三域一份 JSON：一次导出、一次恢复，'
                        '迁移/换机不用来回切区域。'),
                if (fullSystem != null)
                  FullSystemBackupPanel(
                    service: fullSystem,
                    gateway: widget.gateway,
                    onRestored: widget.onRestored,
                  )
                else
                  const Text(
                    '当前未提供全系统备份（需生活区+工作区双域一起启用）。'
                    '分区备份请用下方各区入口。',
                    style: TextStyle(fontSize: 13, color: Colors.grey),
                  ),
              ],
            ),
          ),
          const Divider(),
          // ---- 区②：生活区 ----
          _domainSection(
              domain: InventoryDomain.life,
              repository: widget.lifeRepository),
          const Divider(),
          // ---- 区③：工作区 ----
          if (workRepo != null)
            _domainSection(
                domain: InventoryDomain.work, repository: workRepo)
          else
            Container(
              key: Key('data_section_work'),
              padding: const EdgeInsets.only(bottom: 24),
              child: _sectionHeader('工作区', note: '工作区未启用（单域模式）。'),
            ),
          const Divider(),
          // ---- 区④：知识区（+35 通道，不建库不接 Writer）----
          Container(
            key: Key('data_section_knowledge'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _sectionHeader('知识区',
                    note: '知识库建库后，这里的备份/恢复自动生效；'
                        '全系统备份文件已预留知识分区，不会丢数据。'),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('data_knowledge_backup_disabled'),
                        onPressed: null,
                        icon: const Icon(Icons.ios_share),
                        label: const Text('知识备份'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('data_knowledge_restore_disabled'),
                        onPressed: null,
                        icon: const Icon(Icons.restore),
                        label: const Text('知识恢复'),
                      ),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    '知识库建库后开放（当前仅通道，未建库不接写入口）',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
