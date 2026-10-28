import 'package:flutter/material.dart';
import '../services/recording_upload.dart';

class RecordingUploadSummary extends StatelessWidget {
  const RecordingUploadSummary({
    super.key,
    required this.participantId,
    required this.onOpen,
  });

  final String participantId;
  final ValueChanged<RecordingUpload> onOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<RecordingUpload>>(
      valueListenable: RecordingUpload.recent,
      builder: (context, jobs, _) {
        final visible = jobs
            .where(
              (job) =>
                  job.classId != null && job.participantId == participantId,
            )
            .toList();
        if (visible.isEmpty) return const SizedBox.shrink();
        final job = visible.last;
        return ListenableBuilder(
          listenable: job,
          builder: (context, _) => Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onOpen(job),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 550),
                      transitionBuilder: (child, animation) => ScaleTransition(
                        scale: animation,
                        child: FadeTransition(opacity: animation, child: child),
                      ),
                      child: Icon(
                        job.completed ? Icons.check_circle : Icons.cloud_upload,
                        key: ValueKey(job.completed),
                        color: job.completed
                            ? Colors.green
                            : Theme.of(context).colorScheme.primary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            job.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            job.completed
                                ? 'Upload complete • View videos'
                                : job.label,
                          ),
                          if (!job.completed) ...[
                            const SizedBox(height: 8),
                            LinearProgressIndicator(value: job.progress / 100),
                          ],
                        ],
                      ),
                    ),
                    if (job.failed)
                      TextButton(
                        onPressed: job.start,
                        child: const Text('Retry'),
                      ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
