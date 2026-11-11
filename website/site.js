// Daisyshot — site behaviour. No dependencies, no network.
const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ───────── language (English is the markup; Vietnamese lives here) ─────────
const VI = {
  n1: 'Chụp màn hình', n2: 'Studio', n3: 'Riêng tư', n4: 'Mã nguồn mở', n5: 'Tải về',
  h0: 'Miễn phí &amp; mã nguồn mở · Chạy hoàn toàn ngoại tuyến',
  h1: '<span class="up" style="--d:1">Để màn hình của bạn</span> <span class="up" style="--d:2">đẹp <span class="sel">đến thế này.</span></span>',
  h2: 'Ảnh chụp màn hình, quay màn hình và video màn hình chỉn chu — trong một ứng dụng Mac nhỏ gọn, thuần native, nằm ngay trên thanh menu.',
  h3: 'Tải cho macOS', h4: 'Xem trên GitHub', h5: 'macOS 15 trở lên', h6: 'Giấy phép MIT',
  h7: 'Thử xem — kéo chuột ở bất kỳ đâu phía trên để chụp màn hình.', h8: 'Âm thanh',
  s0: 'Chụp màn hình', s1: 'Chụp mọi thứ.<br><em>Giải thích trong vài giây.</em>',
  s2: 'Một vùng, một cửa sổ, toàn màn hình, lặp lại vùng vừa chụp, hay cả một trang cuộn dài. Rồi chỉ vào điều quan trọng.',
  t1: 'Mũi tên', t2: 'Hình khối', t3: 'Văn bản', t4: 'Bút &amp; bút dạ quang', t5: 'Làm mờ &amp; pixel hoá', t6: 'Spotlight', t7: 'Đánh số bước', t8: 'Cắt', t9: 'Hình nền &amp; lề',
  r0: 'Xử lý trên máy', r1: 'Auto Redact tìm ra bí mật trước khi người xem kịp thấy.',
  r2: 'Daisyshot đọc chữ trong ảnh chụp và chỉ che đúng phần giá trị, nên nhãn bên cạnh vẫn đọc được. Tất cả chạy trên máy Mac của bạn bằng Vision của Apple.',
  f1: 'Khoá API &amp; secret', f2: 'Mật khẩu', f3: 'Email', f4: 'Số điện thoại', f5: 'Số thẻ', f6: 'Số CCCD / CMND', f7: 'Số tài khoản (STK)', f8: 'Khuôn mặt', f9: 'Mẫu của riêng bạn',
  d0: 'Khoá của workspace production', d1: 'Đã che trên máy', d2: 'Chủ sở hữu', d3: 'Secret key', d4: 'Thẻ', d5: 'Số request hôm nay', d6: 'Chạy Auto Redact', d7: 'Xem lại',
  b0: '…và cả một hộp đồ nghề nữa.',
  b1: 'Chụp cuộn', b2: 'Chụp cả trang web, đoạn chat hay tài liệu thành một ảnh dài. Có thể tự cuộn giúp bạn.',
  b3: 'Sao chép chữ từ mọi thứ', b4: 'Kéo qua video, hình ảnh hay PDF bị khoá — chữ đã nằm trong clipboard.',
  b5: 'Mã QR', b6: 'Đọc mã QR ngay trên màn hình. Không cần điện thoại.',
  b7: 'Ghim lên trên', b8: 'Giữ ảnh tham khảo nổi trên mọi cửa sổ trong lúc làm việc.',
  b9: 'Hẹn giờ', b10: 'Mở sẵn menu hay trạng thái hover, rồi để đồng hồ đếm ngược chụp giúp.',
  b11: 'Quick Access', b12: 'Mỗi ảnh chụp hiện thành một thẻ nhỏ. Rê chuột vào và bấm một phím, hoặc kéo thẳng sang ứng dụng khác.',
  b13: 'Lịch sử chụp', b14: 'Mọi thứ bạn đã chụp, tìm kiếm được. Lỡ đóng một thẻ? Khôi phục lại ngay.', b15: 'Tìm trong lịch sử',
  q1: 'Sao chép', q2: 'Lưu', q3: 'Chú thích', q4: 'Ghim',
  u0: 'Studio', u1: 'Bấm quay. Cứ làm việc như bình thường.<br><em>Daisyshot lo phần chỉn chu.</em>',
  p0: 'Cách thông thường', p0b: 'Một bản quay màn hình thô. Phẳng, chật chội, khó theo dõi.',
  p1: 'Hình nền, lề, đổ bóng', p1b: 'Hình nền macOS, gradient hoặc ảnh của bạn, kèm góc bo tròn.',
  p2: 'Zoom bám theo con trỏ', p2b: 'Tự đặt đúng nơi có thao tác, và chỉnh được trên timeline.',
  p3: 'Con trỏ mượt và to hơn', p3b: 'Đường chuột rung lắc thành những đường lướt, có hiệu ứng click và motion blur.',
  p4: 'Hiện phím bấm', p4b: 'Phím tắt hiện lên khi bạn bấm, để người xem làm theo được.',
  p5: 'Đoạn gõ phím, tua nhanh', p5b: 'Các đoạn gõ phím được tìm sẵn. Tăng tốc chỉ với một cú nhấp.',
  p6: 'Bong bóng camera', p6b: 'Đặt khuôn mặt bạn ở góc, hoặc chuyển sang chỉ camera trong chốc lát.',
  p7: 'Mọi khung hình, một lần xuất', p7b: 'Lấp đầy khung và bám theo con trỏ cho 9:16, 1:1 hay 4:5, xếp hàng sau video chính.',
  p8: 'Phát hiện gõ phím · nhanh gấp 4', p9: 'Trước', p10: 'Với Daisyshot',
  e0: 'Tự động theo mặc định. Của bạn đến từng khung hình.',
  e1: 'Một timeline thực thụ', e2: 'Cắt, tỉa, tách và tăng tốc clip. Dời một đoạn zoom, kéo dài, hoặc xoá đi.',
  e3: 'Mặt nạ tự tìm chữ', e4: 'Mặt nạ làm mờ và làm nổi tự tìm chữ nhạy cảm trong bản quay, và cảnh báo khi nội dung dịch chuyển.',
  e5: 'Âm thanh gọn gàng', e6: 'Nhạc nền, khử nhiễu và chuẩn hoá âm lượng, có sẵn.',
  e7: 'Preset &amp; Quick Export', e8: 'Lưu phong cách một lần. Xuất ngay sau khi quay mà không cần mở trình chỉnh sửa.',
  e9: 'Quay mọi thứ', e10: 'Một màn hình, một cửa sổ, một vùng, hay iPhone / iPad qua USB. Micro và âm thanh hệ thống theo từng ứng dụng.',
  e11: 'Sinh ra để thuyết trình', e12: 'Ghi chú diễn giả và teleprompter, làm nổi cú click, GIF hoặc MP4, và khôi phục nếu có sự cố.',
  e13: 'Xuất thẳng từ Studio. Hình nền, zoom, con trỏ và phím bấm đều được thêm sau khi quay.',
  v0: 'Riêng tư', v1: '<span><em>Không</em> tài khoản.</span> <span><em>Không</em> đám mây.</span> <span><em>Không</em> theo dõi.</span>',
  v2: 'Không gì rời khỏi máy Mac của bạn.',
  v3: 'Yêu cầu mạng duy nhất', v4: 'Mỗi ngày một lần, Daisyshot hỏi GitHub xem có bản phát hành mới không. Không gửi gì về bạn hay tệp của bạn, và bạn có thể tắt đi. Bản cập nhật chỉ được cài khi mang chữ ký phát hành Ed25519 của Daisyshot.',
  v5: 'Phân tích', v6: 'Tài khoản', v7: 'Tải lên',
  v8: 'Quyền truy cập, chỉ khi tính năng cần đến',
  v9: 'Ghi màn hình &amp; âm thanh hệ thống', v10: 'Chụp và quay màn hình',
  v11: 'Trợ năng (Accessibility)', v12: 'Phím bấm, phát hiện gõ phím, đưa cửa sổ lên trước',
  v13: 'Camera &amp; Micro', v14: 'Bong bóng camera và giọng nói của bạn',
  k0: 'Ưu tiên bàn phím', k1: 'Chào đón đôi tay nhanh.<br><em>Cả script nữa.</em>',
  k2: 'Thanh tất-cả-trong-một', k3: 'Chụp vùng', k4: 'Chụp toàn màn hình', k5: 'Chụp cửa sổ', k6: 'Chụp cuộn', k7: 'Chụp chữ (OCR)', k8: 'Quay màn hình', k9: 'Ẩn biểu tượng desktop',
  k10: '# Điều khiển Daisyshot từ script, launcher và Shortcuts',
  k11: 'Mọi phím tắt đều đổi được, và Studio có bộ phím tắt riêng cũng tuỳ chỉnh được. Ứng dụng khác cần bạn đồng ý ở lần đầu gửi lệnh.',
  o1: 'thư viện bên thứ ba', o2: 'Swift thuần, SwiftUI và AppKit', o3: 'ngôn ngữ: English, Tiếng Việt, 한국어, 日本語, 简体中文', o4: 'Đọc, tự build, hay fork tuỳ ý.',
  o5: 'Một ứng dụng nhìn thấy màn hình của bạn nên là ứng dụng bạn đọc được mã nguồn.', o6: 'Xem mã nguồn ↗', o7: 'Ủng hộ trên Ko-fi ↗',
  g1: 'Để màn hình của bạn<br>đẹp đến thế này.', g2: 'Tải miễn phí cho macOS', g3: 'Lần mở đầu tiên: ba bước nhỏ',
  g4: 'Mở tệp .dmg và kéo Daisyshot vào Applications.',
  g5: 'Bản build chưa được Apple notarize nên macOS sẽ chặn lần mở đầu. Bấm <b>Done</b>, mở <b>System Settings › Privacy &amp; Security</b> rồi chọn <b>Open Anyway</b>.',
  g6: 'Cho phép Ghi màn hình &amp; âm thanh hệ thống, rồi mở lại Daisyshot. Ứng dụng nằm trên thanh menu.',
  x1: 'Bản phát hành', x2: 'Bảo mật', x3: 'Giấy phép', x4: '© 2026 Tam Hoang. Mã nguồn theo Giấy phép MIT.', x5: 'Trang này không tải tracker, font hay bất cứ thứ gì từ bên thứ ba.',
};
const EN = {}; $$('[data-i]').forEach(el => EN[el.dataset.i] ??= el.innerHTML);
const store = { get: k => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
const promo = $('#promo');

function frame() {   // the selection frame around the headline's last words
  const sel = $('.hero .sel'); if (!sel) return;
  sel.insertAdjacentHTML('beforeend', '<span class="fr" aria-hidden="true">' + [[0, 0], [50, 0], [100, 0], [0, 50], [100, 50], [0, 100], [50, 100], [100, 100]].map(([x, y]) => `<i style="left:${x}%;top:${y}%"></i>`).join('') + '<b></b></span>');
  const size = () => { const r = sel.getBoundingClientRect(); $('b', sel).textContent = `${Math.round(r.width)} × ${Math.round(r.height)}`; };
  size(); addEventListener('resize', size);
}
function setLang(l, first) {
  document.documentElement.lang = l;
  $$('[data-i]').forEach(el => { el.innerHTML = (l == 'vi' && VI[el.dataset.i]) || EN[el.dataset.i]; });
  $$('.steps p').forEach(p => { p.innerHTML = `<span>${p.innerHTML}</span>`; });
  frame();
  const src = l == 'vi' ? 'assets/promo-vietsub.mp4' : 'assets/promo.mp4';
  if (!first || l == 'vi') { promo.src = src; promo.play().catch(() => {}); }
  store.set('lang', l);
}
setLang(store.get('lang') || (navigator.language.startsWith('vi') ? 'vi' : 'en'), true);
$('#lang').onclick = () => setLang(document.documentElement.lang == 'vi' ? 'en' : 'vi');

// ───────── reveal on scroll, lazy video ─────────
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }), { rootMargin: '0px 0px -8% 0px' });
$$('.rv').forEach(el => io.observe(el));
const vio = new IntersectionObserver(es => es.forEach(e => e.isIntersecting ? e.target.play().catch(() => {}) : e.target.pause()), { threshold: .2 });
$$('video').forEach(v => vio.observe(v));
$('#sound').onclick = e => { promo.muted = !promo.muted; e.currentTarget.setAttribute('aria-pressed', !promo.muted); if (!promo.muted) promo.play(); };

// ───────── QR tile (decorative pattern, finder squares included) ─────────
{ let s = 7, out = ''; const rnd = () => (s = s * 16807 % 2147483647) / 2147483647;
  const finder = (x, y) => (x < 7 && y < 7) || (x > 13 && y < 7) || (x < 7 && y > 13);
  const fin = (x, y) => { const a = x > 13 ? x - 14 : x, b = y > 13 ? y - 14 : y; return a == 0 || a == 6 || b == 0 || b == 6 || (a > 1 && a < 5 && b > 1 && b < 5); };
  for (let y = 0; y < 21; y++) for (let x = 0; x < 21; x++) if (finder(x, y) ? fin(x, y) : (x != 7 && y != 7 && x != 13 && y != 13 || !finder(x - 1, y) && !finder(x, y - 1) && !finder(x + 1, y) && !finder(x, y + 1)) && rnd() > .5) out += `<rect x="${x}" y="${y}" width="1.02" height="1.02"/>`;
  $('#qr').innerHTML = out; }

// ───────── Auto Redact demo ─────────
const demo = $('#demo');
$('#redactBtn').onclick = () => { if (demo.classList.toggle('on')) return; setTimeout(() => demo.classList.add('on'), 650); };
new IntersectionObserver((es, o) => es.forEach(e => { if (e.isIntersecting) { setTimeout(() => demo.classList.add('on'), 700); o.disconnect(); } }), { threshold: .7 }).observe(demo);

// ───────── scroll: nav, hero film tilt, Studio story ─────────
const nav = $('#nav'), film = $('#film'), story = $('#story'), stage = $('#stage'), canvas = $('#canvas'), steps = $$('#steps li');
let lastY = 0, step = -1;
function setStep(n) {
  if (n == step) return; step = n;
  for (let i = 1; i < 8; i++) stage.classList.toggle('on' + i, n >= i);
  steps.forEach((li, i) => li.classList.toggle('on', i == n));
}
function onScroll() {
  const y = scrollY, vh = innerHeight;
  nav.classList.toggle('hide', y > lastY && y > 500); lastY = y;
  nav.style.setProperty('--spin', (y / 8).toFixed(1));
  const fr = film.getBoundingClientRect();
  if (fr.bottom > 0 && !reduced) film.style.setProperty('--tilt', clamp((fr.top - vh * .22) / (vh * .6)).toFixed(3));
  const sr = story.getBoundingClientRect();
  setStep(clamp(Math.floor(-sr.top / (sr.height - vh) * 8), 0, 7));
}
addEventListener('scroll', onScroll, { passive: true }); addEventListener('resize', onScroll);
steps.forEach((li, i) => li.onclick = () => { const top = story.getBoundingClientRect().top + scrollY; scrollTo({ top: top + (story.offsetHeight - innerHeight) * (i + .5) / 8 }); });
new ResizeObserver(() => canvas.style.setProperty('--s', canvas.clientHeight / 1080)).observe(canvas);
onScroll();

// typing in the mock's search field, in step with the cursor loop
{ const typed = $('#typed'), box = typed.parentElement, TXT = 'deploy production', cur = $('.stage .cursor');
  let seen = false; new IntersectionObserver(es => seen = es[0].isIntersecting).observe(stage);
  (function loop() {
    requestAnimationFrame(loop); if (!seen) return;
    const a = cur.getAnimations()[0]; if (!a) return;
    const p = (a.currentTime % 9000) / 9000, n = p > .9 ? 0 : Math.floor(clamp((p - .24) / .2) * TXT.length);
    if (typed.textContent.length != n) typed.textContent = TXT.slice(0, n);
    box.classList.toggle('focus', p > .21 && p < .9);
  })(); }

// ───────── hero: drag to take a "screenshot" of the page ─────────
if (matchMedia('(hover:hover) and (pointer:fine)').matches) {
  const hero = $('#hero'), coords = $('#coords'), flash = $('#flash');
  let s = null, box = null, card = null, timer;
  const pos = e => { const r = hero.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  hero.addEventListener('pointermove', e => {
    const p = pos(e), ui = e.target.closest('a,button,.film');
    coords.classList.toggle('on', !ui); coords.textContent = `${Math.round(p.x)}, ${Math.round(p.y)}`;
    coords.style.transform = `translate(${e.clientX + 14}px,${e.clientY + 16}px)`;
    if (!s) return;
    const x = Math.min(s.x, p.x), y = Math.min(s.y, p.y), w = Math.abs(p.x - s.x), h = Math.abs(p.y - s.y);
    if (!box && w + h > 10) { box = hero.appendChild(Object.assign(document.createElement('div'), { className: 'sel-live', innerHTML: '<b></b>' })); getSelection().removeAllRanges(); }
    if (box) { Object.assign(box.style, { left: x + 'px', top: y + 'px', width: w + 'px', height: h + 'px' }); box.firstChild.textContent = `${Math.round(w)} × ${Math.round(h)}`; s.r = { x, y, w, h }; }
  });
  hero.addEventListener('pointerleave', () => coords.classList.remove('on'));
  hero.addEventListener('pointerdown', e => { if (e.button || e.target.closest('a,button,.film')) return; s = pos(e); hero.setPointerCapture(e.pointerId); e.preventDefault(); });
  hero.addEventListener('pointerup', () => {
    const r = s && s.r; s = null; if (box) { box.remove(); box = null; }
    if (!r || r.w < 30 || r.h < 30) return;
    flash.animate([{ opacity: .85 }, { opacity: 0 }], { duration: 500, easing: 'ease-out' });
    const W = 276, sc = W / r.w, clone = hero.cloneNode(true);
    clone.removeAttribute('id'); clone.classList.add('static'); $$('[id]', clone).forEach(n => n.removeAttribute('id'));
    const v = $('video', clone), c = document.createElement('canvas'); c.width = 800; c.height = 450; c.style.cssText = 'width:100%;height:100%';
    try { c.getContext('2d').drawImage(promo, 0, 0, 800, 450); } catch {} v.replaceWith(c);
    clone.style.cssText = `position:absolute;left:0;top:0;width:${hero.offsetWidth}px;height:${hero.offsetHeight}px;transform-origin:0 0;transform:scale(${sc}) translate(${-r.x}px,${-r.y}px);pointer-events:none`;
    card?.remove(); clearTimeout(timer);
    card = document.body.appendChild(Object.assign(document.createElement('div'), { className: 'qa-pop' }));
    const vi = document.documentElement.lang == 'vi';
    card.innerHTML = `<div class="th" style="height:${Math.min(r.h * sc, 230)}px"></div><p><b>${Math.round(r.w)} × ${Math.round(r.h)}</b> — ${vi ? 'nhanh như vậy đó. Trong ứng dụng thật: ' : "that's how fast it is. In the real app: "}<b>⌥⇧⌘4</b></p><button aria-label="Close">×</button>`;
    card.firstChild.append(clone);
    const close = () => { const k = card; k.classList.add('out'); setTimeout(() => k.remove(), 400); };
    $('button', card).onclick = close; timer = setTimeout(close, 8000);
  });
}
