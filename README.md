
<div align="center">

██████╗ ███████╗ █████╗ ██╗         █████╗  ██████╗ ██████╗
██╔══██╗██╔════╝██╔══██╗██║        ██╔══██╗██╔═══██╗██╔══██╗
██████╔╝█████╗  ███████║██║        ███████║██║   ██║██║  ██║
██╔══██╗██╔══╝  ██╔══██║██║        ██╔══██║██║   ██║██║  ██║
██║  ██║███████╗██║  ██║███████╗    ██║  ██║╚██████╔╝██████╔╝
╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝    ╚═╝  ╚═╝ ╚═════╝ ╚═════╝


### Low-Level Apple Native Display Subsystem & Hardware Clock Governor
*Giải pháp mở khóa pipeline Always-On Display nguyên bản của Apple kết hợp cưỡng bức xung nhịp và độ sáng 5 tầng sâu cho iPhone thế hệ trước.*

<p align="center">
  <img src="https://img.shields.io/badge/FIRMWARE-iOS%2016.0%20—%2018.x-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Firmware" />
  <img src="https://img.shields.io/badge/ARCH-arm64%20|%20arm64e-000000?style=for-the-badge&logo=arm&logoColor=white" alt="Architecture" />
  <img src="https://img.shields.io/badge/ENGINE-BacklightServicesHost-000000?style=for-the-badge&logo=ray-ban&logoColor=white" alt="Engine" />
  <img src="https://img.shields.io/badge/KERNEL-IOKit%20%2F%20QuartzCore-000000?style=for-the-badge&logo=target&logoColor=white" alt="Kernel" />
  <img src="https://img.shields.io/badge/SCHEME-Theos%20Rootless-000000?style=for-the-badge&logo=gnu&logoColor=white" alt="Theos" />
</p>

---

[Giới thiệu](#-01-tổng-quan-dự-án) • [So sánh chi tiết](#-02-bảng-phân-tích-kỹ-thuật) • [Cơ chế Pipeline](#-03-nguyên-lý-pipeline-gốc)

---

</div>

## ⬡ 01. Tổng quan dự án

Các giải pháp AOD cộng đồng jailbreak phát triển trước đây (*LastLook*, *Vampire*, v.v.) hoạt động theo mô hình **AOD Giả lập (Software Emulation)**:
* Khởi tạo một đối tượng `UIWindow` cấp cao đè lên `SBLockScreenViewController`.
* Sử dụng vòng lặp `CADisplayLink` liên tục tính toán lại tọa độ, vẽ lại kim đồng hồ hoặc làm mờ hình nền bằng CPU/GPU.
* Khiến hệ thống luôn trong trạng thái tải liên tục, máy ấm lên nhanh chóng và tốc độ tiêu hao pin rất cao (10–18%/giờ).

**RealAOD** tiếp cận theo hướng hoàn toàn khác: **Đánh thức Subsystem bị ẩn của chính Apple**.

Bắt đầu từ iOS 16, Apple đã đóng gói sẵn toàn bộ kiến trúc Always-On Display bên trong firmware cho dòng máy Pro. Mã nguồn này vẫn tồn tại trên các thiết bị cũ (A11 – A13) nhưng bị khóa bởi các cờ định danh phần cứng (`Gestalt` / `BacklightServices`).

RealAOD can thiệp trực tiếp vào 5 lớp của hệ thống để:
* ✦ **Mở khóa Pipeline gốc:** Đưa hệ điều hành vào trạng thái ngủ nông `BLSBacklightStateAlwaysOn` (State 2) thay vì dập tắt nguồn màn hình (`State 0`).
* ✦ **Tận dụng Shader phần cứng:** Toàn bộ hiệu ứng mờ nền, làm tối đồng hồ và widget được xử lý bằng Metal Shader nguyên bản của `PosterBoard`, không tốn tài nguyên phụ trội.
* ✦ **Bẻ khóa giới hạn Panel Driver:** Cưỡng chế hạ tần số quét thực tế của màn hình xuống **2–20 Hz** và ép dòng điện đèn nền xuống dải siêu mờ (0.002f – 0.020f) để bảo toàn tối đa thời lượng pin.

---

## ⬡ 02. Bảng phân tích kỹ thuật

* **Phương thức khởi tạo (Initialization)**
  * ▹ *AOD Giả lập:* Tạo View/Window riêng, render liên tục bằng vòng lặp phần mềm.
  * ▹ *RealAOD:* Kích hoạt subsystem `BacklightServicesHost` và engine `BLSHAlwaysOnPresentationEngine` gốc của iOS.

* **Bộ máy xử lý đồ họa (Graphics Engine)**
  * ▹ *AOD Giả lập:* Tự tạo layout blur, tự dựng lại các phần tử UI của màn hình khóa.
  * ▹ *RealAOD:* Sử dụng trực tiếp Metal Shaders và chu trình render gốc từ `PosterBoard`.

* **Tần số quét tĩnh (Idle Refresh Rate)**
  * ▹ *AOD Giả lập:* Màn hình bị kẹt ở mức 60 Hz mặc định, GPU phải refresh liên tục.
  * ▹ *RealAOD:* Cưỡng bức can thiệp IOKit Driver hạ chu kỳ quét tấm nền xuống **2–20 Hz**.

* **Cơ chế phản hồi thông báo (Notification Handling)**
  * ▹ *AOD Giả lập:* Phải tự bắt event, tự nạp icon và tự vẽ lại banner (dễ lỗi giao diện).
  * ▹ *RealAOD:* `SBNCNotificationDispatcher` kích xung lên **50 Hz** trong 3.5 giây để hiệu ứng banner bung mượt nguyên bản.

* **Thoát AOD & Trả quyền hệ thống (Wake Transition)**
  * ▹ *AOD Giả lập:* Thường bị khựng hoặc có độ trễ do lệnh giải phóng bộ nhớ của View giả lập.
  * ▹ *RealAOD:* Chuyển đổi tức thì (Zero-Lag), hoàn trả nguyên vẹn quyền điều phối 60 Hz cho kernel và hệ điều hành.

---

## ⬡ 03. Nguyên lý Pipeline gốc


```
[Lock Command]
│
▼
[BLSHBacklightStateMachine: State 2 (AOD)]
│
├─► [IOKit / AppleCLCD2] ────► Ép nhận Mode 2–20 Hz (Nuốt lỗi Driver)
├─► [SBBacklightController] ──► Ép dòng nền cực tiểu (Factor: 0.002f)
└─► [PosterBoard Metal] ──────► Vẽ hình nền mờ tối gốc (Luminance: 1)


## ⬡ 04. Kiến trúc can thiệp 5 tầng

┌─────────────────────────────────────────────────────────────┐
│ LEVEL 05: PREFERENCES & DAEMON IPC                          │
│ » DBRDisplayController | AODREALRootListController          │
├─────────────────────────────────────────────────────────────┤
│ LEVEL 04: METAL SHADERS & SCENE HOSTING                     │
│ » PosterBoard | PRRenderingBacklightEnvironment             │
├─────────────────────────────────────────────────────────────┤
│ LEVEL 03: POWER GOVERNOR & BACKLIGHT CONTROL                │
│ » SBBacklightController | ProcessControl (APNs Lock)        │
├─────────────────────────────────────────────────────────────┤
│ LEVEL 02: DISPLAY SERVER & SCHEDULING                       │
│ » CAWindowServerDisplay | CADisplay (CAFrameRateRange)      │
├─────────────────────────────────────────────────────────────┤
│ LEVEL 01: DRIVER REGISTERS & FRAMEBUFFER                    │
│ » IORegistryEntry | AppleCLCD2 | IOConnectCallMethod        │
└─────────────────────────────────────────────────────────────┘

* **Level 05 — Preferences & Daemon IPC**
  * `DBRDisplayController`: Nạp trực tiếp specifier điều khiển vào *Cài đặt -> Màn hình & Độ sáng -> Màn hình luôn bật*.
  * `AODREALRootListController`: Bộ điều phối CFPreferences hai chiều, đồng bộ giá trị slider tần số quét (2–20 Hz) và độ sáng (2–20) qua Darwin Notification Center.

* **Level 04 — Metal Shaders & Scene Hosting**
  * `PosterBoard` & `PRRenderingBacklightEnvironment`: Tiếp quản toàn bộ pipeline render hình nền khóa, đồng hồ và widget ở mức `backlightLuminance = 1`.
  * Khai thác shader làm tối gốc của Apple, không tạo layer overlay ngoài luồng.

* **Level 03 — Power Governor & Backlight Control**
  * `SBBacklightController`: Chặn hoàn toàn sự kiện
blanking` (tắt màn) từ hệ thống; ép `factor` độ sáng xuống dải cực tiểu `0.002f – 0.020f` (tương đương 0.2% – 2.0% độ sáng thực tế).
  * `ProcessControl`: Giữ socket mạng APNs không bị rơi vào trạng thái ngủ sâu, triệt tiêu hoàn toàn lỗi trễ thông báo đẩy.

* **Level 02 — Display Server & Scheduling (QuartzCore)**
  * `CAWindowServerDisplay`: Bẻ khóa các cờ quản lý hiển thị `supportsVariableRefreshRate` và `supportsArbitraryFrameRates`, cho phép hệ thống nhận tần số quét tùy ý.
  * `CADisplay`: Ghi đè `preferredFrameRateRange` và `setFrameRateRange:`, khóa cứng xung nhịp hiển thị theo giá trị cài đặt.

* **Level 01 — Driver Registers & Framebuffer (Kernel/IOKit)**
  * `IORegistryEntryCreateCFProperties`: Can thiệp trực tiếp vào descriptor driver (`AppleCLCD2` / `IOMobileFramebuffer`), ghi đè `timing-sample-rate` và `min-refresh-rate`.
  * `IOConnectCallMethod`: Nuốt sạch mã lỗi `kIOReturnUnsupportedMode` từ panel cứng khi bị ép hoạt động dưới dải 60 Hz mặc định.

---

## ⬡ 05. Cơ chế điều phối Dynamic Hz


[Lock Device]
│
▼
┌───────────────┐
│ STATIC AOD    │ ◄──────────────────────────────┐
│ 2 — 20 Hz     │                                │
└───────┬───────┘                                │
│                                        │
├────────► [Notification Event]          │ (After 3.5s)
│                 │                      │
│                 ▼                      │
│          ┌───────────────┐             │
│          │ BOOST BURST   │ ────────────┘
│          │ 50 Hz         │
│          └───────────────┘
│
▼ (Screen Wake / Unlock)
┌───────────────┐
│ OS DEFAULT    │
│ 60 Hz         │
└───────────────┘


* **1. Trạng thái tĩnh (Static AOD: 2–20 Hz)**
  * Ngay khi màn hình khóa chuyển sang giao diện luôn bật, driver lập tức hạ chu kỳ làm tươi xuống giá trị cài đặt (mặc định 2 Hz).
  * Tiết kiệm tới 85% chu kỳ render của GPU và chu trình cấp điện cho tấm nền so với các giải pháp chạy 60 Hz liên tục.

* **2. Bung xung tức thời (Boost Burst: 50 Hz)**
  * `SBNCNotificationDispatcher` bắt sự kiện thông báo gửi đến SpringBoard.
  * Tần số quét tự động bung lên **50 Hz** trong thời gian **3.5 giây** để đảm bảo hoạt ảnh banner trượt xuống mượt mà, sau đó tự động hạ lùi về mức tĩnh đã định cấu hình.

* **3. Trả quyền hệ thống (Wake & Unlock: 60 Hz)**
  * Khi phát hiện thao tác chạm sáng màn hình hoặc mở khóa thành công, toàn bộ cờ cưỡng chế lập tức được gỡ bỏ.
  * Quyền điều phối xung nhịp được trao trả ngay lập tức cho iOS ở tần số quét gốc 60 Hz, bảo đảm không gây giật lag hay delay cảm ứng.
