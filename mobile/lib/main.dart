import 'dart:async';

import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'screens/home_tab.dart';
import 'screens/setup_screen.dart';
import 'screens/tryon_screen.dart';
import 'screens/wardrobe_tab.dart';
import 'screens/you_tab.dart';
import 'store.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EasyBuyApp());
}

/// What arrived from the Android share sheet: either a link or an image.
class ShareIntent {
  ShareIntent.link(this.text) : imagePath = null;
  ShareIntent.image(this.imagePath) : text = null;

  final String? text;
  final String? imagePath;
}

class EasyBuyApp extends StatefulWidget {
  const EasyBuyApp({super.key});

  @override
  State<EasyBuyApp> createState() => _EasyBuyAppState();
}

class _EasyBuyAppState extends State<EasyBuyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _store = EasyBuyStore();

  StreamSubscription<List<SharedMediaFile>>? _shareSubscription;
  bool _booted = false;

  /// Held when a share arrives before setup is finished.
  ShareIntent? _pendingShare;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _store.load();
    if (mounted) setState(() => _booted = true);
    _listenForShares();
  }

  void _listenForShares() {
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _handleShare(files);
      ReceiveSharingIntent.instance.reset();
    });
    _shareSubscription =
        ReceiveSharingIntent.instance.getMediaStream().listen(_handleShare, onError: (_) {});
  }

  void _handleShare(List<SharedMediaFile> files) {
    if (files.isEmpty) return;

    final image = files.where((f) => f.type == SharedMediaType.image).firstOrNull;
    final ShareIntent intent;
    if (image != null) {
      intent = ShareIntent.image(image.path);
    } else {
      final first = files.first;
      final text = (first.message?.isNotEmpty ?? false) ? first.message! : first.path;
      if (text.trim().isEmpty) return;
      intent = ShareIntent.link(text);
    }
    openShare(intent);
  }

  void openShare(ShareIntent intent) {
    if (!_store.hasModel) {
      // Nothing to render onto yet. Remember it and finish setup first.
      _pendingShare = intent;
      _openSetup();
      return;
    }
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => EasyBuyScope(
          store: _store,
          child: TryOnScreen(
            store: _store,
            sharedText: intent.text,
            sharedImagePath: intent.imagePath,
          ),
        ),
      ),
    );
  }

  void _openSetup() {
    _navigatorKey.currentState
        ?.push(
          MaterialPageRoute(
            builder: (_) => EasyBuyScope(store: _store, child: SetupScreen(store: _store)),
          ),
        )
        .then((_) {
          final pending = _pendingShare;
          _pendingShare = null;
          if (pending != null && _store.hasModel) {
            // Resume whatever the user was trying to try on before setup.
            WidgetsBinding.instance.addPostFrameCallback((_) => openShare(pending));
          }
        });
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    _store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listening to the store here so a theme change rebuilds MaterialApp itself,
    // not just the screen that triggered it.
    return AnimatedBuilder(
      animation: _store,
      builder: (context, _) => MaterialApp(
        title: 'EasyBuy',
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: EasyBuyTheme.of(Brightness.light),
        darkTheme: EasyBuyTheme.of(Brightness.dark),
        themeMode: _store.themeMode,
        home: !_booted
            ? const _SplashScreen()
            : EasyBuyScope(
                store: _store,
                child: MainShell(
                  store: _store,
                  onShare: openShare,
                  onOpenSetup: _openSetup,
                ),
              ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('EasyBuy', style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 18),
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three tabs behind a bottom bar: the try-on entry point, everything you have
/// tried, and your photo plus settings.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.store,
    required this.onShare,
    required this.onOpenSetup,
  });

  final EasyBuyStore store;
  final void Function(ShareIntent intent) onShare;
  final VoidCallback onOpenSetup;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from a share usually means there is a new render to show.
    if (state == AppLifecycleState.resumed) widget.store.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = EasyBuyScope.of(context);

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeTab(
            store: store,
            onShare: widget.onShare,
            onOpenSetup: widget.onOpenSetup,
            onSeeAll: () => setState(() => _index = 1),
          ),
          WardrobeTab(store: store),
          YouTab(store: store, onOpenSetup: widget.onOpenSetup),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Try on',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: store.kept.isNotEmpty,
              label: Text('${store.kept.length}'),
              child: const Icon(Icons.checkroom_outlined),
            ),
            selectedIcon: const Icon(Icons.checkroom),
            label: 'Wardrobe',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'You',
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
