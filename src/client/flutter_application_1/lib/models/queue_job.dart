import 'package:flutter/material.dart';

/// 文件处理队列中的单个任务。
class QueueJob {
  final String jobId;
  final String name;
  final String status; // queued | processing | done | error
  final String stage;
  final String mode; // create | update

  const QueueJob({
    required this.jobId,
    required this.name,
    required this.status,
    required this.stage,
    required this.mode,
  });

  factory QueueJob.fromJson(Map<String, dynamic> json) {
    return QueueJob(
      jobId: json['job_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      stage: json['stage'] as String? ?? '',
      mode: json['mode'] as String? ?? 'create',
    );
  }

  bool get isActive => status == 'queued' || status == 'processing';
  bool get isDone => status == 'done';
  bool get isError => status == 'error';
}

/// 全局文件队列状态 — ChatService 检测到变化时更新，
/// QueueStatusBar 通过 MaterialApp.builder 订阅并展示。
class GlobalQueueState {
  static final ValueNotifier<List<QueueJob>> notifier = ValueNotifier([]);
}
