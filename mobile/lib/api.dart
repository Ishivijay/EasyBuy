import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Everything the app knows about a garment, whether it came from a product
/// page or from a shared screenshot.
class Garment {
  Garment({
    required this.images,
    this.title = '',
    this.price = '',
    this.host = '',
    this.pageUrl = '',
    this.source = '',
    this.notes = '',
    this.localImage,
  });

  final List<String> images;
  final String title;
  final String price;
  final String host;
  final String pageUrl;
  final String source;
  final String notes;

  /// Set when the garment is a shared photo rather than a page image.
  final Uint8List? localImage;

  bool get isSharedImage => localImage != null && images.isEmpty;

  factory Garment.fromJson(Map<String, dynamic> json) => Garment(
        images: (json['images'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        title: json['title']?.toString() ?? '',
        price: json['price']?.toString() ?? '',
        host: json['host']?.toString() ?? '',
        pageUrl: json['pageUrl']?.toString() ?? '',
        source: json['source']?.toString() ?? '',
        notes: json['notes']?.toString() ?? '',
      );
}

/// 'keep' or 'pass' — whether the user would actually buy it. Null is undecided.
typedef Verdict = String?;

class RenderItem {
  RenderItem({
    required this.key,
    required this.localPath,
    this.title = '',
    this.pageUrl = '',
    this.garmentPath = '',
    this.category = '',
    this.tookMs = 0,
    this.verdict,
    this.createdAt = 0,
  });

  final String key;
  final String localPath;
  final String title;
  final String pageUrl;
  final String garmentPath;
  final String category;
  final int tookMs;
  final Verdict verdict;
  final int createdAt;

  bool get isKept => verdict == 'keep';
  bool get isPassed => verdict == 'pass';

  String get host {
    try {
      return Uri.parse(pageUrl).host.replaceFirst('www.', '');
    } catch (_) {
      return '';
    }
  }

  factory RenderItem.fromJson(Map<String, dynamic> json) => RenderItem(
        key: json['key']?.toString() ?? '',
        localPath: json['localPath']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        pageUrl: json['pageUrl']?.toString() ?? '',
        garmentPath: json['garmentPath']?.toString() ?? '',
        category: json['category']?.toString() ?? '',
        tookMs: (json['tookMs'] as num?)?.toInt() ?? 0,
        verdict: json['verdict']?.toString(),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      );
}

class JobStatus {
  JobStatus({required this.state, this.stage = '', this.polls = 0, this.error, this.render});

  final String state; // running | done | error
  final String stage;
  final int polls;
  final String? error;
  final RenderItem? render;

  bool get isDone => state == 'done';
  bool get isError => state == 'error';
}

class ApiException implements Exception {
  ApiException(this.message, {this.code});
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// Talks to the local Node proxy. The YouCam key lives there, never here.
class ApiClient {
  ApiClient(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  String assetUrl(String path) => '$baseUrl$path';

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await http
        .post(_uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 60));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final res = await http.get(_uri(path)).timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('The server replied with something unreadable (${res.statusCode})');
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        json['message']?.toString() ?? json['error']?.toString() ?? 'Request failed (${res.statusCode})',
        code: json['error']?.toString(),
      );
    }
    return json;
  }

  /// Returns the remaining unit balance, or null if the shape is unfamiliar.
  Future<({bool configured, int? units})> health() async {
    final json = await _get('/api/health');
    return (configured: json['configured'] == true, units: _findUnits(json['credit']));
  }

  int? _findUnits(dynamic node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString().toLowerCase();
        // The live balance arrives as results[0].amount; older docs show
        // credit/units/balance, so all spellings are accepted.
        if (entry.value is num && RegExp(r'credit|unit|balance|remain|^amount$').hasMatch(key)) {
          return (entry.value as num).toInt();
        }
        final nested = _findUnits(entry.value);
        if (nested != null) return nested;
      }
    } else if (node is List) {
      for (final item in node) {
        final nested = _findUnits(item);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  Future<String> uploadModel(Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    final json = await _post('/api/model', {
      'imageBase64': base64Encode(bytes),
      'contentType': contentType,
    });
    return json['url'].toString();
  }

  Future<({String id, String url})?> activeModel() async {
    final json = await _get('/api/models');
    final models = (json['models'] as List?) ?? const [];
    if (models.isEmpty) return null;
    final activeId = json['activeModelId'];
    final match = models.firstWhere((m) => m['id'] == activeId, orElse: () => models.first);
    return (id: match['id'].toString(), url: match['url'].toString());
  }

  Future<void> setVerdict(String key, Verdict verdict) async {
    await _send('PATCH', '/api/renders/$key', {'verdict': verdict});
  }

  Future<void> deleteRender(String key) async {
    await _send('DELETE', '/api/renders/$key', null);
  }

  /// Removes the stored photo and every render made from it.
  Future<void> deleteModel(String id) async {
    await _send('DELETE', '/api/model/$id', null);
  }

  /// Wipes every stored photo and every render, leaving a blank slate.
  Future<void> deleteAllData() async {
    await _send('DELETE', '/api/data', null);
  }

  Future<Map<String, dynamic>> _send(String method, String path, Map<String, dynamic>? body) async {
    final request = http.Request(method, _uri(path));
    request.headers['Content-Type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send().timeout(const Duration(seconds: 30));
    return _decode(await http.Response.fromStream(streamed));
  }

  /// Server-side extraction. Works for smaller shops and direct image links;
  /// large retailers block it, which is why the app has a WebView fallback.
  Future<Garment> extract(String sharedText) async {
    final json = await _post('/api/extract', {'text': sharedText});
    return Garment.fromJson(json['garment'] as Map<String, dynamic>);
  }

  /// Either a job to poll, or an already-finished render straight from cache.
  ///
  /// This returns both rather than stashing the cached render on the client:
  /// `ClosetStore.api` builds a fresh ApiClient per access, so instance state
  /// set during one call was invisible to the next and the cache path crashed.
  Future<({String? jobId, RenderItem? cached})> startTryOn({
    String? garmentUrl,
    Uint8List? garmentBytes,
    String garmentContentType = 'image/jpeg',
    String pageUrl = '',
    String title = '',
    required String category,
    bool force = false,
  }) async {
    final json = await _post('/api/tryon', {
      if (garmentUrl != null) 'garmentUrl': garmentUrl,
      if (garmentBytes != null) 'garmentImageBase64': base64Encode(garmentBytes),
      'garmentContentType': garmentContentType,
      'pageUrl': pageUrl,
      'title': title,
      'category': category,
      'force': force,
    });

    if (json['state'] == 'done' && json['render'] != null) {
      // Cache hit; nothing to poll.
      return (jobId: null, cached: RenderItem.fromJson(json['render'] as Map<String, dynamic>));
    }
    final jobId = json['jobId'];
    if (jobId == null) {
      throw ApiException('The server accepted the try-on but returned no job to track');
    }
    return (jobId: jobId.toString(), cached: null);
  }

  Future<JobStatus> job(String jobId) async {
    final json = await _get('/api/tryon/$jobId');
    return JobStatus(
      state: json['state']?.toString() ?? 'running',
      stage: json['stage']?.toString() ?? '',
      polls: (json['polls'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
      render: json['render'] == null
          ? null
          : RenderItem.fromJson(json['render'] as Map<String, dynamic>),
    );
  }

  Future<List<RenderItem>> renders() async {
    final json = await _get('/api/renders');
    return ((json['renders'] as List?) ?? const [])
        .map((e) => RenderItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// Formats the try-on API accepts. Anything else has to go through the URL
/// path so YouCam fetches (and negotiates) it itself.
const _uploadableTypes = {'image/jpeg', 'image/jpg', 'image/png'};

/// Pulls the garment image from the phone rather than the server. Retailers
/// block datacentre and CLI fetches but not a real device, so this is the
/// reliable path — the bytes ride along with the try-on request.
Future<({Uint8List bytes, String contentType})?> fetchImageBytes(
  String imageUrl, {
  String? referer,
}) async {
  try {
    final res = await http.get(
      Uri.parse(imageUrl),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
        // Deliberately narrow. A browser would advertise avif and webp, and any
        // CDN doing content negotiation would then hand those back — which the
        // try-on API does not accept. Asking only for jpeg and png makes the
        // CDN transcode for us and costs nothing.
        'Accept': 'image/jpeg,image/png,image/*;q=0.5',
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      },
    ).timeout(const Duration(seconds: 25));

    if (res.statusCode != 200) return null;
    final contentType = (res.headers['content-type'] ?? 'image/jpeg').split(';').first.trim();
    if (!contentType.startsWith('image/')) return null;
    if (res.bodyBytes.length < 1024) return null;

    // If the CDN ignored the Accept header, let the URL path handle it rather
    // than uploading bytes the API will reject.
    if (!_uploadableTypes.contains(contentType)) return null;

    return (bytes: res.bodyBytes, contentType: contentType);
  } catch (_) {
    return null;
  }
}
