import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../store.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Your photo, the connection, and the controls for getting rid of both.
class YouTab extends StatelessWidget {
  const YouTab({super.key, required this.store, required this.onOpenSetup});

  final EasyBuyStore store;
  final VoidCallback onOpenSetup;

  Future<void> _changePhoto(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 92,
    );
    if (picked == null) return;
    await store.uploadModel(await picked.readAsBytes());
  }

  Future<void> _confirmDeletePhoto(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Delete your photo?'),
        content: const Text(
          'This removes the photo from the backend along with every try-on made '
          'from it. It cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(110, 46),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) await store.deleteModel();
  }

  @override
  Widget build(BuildContext context) {
    final store = EasyBuyScope.of(context);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: store.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 40),
            children: [
              Text('You', style: Theme.of(context).textTheme.displaySmall),
              const SizedBox(height: 22),

              _photoCard(context, store),
              const SizedBox(height: 26),

              const SectionHeader(title: 'Connection'),
              _row(
                context,
                icon: store.online ? Icons.check_circle_outline : Icons.error_outline,
                iconColor: store.online ? const Color(0xFF19B36B) : Theme.of(context).colorScheme.error,
                title: store.status,
                subtitle: store.baseUrl,
                trailing: TextButton(onPressed: onOpenSetup, child: const Text('Change')),
              ),
              if (store.units != null)
                _row(
                  context,
                  icon: Icons.bolt_outlined,
                  title: '${store.units} API units left',
                  subtitle: 'Each new try-on spends units. Repeats are cached and free.',
                ),

              const SizedBox(height: 26),
              const SectionHeader(title: 'Appearance'),
              _themePicker(context, store),

              const SizedBox(height: 26),
              const SectionHeader(title: 'Activity'),
              Row(
                children: [
                  Expanded(child: _stat(context, '${store.renders.length}', 'Tried on')),
                  const SizedBox(width: 12),
                  Expanded(child: _stat(context, '${store.kept.length}', 'Kept')),
                  const SizedBox(width: 12),
                  Expanded(child: _stat(context, '${store.undecided.length}', 'Undecided')),
                ],
              ),

              const SizedBox(height: 26),
              const SectionHeader(title: 'Privacy'),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your photo is stored on your own backend and uploaded to YouCam '
                      'only to produce a render. YouCam keeps uploads for about 24 hours. '
                      'Nothing is sent anywhere else.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: store.hasModel ? () => _confirmDeletePhoto(context) : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.error.withValues(alpha: 0.4),
                        ),
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete my photo and try-ons'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _photoCard(BuildContext context, EasyBuyStore store) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF33232B), const Color(0xFF1B1B1F)]
              : [const Color(0xFFFFE4D8), const Color(0xFFFFF6F1)],
        ),
      ),
      child: Row(
        children: [
          if (store.modelUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                store.modelUrl!,
                width: 78,
                height: 104,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(width: 78, height: 104),
              ),
            )
          else
            Container(
              width: 78,
              height: 104,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.person_outline, size: 30),
            ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  store.hasModel ? 'Your photo' : 'No photo yet',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Everything renders onto this.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    backgroundColor: EasyBuyTheme.ink,
                  ),
                  onPressed: () => _changePhoto(context),
                  child: Text(store.hasModel ? 'Change' : 'Add photo'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Light / Dark / System. The app follows the system setting by default,
  /// which meant most people never discovered that a light theme existed.
  Widget _themePicker(BuildContext context, EasyBuyStore store) {
    const options = <({ThemeMode mode, String label, IconData icon})>[
      (mode: ThemeMode.light, label: 'Light', icon: Icons.light_mode_outlined),
      (mode: ThemeMode.dark, label: 'Dark', icon: Icons.dark_mode_outlined),
      (mode: ThemeMode.system, label: 'System', icon: Icons.brightness_auto_outlined),
    ];
    final scheme = Theme.of(context).colorScheme;

    return Row(
      children: options.map((option) {
        final selected = store.themeMode == option.mode;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: GestureDetector(
              onTap: () => store.setThemeMode(option.mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 15),
                decoration: BoxDecoration(
                  color: selected ? scheme.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      option.icon,
                      size: 20,
                      color: selected ? scheme.onPrimary : scheme.onSurface,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.onPrimary : scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _stat(BuildContext context, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 2),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    Color? iconColor,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor ?? Theme.of(context).colorScheme.onSurface),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyLarge),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}
