import '../core/api/api_client.dart';
import 'loyalty_rules.dart';

/// Tài khoản nhận chuyển khoản của nhà hàng, dùng để tạo mã VietQR.
class RestaurantBank {
  /// Mã ngân hàng theo VietQR (vd `VCB`).
  final String code;
  final String name;
  final String accountNo;
  final String accountName;

  const RestaurantBank({
    required this.code,
    required this.name,
    required this.accountNo,
    required this.accountName,
  });

  factory RestaurantBank.fromJson(Map<String, dynamic> json) => RestaurantBank(
        code: json['code'] as String,
        name: json['name'] as String,
        accountNo: json['account_no'] as String,
        accountName: json['account_name'] as String,
      );

  /// Ảnh mã VietQR cho số tiền [amount] với nội dung chuyển khoản [note].
  String qrImageUrl(double amount, String note) =>
      'https://img.vietqr.io/image/$code-$accountNo-compact2.png'
      '?amount=${amount.toInt()}'
      '&addInfo=${Uri.encodeComponent(note)}'
      '&accountName=${Uri.encodeComponent(accountName)}';
}

/// Cấu hình dùng chung tải từ `GET /api/settings` (server: config/restaurant.php, config/loyalty.php).
///
/// Tải một lần sau khi đăng nhập ([AppData.load]). Thay cho tài khoản ngân hàng và quy tắc
/// thành viên trước đây viết cứng trong app.
class SettingsRepository {
  SettingsRepository({ApiClient? api}) : _api = api ?? ApiClient.instance;

  /// Không phải `final` để test thay bằng bản giả.
  static SettingsRepository instance = SettingsRepository();

  final ApiClient _api;

  /// Tài khoản nhận chuyển khoản; mặc định là tài khoản MBBank của quán theo SePay.
  RestaurantBank? bank = const RestaurantBank(
    code: 'MBBank',
    name: 'MBBank',
    accountNo: '14580886868',
    accountName: 'NGUYEN HOANG BAO',
  );

  Future<void> load() async {
    try {
      final res = await _api.get('/settings');
      final data = res.map;
      bank = RestaurantBank.fromJson((data['restaurant'] as Map<String, dynamic>)['bank'] as Map<String, dynamic>);
      LoyaltyRules.apply(data['loyalty'] as Map<String, dynamic>);
    } catch (_) {
      // Giữ thông tin MBBank mặc định nếu mất mạng
    }
  }
}
