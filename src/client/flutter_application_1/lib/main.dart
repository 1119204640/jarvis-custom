import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

/// 应用入口 — 启动 Jarvis AI 秘书客户端
void main() {
  runApp(const JarvisApp());
}

/// 根组件：配置 MaterialApp 主题并加载主页面
class JarvisApp extends StatelessWidget {
  const JarvisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jarvis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Material You 风格：给一个种子颜色，自动推导整套调色板
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
