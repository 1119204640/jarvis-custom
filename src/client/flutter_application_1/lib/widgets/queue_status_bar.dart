import 'package:flutter/material.dart';
import '../models/queue_job.dart';

/// 全局面板 — 展示文件处理队列中各文件的状态。
///
/// 显示在页面底部，对所有子页面可见。
/// 队列为空时自动隐藏，有任务时以水平滚动的状态条展示。
class QueueStatusBar extends StatelessWidget {
  final List<QueueJob> jobs;

  const QueueStatusBar({super.key, required this.jobs});

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) return const SizedBox.shrink();

    final activeJobs = jobs.where((j) => j.isActive).toList();
    final doneJobs = jobs.where((j) => !j.isActive).toList();

    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- 活跃任务 --
            if (activeJobs.isNotEmpty)
              SizedBox(
                height: 26,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: activeJobs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => _JobChip(job: activeJobs[i]),
                ),
              ),
            // -- 已完成/失败的任务 (收纳折叠) --
            if (doneJobs.isNotEmpty) ...[
              if (activeJobs.isNotEmpty) const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: doneJobs.map((j) => _JobChip(job: j, dimmed: true)).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _JobChip extends StatelessWidget {
  final QueueJob job;
  final bool dimmed;

  const _JobChip({required this.job, this.dimmed = false});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget icon;
    Color? color;
    switch (job.status) {
      case 'queued':
        icon = Icon(Icons.schedule, size: 12, color: cs.onSurfaceVariant);
        color = cs.surfaceContainerHighest;
        break;
      case 'processing':
        icon = SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: cs.primary,
          ),
        );
        color = cs.primaryContainer;
        break;
      case 'done':
        icon = Icon(Icons.check_circle, size: 12, color: Colors.green);
        color = null; // 使用 dimmed 处理
        break;
      case 'error':
        icon = Icon(Icons.error, size: 12, color: cs.error);
        color = null;
        break;
      default:
        icon = const SizedBox(width: 12, height: 12);
        color = null;
    }

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: dimmed
            ? cs.surfaceContainerHighest.withAlpha(120)
            : (color ?? cs.surfaceContainerHighest),
        borderRadius: BorderRadius.circular(12),
        border: !dimmed && job.status == 'processing'
            ? Border.all(color: cs.primary.withAlpha(80))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              job.name,
              style: TextStyle(
                fontSize: 11,
                color: dimmed ? cs.onSurfaceVariant.withAlpha(150) : cs.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (job.stage.isNotEmpty && !dimmed) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                job.stage,
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurfaceVariant.withAlpha(180),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: chip,
    );
  }
}
