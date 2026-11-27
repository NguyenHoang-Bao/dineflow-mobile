/// Thông tin liên hệ và giờ phục vụ của quán, dùng chung cho mọi màn của Khách hàng.
///
/// Trước đây mỗi màn tự viết: Trợ giúp / Cửa hàng ghi hotline "1800 1234", màn Đặt bàn ghi
/// "1900 1234"; giờ mở cửa ghi 10:00–22:00 nhưng khung giờ đặt bàn lại chỉ 11:00–13:30, 17:00–21:00
/// mà không nói rõ. Đổi số thật của quán ở đây (server chưa có API trả thông tin này).
class RestaurantInfo {
  RestaurantInfo._();

  static const hotline = '1800 1234';
  static const hotlineHours = '8:00 – 22:00';

  static const address = '140 Lê Trọng Tấn, Phường Tây Thạnh, Tân Phú, TP. Hồ Chí Minh';

  /// Giờ mở cửa theo ngày.
  static const openingHours = [
    ('Thứ 2 – Thứ 6', '10:00 – 22:00'),
    ('Thứ 7 – Chủ nhật', '09:00 – 23:00'),
  ];

  /// Khung giờ nhận đặt bàn online (bữa trưa, bữa tối) — cũng là các ô giờ ở màn Đặt bàn.
  static const bookingSlots = [
    '11:00', '11:30', '12:00', '12:30', '13:00', '13:30', '17:00', '17:30',
    '18:00', '18:30', '19:00', '19:30', '20:00', '20:30', '21:00',
  ];

  /// "11:00 – 13:30 và 17:00 – 21:00" (tóm tắt [bookingSlots] để hiện cho khách).
  static const bookingHoursLabel = '11:00 – 13:30 và 17:00 – 21:00';
}
