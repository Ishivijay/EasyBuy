import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import 'api.dart';

/// Loads a shared product URL in an offscreen WebView and runs the same
/// extractor script the Chrome extension injects.
///
/// This exists because the obvious approach does not work: Zara, H&M, ASOS and
/// friends return 403 to any server-side fetch, including one wearing a social
/// crawler's user agent, because they fingerprint the TLS handshake as well as
/// the headers. A phone running a real WebView is simply a browser, so it is
/// not blocked — and as a bonus the page's own JavaScript has run by the time
/// we read the DOM, so single-page sites work too.
class HiddenPageExtractor extends StatefulWidget {
  const HiddenPageExtractor({
    super.key,
    required this.url,
    required this.onExtracted,
    required this.onFailed,
  });

  final String url;
  final void Function(Garment garment) onExtracted;
  final void Function(String message) onFailed;

  @override
  State<HiddenPageExtractor> createState() => _HiddenPageExtractorState();
}

class _HiddenPageExtractorState extends State<HiddenPageExtractor> {
  static const _mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

  // Single-page stores hydrate after load, so one attempt is not enough.
  static const _attemptDelays = [
    Duration(milliseconds: 900),
    Duration(milliseconds: 1600),
    Duration(seconds: 3),
  ];

  late final WebViewController _controller;
  String? _script;
  bool _settled = false;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => _harvest(),
          onWebResourceError: (error) {
            // Sub-resource failures are normal and not fatal; only a failed
            // main frame means we will never get a DOM.
            if (error.isForMainFrame ?? false) {
              _fail('Could not open that page (${error.description})');
            }
          },
        ),
      );

    _boot();
  }

  Future<void> _boot() async {
    try {
      _script = await rootBundle.loadString('assets/extractor.js');
    } catch (e) {
      _fail('Extractor script missing from the bundle: $e');
      return;
    }

    final uri = Uri.tryParse(widget.url);
    if (uri == null || !uri.hasScheme) {
      _fail('That does not look like a link');
      return;
    }
    await _controller.loadRequest(uri);

    // If the page never fires onPageFinished, give up rather than hang.
    _watchdog = Timer(const Duration(seconds: 25), () {
      _fail('That page took too long to load');
    });
  }

  Future<void> _harvest() async {
    if (_settled || _script == null) return;
    _watchdog?.cancel();

    for (final delay in _attemptDelays) {
      if (_settled || !mounted) return;
      await Future<void>.delayed(delay);
      if (_settled || !mounted) return;

      Garment? garment;
      try {
        final raw = await _controller.runJavaScriptReturningResult(_script!);
        garment = _parse(raw);
      } catch (_) {
        // Keep retrying; a mid-hydration DOM can throw.
        continue;
      }

      if (garment != null && garment.images.isNotEmpty) {
        _settled = true;
        widget.onExtracted(garment);
        return;
      }
    }

    _fail('No product image found on that page. Try sharing a screenshot instead.');
  }

  /// Android hands back the value as a JSON string, so it arrives encoded once
  /// or twice depending on the platform view.
  Garment? _parse(Object raw) {
    dynamic value = raw;
    for (var i = 0; i < 3 && value is String; i++) {
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    if (value is Map<String, dynamic>) return Garment.fromJson(value);
    return null;
  }

  void _fail(String message) {
    if (_settled) return;
    _settled = true;
    _watchdog?.cancel();
    widget.onFailed(message);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The platform view has to be laid out to run JavaScript, so it is kept at
    // one pixel and fully transparent rather than removed from the tree.
    return IgnorePointer(
      child: Opacity(
        opacity: 0,
        child: SizedBox(width: 1, height: 1, child: WebViewWidget(controller: _controller)),
      ),
    );
  }
}
