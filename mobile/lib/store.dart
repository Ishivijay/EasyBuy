import 'dart:typed_data';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Shared app state. Small enough that a ChangeNotifier beats pulling in a
/// state management package, but central enough that three tabs and the try-on
/// screen all stay in sync without threading callbacks through every widget.
class EasyBuyStore extends ChangeNotifier {
  EasyBuyStore({String? baseUrl}) : _baseUrl = baseUrl ?? defaultBaseUrl;

  static const defaultBaseUrl = 'http://192.168.0.240:8787';
  static const _prefsBaseUrl = 'baseUrl';
  static const _prefsTheme = 'themeMode';

  /// Light, dark, or follow the system. Persisted so it survives a restart.
  ThemeMode themeMode = ThemeMode.system;

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsTheme, mode.name);
  }

  String _baseUrl;
  String get baseUrl => _baseUrl;

  // One client per address, rebuilt only when the address changes. Handing out
  // a fresh instance per access silently breaks anything that keeps state
  // between two calls.
  ApiClient? _api;
  ApiClient get api => _api ??= ApiClient(_baseUrl);

  String? modelId;
  String? modelUrl;
  bool get hasModel => modelUrl != null;

  bool online = false;
  int? units;
  String status = 'Checking…';

  List<RenderItem> renders = const [];
  bool loadingRenders = true;

  List<RenderItem> get kept => renders.where((r) => r.isKept).toList();
  List<RenderItem> get undecided => renders.where((r) => r.verdict == null).toList();

  bool get ready => online && hasModel;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_prefsBaseUrl) ?? defaultBaseUrl;

    final saved = prefs.getString(_prefsTheme);
    themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == saved,
      orElse: () => ThemeMode.system,
    );

    await refresh();
  }

  Future<void> refresh() async {
    try {
      final health = await api.health();
      online = health.configured;
      units = health.units;
      // Just the connection state — the unit balance has its own row in the
      // You tab, and showing it twice reads like a bug.
      status = health.configured ? 'Connected' : 'No API key on the backend';

      final model = await api.activeModel();
      modelId = model?.id;
      modelUrl = model == null ? null : api.assetUrl(model.url);

      renders = await api.renders();
    } catch (_) {
      online = false;
      status = 'Backend unreachable';
    } finally {
      loadingRenders = false;
      notifyListeners();
    }
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = url.trim().replaceAll(RegExp(r'/$'), '');
    await prefs.setString(_prefsBaseUrl, cleaned);
    _baseUrl = cleaned;
    _api = null; // rebuilt against the new address on next access
    notifyListeners();
    await refresh();
  }

  Future<void> uploadModel(Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    final path = await api.uploadModel(bytes, contentType: contentType);
    modelUrl = api.assetUrl(path);
    notifyListeners();
    await refresh();
  }

  /// Clears everything. Deleting only the active photo used to promote whichever
  /// other photo happened to be stored next, so the UI looked like it had
  /// swapped your photo rather than removed it.
  Future<void> deleteModel() async {
    await api.deleteAllData();
    modelId = null;
    modelUrl = null;
    renders = const [];
    notifyListeners();
    await refresh();
  }

  /// Optimistic so the button reacts instantly; the refresh reconciles.
  Future<void> setVerdict(String key, Verdict verdict) async {
    renders = [
      for (final render in renders)
        if (render.key == key)
          RenderItem(
            key: render.key,
            localPath: render.localPath,
            title: render.title,
            pageUrl: render.pageUrl,
            garmentPath: render.garmentPath,
            category: render.category,
            tookMs: render.tookMs,
            createdAt: render.createdAt,
            verdict: verdict,
          )
        else
          render,
    ];
    notifyListeners();

    try {
      await api.setVerdict(key, verdict);
    } catch (_) {
      await refresh();
    }
  }

  Future<void> deleteRender(String key) async {
    renders = renders.where((r) => r.key != key).toList();
    notifyListeners();
    try {
      await api.deleteRender(key);
    } catch (_) {
      await refresh();
    }
  }
}

/// Makes the store available to the whole tree and rebuilds listeners on change.
class EasyBuyScope extends InheritedNotifier<EasyBuyStore> {
  const EasyBuyScope({super.key, required EasyBuyStore store, required super.child})
      : super(notifier: store);

  static EasyBuyStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<EasyBuyScope>();
    assert(scope?.notifier != null, 'EasyBuyScope is missing from the widget tree');
    return scope!.notifier!;
  }
}
