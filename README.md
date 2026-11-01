<div align="center">

# 🌙 RealAOD

**Mở khóa Always-On Display gốc của Apple trên iPhone không được hỗ trợ chính thức**

[![Platform](https://img.shields.io/badge/Platform-iOS%2016.0--18.0-blue?style=flat-square&logo=apple)](https://github.com/)
[![Architecture](https://img.shields.io/badge/Architecture-arm64%20%7C%20arm64e-orange?style=flat-square)](https://github.com/)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Theos](https://img.shields.io/badge/Built%20with-Theos-9b59b6?style=flat-square)](https://theos.dev/)

[Giới thiệu](#-giới-thiệu) · [Tính năng](#-tính-năng) · [Cài đặt](#-cài-đặt) · [Cấu trúc](#-cấu-trúc-dự-án) · [Giới hạn](#-giới-hạn-kỹ-thuật) · [Đóng góp](#-đóng-góp)

</div>

---

## 📖 Giới thiệu

**RealAOD** là một tweak jailbreak được thiết kế để **mở khóa engine Always-On Display (AOD) gốc của Apple** — thứ vốn đã tồn tại trong iOS nhưng bị ẩn đi trên các mẫu iPhone không được hỗ trợ chính thức.

> ⚠️ **Đây không phải AOD giả lập.** Tweak này không tự vẽ đồng hồ, không tự tạo hiệu ứng mờ. Nó chỉ **mở các cổng kiểm tra phần mềm** để engine `BLSHAlwaysOnPresentationEngine` của Apple tự chạy — giống hệt cách iPhone 14 Pro/15 Pro hoạt động.

### 🎯 Tại sao RealAOD?

| | AOD giả lập (LastLook, v.v.) | **RealAOD** |
|---|---|---|
| Đồng hồ | Tự vẽ | Engine gốc Apple |
| Hiệu ứng mờ | Tự làm | Shader gốc |
| Thông báo | Tự xử lý | Hệ thống xử lý |
| Tiêu hao pin | Cao (màn hình luôn sáng) | Tối ưu (nếu có LTPO) |
| Trải nghiệm | "Giống" hàng thật | **Là hàng thật** |

---

## ✨ Tính năng

- ✅ **Mở khóa AOD gốc** — không tự vẽ UI
- ✅ **Công tắc bật/tắt** trong Cài đặt (mặc định tắt)
- ✅ **Nút Respring** tích hợp — áp dụng thay đổi ngay
- ✅ **Hỗ trợ đa tiến trình** — hook đồng thời SpringBoard, backboardd, PosterBoard, Preferences
- ✅ **Tương thích rootless & rootful**
- ✅ **Không xung đột** với các tweak AOD khác (nếu tắt công tắc)

---

## 📱 Thiết bị hỗ trợ

| Thiết bị | iOS | Trạng thái |
|---|---|---|
| iPhone XS / XS Max | 18.0+ | ✅ Hoạt động đầy đủ |
| iPhone XS / XS Max | 16.x – 17.x | ⚠️ Thử Nghiệm (Chưa thể kiểm chứng) |
| iPhone 8 / 8 Plus / X | 16.x | ✅ Hoạt động đầy đủ |
| iPhone 11 trở lên | 16.0+ | ⚠️ Thử nghiệm (chưa kiểm chứng) |

> **Lưu ý**: iPhone 6s/7Plus dừng ở iOS 16.7.x — không thể lên iOS 17/18. Các máy này không có engine AOD gốc trong iOS, nên tweak sẽ không có tác dụng.

---

## 🚀 Cài đặt

### Yêu cầu

- Thiết bị đã **jailbreak** (Dopamine, palera1n)
- **Theos** đã cài đặt (nếu build từ source)
- **PreferenceLoader** (để hiện Settings)

### Cài từ file .deb

```bash
# Tải file .deb từ Releases
# Chuyển vào thiết bị qua SSH/SFTP
dpkg -i com.jb.aodreal_0.0.1_iphoneos-arm64.deb
killall -9 SpringBoard
