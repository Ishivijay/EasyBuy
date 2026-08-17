import 'package:flutter/material.dart';

/// The render takes eight to thirteen seconds, which is long enough that a bare
/// spinner feels broken. Showing the real pipeline — and ticking steps off as
/// the backend reports them — makes the wait legible instead of anxious.
class StageProgress extends StatelessWidget {
  const StageProgress({super.key, required this.stage});

  /// The raw stage string from the proxy.
  final String stage;

  static const _steps = <({String label, List<String> matches, IconData icon})>[
    (label: 'Preparing your photo', matches: ['queued', 'preparing-model'], icon: Icons.person_outline),
    (
      label: 'Reading the garment',
      matches: ['uploading-garment', 'downloading-garment'],
      icon: Icons.checkroom_outlined
    ),
    (label: 'Sending to YouCam', matches: ['submitting'], icon: Icons.cloud_upload_outlined),
    (label: 'Rendering the try-on', matches: ['rendering'], icon: Icons.auto_awesome_outlined),
    (label: 'Saving', matches: ['saving'], icon: Icons.check_circle_outline),
  ];

  int get _activeIndex {
    for (var i = 0; i < _steps.length; i++) {
      if (_steps[i].matches.contains(stage)) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final active = _activeIndex;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(_steps.length, (index) {
        final step = _steps[index];
        final done = index < active;
        final current = index == active;

        final color = done
            ? scheme.onSurface.withValues(alpha: 0.45)
            : current
                ? scheme.onSurface
                : scheme.onSurface.withValues(alpha: 0.28);

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                height: 26,
                child: current
                    ? CircularProgressIndicator(strokeWidth: 2.2, color: scheme.primary)
                    : Icon(done ? Icons.check : step.icon, size: 20, color: color),
              ),
              const SizedBox(width: 14),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 15,
                  color: color,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(step.label),
              ),
            ],
          ),
        );
      }),
    );
  }
}
