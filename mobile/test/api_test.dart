import 'package:easybuy/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Garment.fromJson', () {
    test('reads the extractor payload', () {
      final garment = Garment.fromJson({
        'source': 'zara',
        'host': 'zara.com',
        'pageUrl': 'https://zara.com/item',
        'title': 'Ribbed knit top',
        'price': '19.99 GBP',
        'images': ['https://cdn/a.jpg', 'https://cdn/b.jpg'],
      });

      expect(garment.images, hasLength(2));
      expect(garment.title, 'Ribbed knit top');
      expect(garment.host, 'zara.com');
      expect(garment.isSharedImage, isFalse);
    });

    test('survives a payload with missing fields', () {
      final garment = Garment.fromJson({});
      expect(garment.images, isEmpty);
      expect(garment.title, '');
      expect(garment.price, '');
    });
  });

  group('RenderItem.fromJson', () {
    test('reads a finished render', () {
      final render = RenderItem.fromJson({
        'key': 'abc123',
        'localPath': '/renders/abc123.jpg',
        'title': 'Denim jacket',
        'garmentPath': 'ref_file_url',
        'tookMs': 8400,
      });

      expect(render.key, 'abc123');
      expect(render.localPath, '/renders/abc123.jpg');
      expect(render.tookMs, 8400);
    });
  });

  group('ApiClient', () {
    test('builds absolute asset URLs from the configured base', () {
      final api = ApiClient('http://192.168.0.240:8787');
      expect(api.assetUrl('/renders/x.jpg'), 'http://192.168.0.240:8787/renders/x.jpg');
    });
  });
}
