import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../main.dart' show ShareIntent;
import '../store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/photo_viewer.dart';

/// The entry point. Its job is to make the next action obvious and to show
/// that something has been happening — not to be a form.
class HomeTab extends StatelessWidget {
  const HomeTab({
    super.key,
    required this.store,
    required this.onShare,
    required this.onOpenSetup,
    required this.onSeeAll,
  });

  final EasyBuyStore store;
  final void Function(ShareIntent intent) onShare;
  final VoidCallback onOpenSetup;
  final VoidCallback onSeeAll;

  Future<void> _pickPhoto(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 92,
    );
    if (picked != null) onShare(ShareIntent.image(picked.path));
  }

  Future<void> _pasteLink(BuildContext context) async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('Paste a product link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://…'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(110, 46)),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Try it on'),
          ),
        ],
      ),
    );
    if (link != null && link.isNotEmpty) onShare(ShareIntent.link(link));
  }

  @override
  Widget build(BuildContext context) {
    final recents = store.renders.take(6).toList();

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: store.refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
            children: [
              _greeting(context),
              const SizedBox(height: 24),
              if (!store.ready)
                EntranceFade(child: _setupCard(context))
              else
                EntranceFade(child: _stage(context)),
              const SizedBox(height: 18),
              EntranceFade(index: 1, child: _actions(context)),
              const SizedBox(height: 34),
              if (recents.isNotEmpty)
                EntranceFade(index: 2, child: _recent(context, recents))
              else if (store.ready)
                EntranceFade(index: 2, child: _howItWorks(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _greeting(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'EasyBuy',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 3),
              Text(
                store.renders.isEmpty
                    ? 'See it on you before you buy it'
                    : '${store.renders.length} tried · ${store.kept.length} kept',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        if (store.modelUrl != null)
          GestureDetector(
            onTap: onOpenSetup,
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: EasyBuyTheme.coral, width: 2),
              ),
              padding: const EdgeInsets.all(2),
              child: CircleAvatar(
                radius: 22,
                backgroundImage: NetworkImage(store.modelUrl!),
              ),
            ),
          ),
      ],
    );
  }

  Widget _setupCard(BuildContext context) {
    final missingModel = !store.hasModel;

    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            missingModel ? Icons.person_add_alt : Icons.wifi_tethering_off,
            size: 28,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(
            missingModel ? 'Add your photo' : 'Connect to your backend',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            missingModel
                ? 'One full-body photo, facing forward. Everything you try gets rendered onto it.'
                : store.status,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: onOpenSetup, child: const Text('Get started')),
        ],
      ),
    );
  }

  /// The hero. Deliberately shows the user's own photo — it makes the app feel
  /// like it is about them rather than about an API.
  Widget _stage(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? [const Color(0xFF33232B), const Color(0xFF1B1B1F)]
              : [const Color(0xFFFFE4D8), const Color(0xFFFFF6F1)],
        ),
      ),
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Pill(label: 'READY', icon: Icons.bolt, color: EasyBuyTheme.coral),
                const SizedBox(height: 14),
                Text(
                  'Share anything\nto try it on',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 10),
                Text(
                  'Tap Share in any shopping app and pick EasyBuy. '
                  'A product link works — so does a screenshot.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                ),
              ],
            ),
          ),
          if (store.modelUrl != null) ...[
            const SizedBox(width: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.network(
                store.modelUrl!,
                width: 86,
                height: 124,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(width: 86, height: 124),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: store.ready ? () => _pickPhoto(context) : null,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
            label: const Text('Photo'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: store.ready ? () => _pasteLink(context) : null,
            icon: const Icon(Icons.link, size: 20),
            label: const Text('Link'),
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context, List<RenderItem> recents) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Recently tried',
          action: TextButton(onPressed: onSeeAll, child: const Text('See all')),
        ),
        SizedBox(
          height: 210,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: recents.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final render = recents[index];
              return EntranceFade(
                index: index,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    PhotoViewerPage.route(
                      image: NetworkImage(store.api.assetUrl(render.localPath)),
                      heroTag: 'home-${render.key}',
                      caption: render.title,
                    ),
                  ),
                  child: SizedBox(
                    width: 152,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Hero(
                              tag: 'home-${render.key}',
                              child: Image.network(
                                store.api.assetUrl(render.localPath),
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const ColoredBox(color: Colors.black12),
                              ),
                            ),
                          ),
                        ),
                        if (render.isKept)
                          const Positioned(
                            top: 10,
                            left: 10,
                            child: Pill(
                              label: 'KEPT',
                              icon: Icons.favorite,
                              color: EasyBuyTheme.coral,
                              filled: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _howItWorks(BuildContext context) {
    const steps = [
      (icon: Icons.ios_share, title: 'Share', body: 'Any product page, or a screenshot of an outfit.'),
      (icon: Icons.auto_awesome, title: 'See it', body: 'It renders onto your photo in about ten seconds.'),
      (icon: Icons.favorite_border, title: 'Decide', body: 'Keep it or pass. Your shortlist builds itself.'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'How it works'),
        ...steps.indexed.map((entry) {
          final (index, step) = entry;
          return EntranceFade(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(step.icon,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(step.title, style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(step.body, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}
