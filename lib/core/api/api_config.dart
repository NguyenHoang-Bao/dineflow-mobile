/// Cấu hình kết nối tới backend DineFlow (Spring Boot).
class ApiConfig {
  ApiConfig._();

  /// URL máy chủ Production trên AWS EC2
  static const String _productionUrl = 'http://13.212.78.140:8000/api';

  /// Cho phép ghi đè khi cần qua lệnh build: flutter run --dart-define=API_BASE_URL=...
  static const String _override = String.fromEnvironment('API_BASE_URL');

  static String get baseUrl {
    if (_override.isNotEmpty) return _override;
    return _productionUrl;
  }

  static String resolveMediaUrl(String url) {
    final media = Uri.tryParse(url);
    if (media == null || !media.hasScheme || !_localHosts.contains(media.host)) return url;

    final base = Uri.parse(baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: media.path,
      query: media.hasQuery ? media.query : null,
    ).toString();
  }

  static const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2', '0.0.0.0', '13.212.78.140'};

  static const Duration timeout = Duration(seconds: 15);
}
