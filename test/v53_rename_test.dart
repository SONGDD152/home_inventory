// V4.1.6 改名专项：展示名「小本本」+ 包名 com.danfeng.xiaobenben（PM 2026-11-28 拍板）。
// 源码级锁：改名是迁移工程，任何一处回退都会让迁移演练失真——锁死。
// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('源码级锁①：applicationId 已换成 com.danfeng.xiaobenben，namespace 未动', () {
    final gradle =
        File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle.contains('applicationId = "com.danfeng.xiaobenben"'), isTrue,
        reason: '包身份（决定私有目录路径）');
    // D1：namespace 是代码结构名，刻意不动——改了会连锁 Kotlin 目录，无收益。
    expect(gradle.contains('namespace = "com.songdd.homeinventory.home_inventory"'),
        isTrue, reason: 'namespace 保持不动（D1 拍板）');
    expect(gradle.contains('com.songdd.homeinventory.home_inventory"') &&
        gradle.contains('applicationId = "com.songdd'),
        isFalse,
        reason: 'applicationId 不得残留旧值');
  });

  test('源码级锁②：桌面名 Manifest label = 小本本', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest.contains('android:label="小本本"'), isTrue);
    expect(manifest.contains('android:label="home_inventory"'), isFalse);
  });

  test('源码级锁③：lib/ 内「家庭仓储」文案清零（含注释）', () {
    final dir = Directory('lib');
    final offenders = <String>[];
    for (final f in dir.listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.readAsStringSync().contains('家庭仓储')) offenders.add(f.path);
    }
    expect(offenders, isEmpty, reason: 'D2 拍板：全改「小本本」，一处不残留');
  });

  test('源码级锁④：版号 4.2.3+36（V4.2.3 数据管理终审版；+35 为上一形态已上线）', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: 4.2.3+36'));
    expect(pubspec, contains('name: home_inventory'),
        reason: 'pubspec name 是 Dart 包名，刻意不动（改动=全仓 import 连锁）');
  });

  test('源码级锁⑤：应用标题与导出文件名前缀 = 小本本', () {
    expect(File('lib/main.dart').readAsStringSync(), contains("title: '小本本'"));
    final report = File('lib/ui/daily_report_page.dart').readAsStringSync();
    expect(report, contains("'小本本日报-"));
    final backup = File('lib/ui/backup_actions.dart').readAsStringSync();
    expect(backup, contains("return '小本本-\${widget.domain.storageLabel}-"));
  });
}
