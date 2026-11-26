# DineFlow – Mobile App (Flutter)

Ứng dụng quản lý nhà hàng & quán cafe **DineFlow** dành cho khách hàng, nhân viên order, thu ngân và quản lý. 
Ứng dụng đã được tích hợp hoàn chỉnh với **Production Backend trên AWS EC2**, tự động đồng bộ thời gian thực và tích hợp cổng thanh toán ngân hàng tự động **SePay (VietQR)**.

---

## 🚀 Kết nối Backend & Thanh toán SePay

* **Production Backend API:** `https://dineflow.13-212-78-140.sslip.io/api` (Mặc định trong `lib/core/api/api_config.dart`, kết nối tự động bảo mật HTTPS/SSL).
* **Cổng thanh toán SePay:**
  * Ngân hàng: **MBBank**
  * Số tài khoản: **14580886868**
  * Tên chủ tài khoản: **NGUYEN HOANG BAO**
  * Cơ chế: Quét mã VietQR tự động điền nội dung (`DF-xxxx` hoặc `OD-xxxx`). Khi khách chuyển khoản thật, SePay Webhook tự động kích hoạt backend xác nhận đơn/lịch đặt bàn, app tự động nhảy sang màn hình thành công và gửi thông báo.

---

## 🛠️ Hướng dẫn cài đặt và chạy (Dành cho Dev)

1. **Clone repository:**
   ```bash
   git clone https://github.com/NguyenHoang-Bao/dineflow-mobile.git
   cd dineflow-mobile
   ```

2. **Cài đặt thư viện dependencies:**
   ```bash
   flutter pub get
   ```

3. **Chạy ứng dụng (trên máy ảo Android / iOS / máy thật):**
   ```bash
   flutter run
   ```
   > Không cần cài đặt backend local, app tự động gọi Production API trên AWS EC2.

---

## 👥 Danh sách tài khoản thử nghiệm

| Vai trò | Số điện thoại | Mật khẩu | Chức năng chính |
| :--- | :--- | :--- | :--- |
| **Khách hàng** | `0900000004` | `123456` | Đặt bàn, chọn món trước, thanh toán cọc SePay, tích điểm, ví voucher |
| **Nhân viên Order** | `0900000002` | `123456` | Xem sơ đồ bàn, gọi món tại bàn, gộp bàn, chuyển đơn sang bếp |
| **Thu ngân** | `0900000003` | `123456` | Thanh toán hóa đơn, in hóa đơn, áp mã giảm giá, quét QR SePay |
| **Quản trị viên** | `0900000001` | `123456` | Báo cáo doanh thu, quản lý thực đơn, quản lý bàn/khu vực, nhân sự |

*(Người dùng mới cũng có thể bấm **"Đăng ký ngay"** ở màn hình đăng nhập để tạo tài khoản riêng)*.