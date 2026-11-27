import 'dart:developer' as dev;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../app/app_navigator.dart';
import '../api/api_client.dart';

/// Quản lý nhận Push Notification qua Firebase Cloud Messaging (FCM).
class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _initialized = false;
  String? _fcmToken;

  String? get fcmToken => _fcmToken;

  /// Khởi tạo Firebase và đăng ký nhận thông báo.
  Future<void> init() async {
    if (_initialized) return;

    try {
      await Firebase.initializeApp();
      _initialized = true;
      dev.log('[FCM] Firebase initialized successfully.', name: 'FcmService');

      // 1. Xin quyền thông báo (iOS & Android 13+)
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      dev.log('[FCM] Permission status: ${settings.authorizationStatus}', name: 'FcmService');

      // 2. Lấy FCM Device Token
      _fcmToken = await messaging.getToken();
      dev.log('[FCM] Device Token: $_fcmToken', name: 'FcmService');

      // 3. Lắng nghe khi token thay đổi
      messaging.onTokenRefresh.listen((newToken) {
        _fcmToken = newToken;
        dev.log('[FCM] Token refreshed: $_fcmToken', name: 'FcmService');
        syncTokenToBackend();
      });

      // 4. Lắng nghe thông báo khi app đang mở (Foreground)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        dev.log('[FCM Foreground] Nhận thông báo: ${message.notification?.title} - ${message.notification?.body}',
            name: 'FcmService');
        final title = message.notification?.title ?? 'Thông báo từ DineFlow';
        final body = message.notification?.body ?? '';
        final context = AppNavigator.key.currentContext;
        if (context != null) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1E293B),
              elevation: 6,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              content: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEA580C).withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.notifications_active, color: Color(0xFFEA580C), size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                        ),
                        if (body.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            body,
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      });

      // 5. Lắng nghe khi người dùng bấm vào thông báo để mở app
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        dev.log('[FCM Opened] Mở app từ thông báo: ${message.data}', name: 'FcmService');
      });
    } catch (e) {
      dev.log('[FCM] Chưa cấu hình google-services.json hoặc không chạy được Firebase: $e', name: 'FcmService');
    }
  }

  /// Gửi FCM Token thiết bị lên Backend Spring Boot để lưu cho User hiện tại.
  Future<void> syncTokenToBackend() async {
    if (_fcmToken == null || _fcmToken!.isEmpty) return;

    try {
      await ApiClient.instance.post('/notifications/fcm-token', body: {
        'token': _fcmToken,
      });
      dev.log('[FCM] Đã đồng bộ FCM Token lên server thành công.', name: 'FcmService');
    } catch (e) {
      dev.log('[FCM] Bỏ qua lỗi gửi token lên server (chưa đăng nhập hoặc offline): $e', name: 'FcmService');
    }
  }
}
