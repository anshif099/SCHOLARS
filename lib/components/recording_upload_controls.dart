import 'package:flutter/material.dart';
import '../services/recording_upload.dart';

class RecordingUploadControls extends StatelessWidget {
  const RecordingUploadControls({super.key, required this.recordingId});
  final String recordingId;

  @override
  Widget build(BuildContext context) {
    final job = RecordingUpload.jobs[recordingId];
    if (job == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        if (!job.running && !job.failed) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: job.progress / 100),
              Row(
                children: [
                  Expanded(child: Text(job.label)),
                  TextButton(
                    onPressed: job.failed ? job.start : job.togglePause,
                    child: Text(
                      job.failed
                          ? 'Retry'
                          : job.paused
                          ? 'Continue upload'
                          : 'Pause',
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
