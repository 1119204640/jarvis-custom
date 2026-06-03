import 'package:flutter/material.dart';
import 'models/queue_job.dart';
import 'screens/home_screen.dart';
import 'widgets/queue_status_bar.dart';

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
      // QueueStatusBar 通过 builder 放在所有路由的底部
      builder: (context, child) {
        return Column(
          children: [
            Expanded(child: child!),
            ValueListenableBuilder<List<QueueJob>>(
              valueListenable: GlobalQueueState.notifier,
              builder: (context, jobs, child) => QueueStatusBar(jobs: jobs),
            ),
          ],
        );
      },
    );
  }
}
