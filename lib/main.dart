// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

import 'data/inventory_database.dart';
import 'ui/home_page.dart';

/// 应用入口：生产使用 sqflite 默认工厂，注入到界面。
///
/// 测试不走这里，而是直接构造 HomePage 并注入临时文件库。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = InventoryDatabase();
  runApp(HomeInventoryApp(database: database));
}

class HomeInventoryApp extends StatelessWidget {
  const HomeInventoryApp({super.key, required this.database});

  final InventoryDatabase database;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '家庭仓储布局',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
      home: HomePage(repository: database),
    );
  }
}
