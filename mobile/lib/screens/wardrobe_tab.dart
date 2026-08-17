import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/photo_viewer.dart';

enum _Filter { all, kept, undecided, passed }

/// Everything tried, across every store. This is the part that turns a
/// one-shot tool into something worth opening again: a shortlist you built by
/// actually seeing the clothes on yourself.
class WardrobeTab extends StatefulWidget {
  const WardrobeTab({super.key, required this.store});

  final EasyBuyStore store;

  @override
  State<WardrobeTab> createState() => _WardrobeTabState();
}

class _WardrobeTabState extends State<WardrobeTab> {
  _Filter _filter = _Filter.all;

  List<RenderItem> get _visible {
    final all = widget.store.renders;
    return switch (_filter) {
      _Filter.all => all,
      _Filter.kept => all.where((r) => r.isKept).toList(),
      _Filter.passed => all.where((r) => r.isPassed).toList(),
      _Filter.undecided => all.where((r) => r.verdict == null).toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = EasyBuyScope.of(context);
    final items = _visible;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: store.refresh,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Wardrobe', style: Theme.of(context).textTheme.displaySmall),
                      const SizedBox(height: 3),
                      Text(
                        '${store.renders.length} tried on · ${store.kept.length} on the shortlist',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      _filters(context, store),
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
              ),

              if (store.loadingRenders)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverGrid.builder(
                    itemCount: 4,
                    gridDelegate: _gridDelegate,
                    itemBuilder: (_, __) => const Shimmer(borderRadius: 18),
                  ),
                )
              else if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: _empty(context))
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  sliver: SliverGrid.builder(
                    itemCount: items.length,
                    gridDelegate: _gridDelegate,
                    itemBuilder: (context, index) => EntranceFade(
                      index: index,
                      child: _tile(context, store, items[index]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 2,
    crossAxisSpacing: 12,
    mainAxisSpacing: 12,
    childAspectRatio: 3 / 4,
  );

  Widget _filters(BuildContext context, EasyBuyStore store) {
    final counts = {
      _Filter.all: store.renders.length,
      _Filter.kept: store.kept.length,
      _Filter.undecided: store.undecided.length,
      _Filter.passed: store.renders.where((r) => r.isPassed).length,
    };
    const labels = {
      _Filter.all: 'All',
      _Filter.kept: 'Kept',
      _Filter.undecided: 'Undecided',
      _Filter.passed: 'Passed',
    };

    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: _Filter.values.map((filter) {
          final selected = _filter == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text('${labels[filter]} ${counts[filter]}'),
              selected: selected,
              showCheckmark: false,
              onSelected: (_) => setState(() => _filter = filter),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final message = switch (_filter) {
      _Filter.all => 'Share a product link or a screenshot to get started.',
      _Filter.kept => 'Nothing on the shortlist yet. Keep a try-on to add it.',
      _Filter.passed => 'Nothing passed on yet.',
      _Filter.undecided => 'Everything has a verdict. Nice.',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.checkroom_outlined,
              size: 38,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(message,
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, EasyBuyStore store, RenderItem render) {
    return GestureDetector(
      onTap: () => _openSheet(context, store, render),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: 'wardrobe-${render.key}',
              child: Image.network(
                store.api.assetUrl(render.localPath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(11, 26, 11, 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (render.title.isNotEmpty)
                      Text(
                        render.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (render.host.isNotEmpty)
                      Text(
                        render.host,
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                  ],
                ),
              ),
            ),
            if (render.verdict != null)
              Positioned(
                top: 10,
                left: 10,
                child: Pill(
                  label: render.isKept ? 'KEPT' : 'PASSED',
                  icon: render.isKept ? Icons.favorite : Icons.close,
                  color: render.isKept ? EasyBuyTheme.coral : Colors.blueGrey,
                  filled: true,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _openSheet(BuildContext context, EasyBuyStore store, RenderItem render) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => _DetailSheet(store: store, render: render),
    );
  }
}

class _DetailSheet extends StatefulWidget {
  const _DetailSheet({required this.store, required this.render});

  final EasyBuyStore store;
  final RenderItem render;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  late Verdict _verdict = widget.render.verdict;

  Future<void> _decide(Verdict verdict) async {
    // Tapping the active verdict clears it, so a decision is reversible.
    final next = _verdict == verdict ? null : verdict;
    setState(() => _verdict = next);
    await widget.store.setVerdict(widget.render.key, next);
  }

  @override
  Widget build(BuildContext context) {
    final render = widget.render;
    final image = NetworkImage(widget.store.api.assetUrl(render.localPath));

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 18),

          GestureDetector(
            onTap: () => Navigator.of(context).push(
              PhotoViewerPage.route(image: image, caption: render.title),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: Image(image: image, fit: BoxFit.cover),
              ),
            ),
          ),

          const SizedBox(height: 18),
          if (render.title.isNotEmpty)
            Text(render.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (render.host.isNotEmpty) Pill(label: render.host, icon: Icons.storefront),
              if (render.category.isNotEmpty)
                Pill(label: _categoryLabel(render.category), icon: Icons.straighten),
              if (render.tookMs > 0)
                Pill(label: '${(render.tookMs / 1000).toStringAsFixed(1)}s', icon: Icons.timer_outlined),
            ],
          ),

          const SizedBox(height: 24),
          Text('Would you buy it?', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _verdictButton(
                  context,
                  label: 'Keep',
                  icon: Icons.favorite,
                  active: _verdict == 'keep',
                  color: EasyBuyTheme.coral,
                  onTap: () => _decide('keep'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _verdictButton(
                  context,
                  label: 'Pass',
                  icon: Icons.close,
                  active: _verdict == 'pass',
                  color: Colors.blueGrey,
                  onTap: () => _decide('pass'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 22),
          if (render.pageUrl.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: render.pageUrl));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Product link copied')),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy product link'),
            ),

          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () async {
              await widget.store.deleteRender(render.key);
              if (context.mounted) Navigator.pop(context);
            },
            icon: Icon(Icons.delete_outline, size: 18, color: Theme.of(context).colorScheme.error),
            label: Text(
              'Delete this try-on',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  String _categoryLabel(String category) => switch (category) {
        'lower_body' => 'Bottom',
        'full_body' => 'Full body',
        _ => 'Top',
      };

  Widget _verdictButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 170),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? color : Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: active ? Colors.white : color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
