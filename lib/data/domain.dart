/// V4.0 多域架构：域标识（物理分库的地基）。
///
/// PM 2026-11-26 拍板：**工作仓储采用物理分库**——生活域与工作域各持独立
/// `.db` 文件，两本账互不相通。因此「域」在本 App 里不是一个 UI 上的筛选条件，
/// 而是**一份独立的账本**：独立的库文件、独立的备份、独立的守恒口径。
///
/// 这里只放纯数据（枚举 + 文案 + 文件名），不含任何行为，
/// 便于数据层、UI 层、语音层共用同一套域定义。
library;

/// 应用内的域。
enum InventoryDomain {
  /// 生活域：家庭仓储（沿用既有库文件 `home_inventory.db`，用户数据天然保留）。
  life(
    id: 'life',
    label: '生活区',
    storageLabel: '生活',
    fileName: 'home_inventory.db',
  ),

  /// 工作域：工作仓储（新建库文件 `work_inventory.db`，走 onCreate 建全套表）。
  work(
    id: 'work',
    label: '工作区',
    storageLabel: '工作',
    fileName: 'work_inventory.db',
  );

  const InventoryDomain({
    required this.id,
    required this.label,
    required this.storageLabel,
    required this.fileName,
  });

  /// 机器可读标识（写进备份 JSON 的 `domain` 字段，跨域恢复校验用）。
  final String id;

  /// UI 文案：顶栏分段控件、抽屉副标题用。
  final String label;

  /// 备份/导出文件名里的域标识（如 `家庭仓储-生活-20261126.json`）。
  final String storageLabel;

  /// 该域对应的数据库文件名。
  final String fileName;

  /// 按标识解析域；未知标识返回 null（备份校验用）。
  static InventoryDomain? fromId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final domain in InventoryDomain.values) {
      if (domain.id == id) return domain;
    }
    return null;
  }
}

/// 切域进行中导致的写操作拒绝。
///
/// 切库守卫在切换期间**直接拒绝写入**（不静默重试——静默重试可能写进错库）。
/// UI 层单独 catch 这个异常，提示「正在切换，请稍候」，
/// 不与普通 ArgumentError 混在一起。
class DomainSwitchInProgress implements Exception {
  const DomainSwitchInProgress();

  @override
  String toString() => '正在切换区域，请稍候';
}

/// 域能力开关：哪些功能在哪个域开放。
///
/// V4.0：两域**表结构完全一致**（各 8 张表，逐表逐列核对），
/// 但产品上**功能开放范围不同**——工作域本轮不开放提醒/日程。
/// 注意：这是**能力开关**，不是"表不存在"：
/// 说「工作区提醒我明天交周报」时，报错文案是「工作区暂不支持提醒」，
/// 而不是"表缺失"这种技术口吻。
///
/// ## V4.1.1 整改 3：工作域**开放提醒**
///
/// PM 2026-11-27 真机手点发现：**新建提醒一律落生活区**，工作区没有入口，
/// 属「分区破口」。整改后**两域都能新建提醒**，
/// 新建时**必选区域**（二选一，不选不能存），落哪本账由用户明确表态。
///
/// 物理分库下 `reminders` 表**每库一张**（工作库那张一直建着、只是没人写），
/// 所以开放工作域**不需要动 schema**——它本来就在。
enum DomainCapability {
  /// 提醒条目 + 日程 + 日报。
  reminders,

  /// 仓储账目（两个域都开放，这是 App 的本行）。
  storage,
}

/// 各域的能力开关。
///
/// - 生活域：全开（仓储 + 提醒/日程/日报）。
/// - 工作域：**整改 3 后也开放提醒**（V4.1 之前只开仓储）。
///   语音跨域落库时，提醒直接落工作库，不再需要「是否切换到生活区」的引导。
const Map<InventoryDomain, Set<DomainCapability>> domainCapabilities =
    <InventoryDomain, Set<DomainCapability>>{
  InventoryDomain.life: <DomainCapability>{
    DomainCapability.storage,
    DomainCapability.reminders,
  },
  InventoryDomain.work: <DomainCapability>{
    DomainCapability.storage,
    DomainCapability.reminders,
  },
};

/// 某域是否开放某能力。
bool domainSupports(InventoryDomain domain, DomainCapability capability) =>
    domainCapabilities[domain]?.contains(capability) ?? false;
