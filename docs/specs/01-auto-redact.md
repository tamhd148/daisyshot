# Đề bài: Tự che thông tin nhạy cảm (Auto Redact)

Trạng thái: **đã duyệt (2026-10-08)** · Phiên bản dự kiến: 1.1 · Chạy 100% offline

## 1. Mục tiêu

Trước khi gửi ảnh chụp cho người khác, Daisyshot tự tìm các thông tin nhạy cảm trong ảnh (email, số điện thoại, số thẻ,
API key, mật khẩu…) và che chúng chỉ với một cú bấm. Nếu người dùng quên che mà vẫn copy hoặc kéo ảnh đi, app cảnh báo nhẹ.

Điểm khác biệt: không chỉ che email hay số điện thoại cơ bản mà còn **phát hiện secret của lập trình viên**
(API key, token, private key, mật khẩu trong file cấu hình) và **mẫu riêng của Việt Nam** (số điện thoại VN, CCCD).

## 2. Phạm vi

**Có làm**
- Quét chữ trong ảnh, che **đúng đoạn chữ nhạy cảm** chứ không che cả dòng (ví dụ chỉ che `an@gmail.com` trong dòng
  `Liên hệ: an@gmail.com`).
- Che khuôn mặt (tuỳ chọn, mặc định tắt).
- Kết quả là các mảng Redact bình thường: sửa, xoá, đổi kiểu che, undo được như vẽ tay.
- Cảnh báo khi copy, kéo hoặc chia sẻ ảnh còn chứa secret chưa che.

**Không làm (bản này)**
- Che tên người hoặc địa chỉ nhà bằng AI: dễ báo nhầm, để bản sau.
- Che trong video đang quay.
- Che trong ảnh đã lưu trên ổ đĩa mà không mở bằng Daisyshot.

## 3. Các loại thông tin phát hiện

Mỗi loại là một **nhóm** bật/tắt riêng trong Settings. Cột "Mặc định" là trạng thái lúc cài app.

| Nhóm | Ví dụ | Cách nhận diện | Mặc định |
|---|---|---|---|
| **Secret / API key** | `sk-ant-…`, `sk-…`, `ghp_…`, `github_pat_…`, `AKIA…`, `xoxb-…`, `AIza…`, `sk_live_…`, JWT `eyJ…`, `-----BEGIN … PRIVATE KEY-----` | Mẫu cố định theo từng nhà cung cấp; thêm chuỗi ≥ 24 ký tự có độ ngẫu nhiên cao đứng sau `key`, `token`, `secret`, `password`, `Authorization: Bearer` | Bật |
| **Mật khẩu** | `password: hunter2`, `PASS=…`, `mật khẩu: …` | Chỉ che phần giá trị sau nhãn, không che nhãn | Bật |
| **Email** | `an.nguyen@company.vn` | `NSDataDetector` + regex | Bật |
| **Số điện thoại** | `0912 345 678`, `+84 912…`, số quốc tế | `NSDataDetector` + mẫu VN `(\+84\|0)(3\|5\|7\|8\|9)\d{8}` | Bật |
| **Thẻ ngân hàng** | `4111 1111 1111 1111` | 13–19 chữ số **và** qua kiểm tra Luhn (tránh che nhầm số thường) | Bật |
| **CCCD / CMND** | 12 hoặc 9 chữ số đứng cạnh chữ "CCCD", "CMND", "Căn cước" | Chỉ che khi có nhãn đi kèm, để không che nhầm mọi dãy 12 số | Bật |
| **Số tài khoản** | dãy 8–19 số cạnh chữ "STK", "Số tài khoản", "Account", "IBAN" | Có nhãn mới che | Bật |
| **Địa chỉ IP** | `192.168.1.10`, IPv6 | Regex, kiểm tra từng octet ≤ 255 | Tắt |
| **URL có token** | `https://…?token=…&key=…` | Chỉ che phần giá trị của tham số nhạy cảm | Bật |
| **Khuôn mặt** | ảnh đại diện, webcam | `VNDetectFaceRectanglesRequest` | Tắt |

Người dùng có thể thêm **mẫu tự định nghĩa**: một danh sách từ khoá hoặc regex trong Settings (ví dụ tên công ty, mã
dự án nội bộ).

**Chịu lỗi OCR:** OCR hay nhầm `O`/`0`, `l`/`1`, `S`/`5`. Với secret và thẻ, so mẫu sau khi chuẩn hoá các ký tự dễ nhầm
này, để vẫn bắt được khi OCR đọc sai một chữ.

## 4. Trải nghiệm người dùng

### 4.1 Trong trình Annotate
1. Khi chọn công cụ **Redact**, thanh tuỳ chọn có thêm nút **"Auto"** (biểu tượng ✨ + ô che).
   Phím tắt đề xuất: `⇧⌘R`.
2. Bấm vào: app quét (ảnh 5K mất dưới 1 giây; nếu lâu hơn thì hiện vòng xoay nhỏ trên nút, không khoá giao diện).
3. Các vùng tìm được hiện ra ngay trên ảnh dưới dạng **khung viền nét đứt màu đỏ, chưa che**. Đồng thời mở một popover nhỏ:

   ```
   Tìm thấy 7 mục nhạy cảm
   ☑ Secret / API key      2
   ☑ Email                 3
   ☑ Số điện thoại         1
   ☐ Địa chỉ IP            1
   Kiểu che: [ Đen đặc ▾ ]
   [ Bỏ qua ]   [ Che 6 mục ]
   ```

   - Bỏ tick một nhóm thì các khung của nhóm đó mờ đi.
   - Click vào một khung trên ảnh để bỏ hoặc chọn riêng mục đó.
4. Bấm **"Che N mục"**: mỗi mục thành một mảng Redact; toàn bộ là **một bước undo**.
5. Không tìm thấy gì: popover báo "Không thấy thông tin nhạy cảm", tự đóng sau 1,5 giây.

### 4.2 Trên thumbnail Quick Access
- Menu chuột phải có thêm mục **"Auto Redact"**: che ngay theo cài đặt mặc định, không cần mở trình Annotate.
  Thumbnail cập nhật, kèm thông báo nhỏ "Đã che 6 mục — Hoàn tác".
- Nếu ảnh có **secret chưa che**, góc thumbnail hiện một chấm cảnh báo màu cam (xem 4.3).

### 4.3 Cảnh báo trước khi gửi đi
- Sau mỗi lần chụp, app quét ngầm (không ảnh hưởng tốc độ chụp hay hiện thumbnail).
- Nếu phát hiện **Secret / Mật khẩu / Thẻ** (nhóm nguy hiểm) mà người dùng **copy, kéo ra app khác hoặc chia sẻ**,
  một banner nhỏ hiện cạnh thumbnail hoặc thanh dưới của trình Annotate:
  > ⚠︎ Ảnh có 2 API key chưa được che. **[Che & copy lại]** [Bỏ qua]
- Không chặn thao tác: ảnh vẫn được copy như bình thường. "Che & copy lại" sẽ ghi đè clipboard bằng bản đã che.
- Có tuỳ chọn tắt cảnh báo này.

### 4.4 Tự che khi chụp (tuỳ chọn)
- Settings › Screenshots: **"Tự động che thông tin nhạy cảm sau khi chụp"**, mặc định **tắt**.
- Khi bật: ảnh đi vào thumbnail, clipboard và file **đã được che sẵn**. Các mảng che vẫn sửa được nếu mở bằng Annotate.

## 5. Kiểu che

- Mặc định cho Auto Redact là **Đen đặc** (blackout).
- Lý do: chữ bị **pixelate có thể khôi phục lại được** bằng công cụ sẵn có (ví dụ Unredacter), nên không an toàn cho secret.
- Người dùng có thể chọn kiểu khác. Khi chọn Pixelate cho nhóm Secret, hiện một dòng chú thích:
  "Pixelate có thể bị giải mã — nên dùng Đen đặc hoặc Secure Blur".
- Kích thước mảng che: phình ra 2 pt mỗi phía để không lộ viền chữ.

## 6. Settings (pane mới hoặc trong Screenshots)

**Thông tin nhạy cảm**
- Danh sách nhóm ở mục 3, mỗi nhóm một checkbox.
- Kiểu che mặc định: Đen đặc / Secure Blur / Smooth Blur / Pixelate.
- ☐ Tự động che sau khi chụp
- ☐ Cảnh báo khi copy/chia sẻ ảnh còn secret (mặc định tắt)
- Mẫu tự định nghĩa: danh sách + nút thêm. Mỗi dòng là từ khoá hoặc `/regex/`.

## 7. Thiết kế kỹ thuật (tóm tắt)

**Module mới**
- `Annotate/SensitiveScanner.swift`: nhận `CGImage`, trả về `[Finding]` gồm `{ category, rect (toạ độ ảnh), text }`.

**Nguồn dữ liệu**
- Dùng `VNRecognizeTextRequest` (đã có trong `TextRecognizer`).
- Lấy khung của **đúng đoạn khớp** bằng `VNRecognizedText.boundingBox(for: range)`.
- Kết quả OCR được cache theo ảnh (giống `ImageAnalysis`), quét lại không tốn thêm.

**Đầu ra trong Annotate**
- Tạo `Annotation(kind: .redact, redactStyle: …)` như hiện có.
- **Không thêm kiểu dữ liệu mới**, file `.daisyshot` cũ vẫn mở được.

**Lưu ý về file `.daisyshot`**
- Ảnh gốc vẫn nằm bên dưới mảng che, giống như che tay hiện nay.
- Ảnh xuất ra (PNG/JPG/clipboard) thì đã bị **xoá điểm ảnh thật**.
- Khi lưu `.daisyshot` có secret bị che, hiện chú thích một lần: "File .daisyshot giữ ảnh gốc — chỉ gửi PNG/JPG cho người khác".

**Hiệu năng**
- Quét chạy nền.
- Ảnh 5K trên chip M1 dưới 1 giây.
- Không quét lại nếu ảnh không đổi.

**Kiểm thử**
- Một hàm `selfTest()` chạy trên bộ ảnh mẫu tự sinh có chứa từng loại thông tin.
- Đo tỉ lệ bắt đúng và báo nhầm. Thêm một bộ "câu dễ báo nhầm" (số hoá đơn, mã đơn hàng, ngày tháng) để chắc không bị che.

## 8. Tiêu chí nghiệm thu

1. Ảnh chụp màn hình Terminal có `export OPENAI_API_KEY=sk-…`: chỉ phần key bị che, `export OPENAI_API_KEY=` vẫn đọc được.
2. Ảnh hộp thư có 3 email: đủ 3 email được tìm thấy, phần chữ xung quanh không bị che.
3. Dãy `1234 5678 9012 3456` (sai Luhn) **không** bị coi là thẻ; `4111 1111 1111 1111` thì có.
4. Số `0912 345 678` và `+84 912 345 678` đều bị bắt.
5. "Che N mục" xong, một lần ⌘Z gỡ hết.
6. Copy ảnh còn secret: banner hiện. Bấm "Che & copy lại" thì clipboard chứa ảnh đã che.
7. Quét không làm giật giao diện: vẫn kéo, zoom canvas mượt khi đang quét.
8. Không có bất kỳ kết nối mạng nào trong toàn bộ quá trình.

## 9. Đã chốt

| # | Câu hỏi | Quyết định |
|---|---|---|
| A | Kiểu che mặc định | **Đen đặc** |
| B | Cảnh báo khi copy ảnh còn secret | Có làm, **mặc định tắt** |
| C | Tự che sau khi chụp | Có làm, mặc định tắt |
| D | Che khuôn mặt | **Làm ở bản này**, mặc định tắt |
| E | Mẫu tự định nghĩa | Có, dạng danh sách đơn giản |
