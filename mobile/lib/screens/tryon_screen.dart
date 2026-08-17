import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../extractor.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/before_after.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/stage_progress.dart';

enum _Phase { extracting, rendering, done, failed }

/// How much of the render to show. Purely a viewport control — it never
/// re-renders and never touches `garment_category`.
///
/// These used to drive the API's garment category, which was wrong: the
/// category describes what the garment *is* so the model knows where to put it.
/// Selecting "Top" for a one-piece dress re-rendered it as a top instead of
/// simply zooming in on the upper half.
enum _View {
  top(label: 'Top', icon: Icons.checkroom, zoom: 1.85, alignment: Alignment.topCenter),
  full(label: 'Full body', icon: Icons.woman_outlined, zoom: 1.0, alignment: Alignment.center),
  bottom(label: 'Bottom', icon: Icons.dry_cleaning_outlined, zoom: 1.85, alignment: Alignment.bottomCenter);

  const _View({
    required this.label,
    required this.icon,
    required this.zoom,
    required this.alignment,
  });

  final String label;
  final IconData icon;
  final double zoom;
  final Alignment alignment;
}

/// Where a share lands. Resolves whatever arrived into a garment image, renders
/// it onto the saved photo, and then asks the only question that matters:
/// would you actually buy it.
class TryOnScreen extends StatefulWidget {
  const TryOnScreen({
    super.key,
    required this.store,
    this.sharedText,
    this.sharedImagePath,
  });

  final EasyBuyStore store;
  final String? sharedText;
  final String? sharedImagePath;

  @override
  State<TryOnScreen> createState() => _TryOnScreenState();
}

class _TryOnScreenState extends State<TryOnScreen> {
  ApiClient get _api => widget.store.api;
  String? get _modelUrl => widget.store.modelUrl;

  _Phase _phase = _Phase.extracting;
  String _stage = 'queued';
  String _statusLine = 'Reading the page…';
  String? _error;

  Garment? _garment;
  int _imageIndex = 0;

  /// What kind of garment this is, inferred from the product. Sent to the API
  /// so it knows where to place the garment; not user-adjustable.
  String _garmentCategory = 'upper_body';

  /// How much of the render is on screen. Viewport only.
  _View _view = _View.full;

  Uint8List? _sharedBytes;
  RenderItem? _render;
  Verdict _verdict;

  String? _webViewUrl;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _resolveGarment();
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  // --- step 1: work out what we are trying on -----------------------------

  Future<void> _resolveGarment() async {
    final imagePath = widget.sharedImagePath;
    if (imagePath != null) {
      try {
        final bytes = await File(imagePath).readAsBytes();
        setState(() {
          _sharedBytes = bytes;
          _garment = Garment(images: const [], title: 'Shared photo', source: 'shared-image');
        });
        _startRender();
      } catch (e) {
        _failWith('Could not read that image: $e');
      }
      return;
    }

    final text = widget.sharedText ?? '';
    final url = RegExp(r'https?://[^\s<>"' r"')]+").firstMatch(text)?.group(0);
    if (url == null) {
      _failWith('That share did not contain a link.');
      return;
    }

    // Ask the server first: instant when the store allows it. Big retailers
    // return 403 to any server, and those fall through to the WebView, which
    // is a real browser and is not blocked.
    setState(() => _statusLine = 'Reading the page…');
    try {
      final garment = await _api.extract(text).timeout(const Duration(seconds: 8));
      if (garment.images.isNotEmpty) {
        _onGarment(garment);
        return;
      }
    } catch (_) {
      // Expected for most large stores; fall through to the WebView.
    }

    if (!mounted) return;
    setState(() {
      _statusLine = 'Opening the page to find the product photo…';
      _webViewUrl = url;
    });
  }

  void _onGarment(Garment garment) {
    if (!mounted) return;
    setState(() {
      _garment = garment;
      _imageIndex = 0;
      _garmentCategory = _guessCategory('${garment.title} ${garment.notes}');
      _webViewUrl = null;
    });
    _startRender();
  }

  String _guessCategory(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'\b(dress|gown|jumpsuit|romper|playsuit|overall|kaftan|saree)\b').hasMatch(lower)) {
      return 'full_body';
    }
    if (RegExp(r'\b(jean|jeans|trouser|pant|pants|chino|short|shorts|skirt|legging|jogger|cargo)\b')
        .hasMatch(lower)) {
      return 'lower_body';
    }
    return 'upper_body';
  }

  // --- step 2: render ------------------------------------------------------

  /// Called on arrival, when a different product photo is picked, and on an
  /// explicit re-render. The View buttons deliberately do not call this — they
  /// only zoom what is already on screen.
  Future<void> _startRender({bool force = false}) async {
    final garment = _garment;
    if (garment == null) return;

    final requestedCategory = _garmentCategory;

    setState(() {
      _phase = _Phase.rendering;
      _stage = 'queued';
      _error = null;
    });

    try {
      String? garmentUrl;
      Uint8List? bytes = _sharedBytes;
      var contentType = 'image/jpeg';

      if (garment.images.isNotEmpty) {
        garmentUrl = garment.images[_imageIndex];
        // Fetch from the phone as well as passing the URL. The server tries the
        // URL first because it is free, and falls back to these bytes when the
        // CDN refuses it — which saves a whole failed round trip.
        setState(() => _stage = 'downloading-garment');
        final fetched = await fetchImageBytes(garmentUrl, referer: garment.pageUrl);
        if (fetched != null) {
          bytes = fetched.bytes;
          contentType = fetched.contentType;
        }
      }

      if (garmentUrl == null && bytes == null) {
        _failWith('No garment image to work with.');
        return;
      }

      final started = await _api.startTryOn(
        garmentUrl: garmentUrl,
        garmentBytes: bytes,
        garmentContentType: contentType,
        pageUrl: garment.pageUrl,
        title: garment.title,
        category: requestedCategory,
        force: force,
      );

      final cached = started.cached;
      if (cached != null) {
        _finish(cached, requestedCategory, cached: true);
        return;
      }

      _pollJob(started.jobId!, requestedCategory);
    } on ApiException catch (e) {
      _failWith(e.code == 'no-model' ? 'Add a photo of yourself in Setup first.' : e.message);
    } catch (e) {
      _failWith(e.toString());
    }
  }

  void _pollJob(String jobId, String requestedCategory) {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(milliseconds: 900), (timer) async {
      JobStatus status;
      try {
        status = await _api.job(jobId);
      } catch (e) {
        timer.cancel();
        _failWith(e.toString());
        return;
      }
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (status.state == 'running') {
        setState(() => _stage = status.stage);
        return;
      }

      timer.cancel();
      if (status.isError) {
        _failWith(status.error ?? 'The render failed.');
        return;
      }
      if (status.render != null) _finish(status.render!, requestedCategory, cached: false);
    });
  }

  void _finish(RenderItem render, String category, {required bool cached}) {
    setState(() {
      _render = render;
      _verdict = render.verdict;
      _phase = _Phase.done;
      _statusLine = cached ? 'From cache · 0 units' : '${(render.tookMs / 1000).toStringAsFixed(1)}s';
    });
    // Keep the wardrobe in sync without making the user pull to refresh.
    widget.store.refresh();
  }

  void _failWith(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _error = message;
      _webViewUrl = null;
    });
  }

  void _onViewChanged(_View view) {
    if (_view == view) return;
    setState(() => _view = view);
  }

  Future<void> _decide(Verdict verdict) async {
    final render = _render;
    if (render == null) return;
    final next = _verdict == verdict ? null : verdict;
    setState(() => _verdict = next);
    await widget.store.setVerdict(render.key, next);
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_garment?.host.isNotEmpty == true ? _garment!.host : 'Try on'),
        actions: [
          if (_phase == _Phase.done)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Text(_statusLine, style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          switch (_phase) {
            _Phase.extracting => _busy(context),
            _Phase.rendering => _renderingView(context),
            _Phase.failed => _failure(context),
            _Phase.done => _result(context),
          },
          // Offscreen and one pixel wide, but it must stay in the tree to run.
          if (_webViewUrl != null)
            HiddenPageExtractor(
              url: _webViewUrl!,
              onExtracted: _onGarment,
              onFailed: _failWith,
            ),
        ],
      ),
      bottomNavigationBar: _phase == _Phase.done ? _decisionBar(context) : null,
    );
  }

  Widget _busy(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(_statusLine,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }

  Widget _renderingView(BuildContext context) {
    final garment = _garment;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 34),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (garment != null && garment.images.isNotEmpty)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.network(
                    garment.images[_imageIndex],
                    height: 140,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
            const SizedBox(height: 30),
            StageProgress(stage: _stage),
            if (garment != null && garment.title.isNotEmpty) ...[
              const SizedBox(height: 22),
              Text(garment.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _failure(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sentiment_dissatisfied_outlined,
                size: 46, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 20),
            Text(_error ?? 'Something went wrong',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: 26),
            FilledButton(
              onPressed: () => _startRender(force: true),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context) {
    final render = _render;
    final garment = _garment;
    if (render == null) return const SizedBox.shrink();

    final renderImage = NetworkImage(_api.assetUrl(render.localPath));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: _modelUrl == null
                    ? AnimatedScale(
                        scale: _view.zoom,
                        alignment: _view.alignment,
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        child: Image(image: renderImage, fit: BoxFit.cover),
                      )
                    : BeforeAfterSlider(
                        before: NetworkImage(_modelUrl!),
                        after: renderImage,
                        zoom: _view.zoom,
                        zoomAlignment: _view.alignment,
                      ),
              ),
            ),
            // The slider owns taps and drags on the image, so full screen needs
            // its own affordance rather than tap-to-open.
            Positioned(
              right: 10,
              bottom: 10,
              child: IconButton(
                icon: const Icon(Icons.fullscreen),
                color: Colors.white,
                style: IconButton.styleFrom(backgroundColor: Colors.black45),
                tooltip: 'View full screen',
                onPressed: () => Navigator.of(context).push(
                  PhotoViewerPage.route(image: renderImage, caption: garment?.title ?? ''),
                ),
              ),
            ),
            // No cache badge here on purpose: the before/after slider owns the
            // top-left corner for its "You" label, and the app bar already
            // reports "From cache · 0 units".
          ],
        ),

        if (_modelUrl != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.swipe,
                  size: 15,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
              const SizedBox(width: 6),
              Text('Drag to compare with your photo',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ],

        if (garment != null && garment.title.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(garment.title, style: Theme.of(context).textTheme.titleMedium),
          if (garment.price.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(garment.price, style: Theme.of(context).textTheme.bodyMedium),
            ),
        ],

        const SizedBox(height: 24),
        _viewSelector(context),

        if (garment != null && garment.images.length > 1) ...[
          const SizedBox(height: 26),
          Text('Another photo of this item',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          _candidateStrip(context, garment),
        ],

        const SizedBox(height: 26),
        OutlinedButton.icon(
          onPressed: () => _startRender(force: true),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Render again'),
        ),
      ],
    );
  }

  Widget _candidateStrip(BuildContext context, Garment garment) {
    return SizedBox(
      height: 86,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: garment.images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final selected = index == _imageIndex;
          return GestureDetector(
            onTap: () {
              if (selected) return;
              setState(() => _imageIndex = index);
              _startRender();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 66,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  width: 2.5,
                  color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                garment.images[index],
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Re-renders on tap. It used to only change a variable, which meant every
  /// render silently went out as `upper_body`.
  /// Zooms the render. No API call, no re-render — the garment stays exactly
  /// as it was generated, we just look at part of it.
  Widget _viewSelector(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('View', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(width: 8),
            Text('zoom only', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: _View.values.map((option) {
            final selected = _view == option;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => _onViewChanged(option),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: selected ? scheme.primary : scheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: selected ? scheme.primary : scheme.outlineVariant,
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(option.icon,
                            size: 22, color: selected ? scheme.onPrimary : scheme.onSurface),
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
        ),
      ],
    );
  }

  /// The point of the whole app: turn a render into a decision.
  Widget _decisionBar(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _decisionButton(
              context,
              label: 'Pass',
              icon: Icons.close,
              active: _verdict == 'pass',
              color: Colors.blueGrey,
              onTap: () => _decide('pass'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: _decisionButton(
              context,
              label: _verdict == 'keep' ? 'Kept' : 'Keep',
              icon: _verdict == 'keep' ? Icons.favorite : Icons.favorite_border,
              active: _verdict == 'keep',
              color: EasyBuyTheme.coral,
              onTap: () => _decide('keep'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _decisionButton(
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
        padding: const EdgeInsets.symmetric(vertical: 17),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? color : Theme.of(context).colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: active ? Colors.white : color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
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
