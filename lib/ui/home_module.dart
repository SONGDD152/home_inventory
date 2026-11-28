import 'package:flutter/material.dart';

import '../data/domain.dart';

/// V4.0：一级模块的种类。
///
/// 主体（页面内容）按种类分派，**不按模块硬编码**——
/// 这样「工作区按需长出模块」只需往注册表加一项，不用改主体逻辑。
enum ModuleKind {
  /// 仓储主体（物品/位置/借出/回收站那套账）。
  storage,

  /// 建设中占位（点进去只有一句"建设中"，不做假功能）。
  building,
}

/// V4.0：域内一级模块（底栏一项）。
///
/// 模块是**按域注册**的：生活区固定三项（V4.2.0 三域骨架：仓储/衣橱/餐饮，
/// 衣橱/餐饮为建设中占位、**不隐藏**）；工作区按需长出（本轮只有工作仓储）；
/// 知识域零模块（点顶栏直接进域壳页）。
///
/// V4.1 批次 4：生活区由五项减为四项——**「日程」被删掉**。
/// 日程不是消失，是**上移到概览层**（概览页双签的「日程」签，
/// 跨域展示 + 可创建/编辑/删除）——见 [ScheduleTabView]。
/// 底栏那一项曾经指向的 `SchedulePage` 已随之删除（无入口即孤儿页，
/// 与 V4.0 日报孤儿页同一类问题）。
class DomainModule {
  const DomainModule({
    required this.id,
    required this.label,
    required this.icon,
    required this.kind,
  });

  /// 模块标识（**选中态按 id 记，不按索引**——增删模块不会让选中态错位）。
  final String id;

  /// 底栏显示文案（工作区的仓储叫「工作仓储」，与生活区区分）。
  final String label;

  /// 底栏图标。
  final IconData icon;

  /// 主体种类。
  final ModuleKind kind;

  /// 抽屉里该模块的副标题用名（沿用「XX模块」口径）。
  String get drawerTitle => '$label模块';
}

/// V4.0：某域的模块注册表。
///
/// V4.2.0 三域骨架（PM 2026-11-28 终审拍板）：生活区底栏**三栏**——
/// 仓储（真实）/ 衣橱（建设中）/ 餐饮（建设中），**「知识库」项撤下**——
/// 知识库提平为顶栏第四栏独立域（全名「知识系统」），不占底栏。
///
/// V4.1 批次 4：**「日程」项已删**——日程上移概览层，不再占生活区底栏。
///
/// 工作区：按需长出 —— 本轮只显示工作仓储；将来加模块自动出现在底栏。
/// 知识域：**零模块**（无底栏）——点顶栏「知识」直接进域壳页
/// （`modulesOf` 返回空列表，界面据此不渲染底栏、主体给建设中壳页）。
List<DomainModule> modulesOf(InventoryDomain domain) {
  switch (domain) {
    case InventoryDomain.life:
      return const <DomainModule>[
        DomainModule(
          id: 'storage',
          label: '仓储',
          icon: Icons.inventory_2,
          kind: ModuleKind.storage,
        ),
        DomainModule(
          id: 'wardrobe',
          label: '衣橱',
          icon: Icons.checkroom,
          kind: ModuleKind.building,
        ),
        DomainModule(
          id: 'dining',
          label: '餐饮',
          icon: Icons.restaurant,
          kind: ModuleKind.building,
        ),
      ];
    case InventoryDomain.work:
      // 工作区模块待定（PM 原话），本轮只上工作仓储。
      return const <DomainModule>[
        DomainModule(
          id: 'storage',
          label: '工作仓储',
          icon: Icons.work_outline,
          kind: ModuleKind.storage,
        ),
      ];
    case InventoryDomain.knowledge:
      // 知识域无底栏模块（PM 2026-11-28 拍板：知识系统区不占底栏）。
      // 库与功能随 +36 知识库功能版落地；届时模块在此登记即自动出现。
      return const <DomainModule>[];
  }
}

/// 按 id 找模块（选中态还原用）。
DomainModule? moduleById(InventoryDomain domain, String id) {
  for (final module in modulesOf(domain)) {
    if (module.id == id) return module;
  }
  return null;
}

/// V4.0：建设中占位页。
///
/// 只说一句"建设中"，**不做假功能、不进空白页**（沿用 V3.5 决策点③）。
class BuildingPlaceholderPage extends StatelessWidget {
  const BuildingPlaceholderPage({
    super.key,
    required this.label,
    this.text,
  });

  /// 标识名（进 widget key；模块用模块名，域壳页用域全名如「知识系统」）。
  final String label;

  /// 展示文案；缺省按 V4.0 口径「$label模块建设中，敬请期待」。
  /// V4.2.0：域壳页传自定义文案（知识系统是域不是模块，不写「模块」二字）。
  final String? text;

  @override
  Widget build(BuildContext context) {
    final shown = text ?? '$label模块建设中，敬请期待';
    return Center(
      key: Key('building_page_$label'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.construction, size: 40, color: Colors.grey),
          const SizedBox(height: 12),
          Text(shown,
              key: Key('building_page_text_$label'),
              style: const TextStyle(fontSize: 15, color: Colors.grey)),
        ],
      ),
    );
  }
}
