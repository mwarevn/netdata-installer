# Netdata Homelab Monitoring — Context toàn bộ dự án

> Cập nhật: 2026-07-10 · Tool hiện tại: `netdata-setup.sh` **v1.12** (~1650 dòng bash)

---

## 1. Mục tiêu

Giám sát chi tiết nhiều Ubuntu server trong homelab từ **1 dashboard duy nhất**:

- Network per-NIC, các loại IP (public / private / tailscale) + báo khi IP public đổi
- Nhiệt độ linh kiện (CPU, NVMe, GPU), sức khỏe ổ cứng (S.M.A.R.T.)
- Docker containers: tên + trạng thái + tài nguyên
- Systemd services (active/failed), uptime, kiểm tra kết nối internet từng node
- Alert qua Telegram (dùng chung bot với `srvctl`)

Trước đây dùng node_exporter + Prometheus + Grafana nhưng thiếu nhiệt độ và internet check.
**Đã chọn**: Netdata parent–child (1 agent/node cover toàn bộ, ~150–250MB RAM + 1–2% CPU/node,
100% local, không cần Netdata Cloud).

---

## 2. Hạ tầng

| Node | Máy | Vị trí | Vai trò | Ghi chú |
|---|---|---|---|---|
| **nitro** | Acer Nitro 5 (i5-11300H, 8GB RAM, GTX/iGPU, NVMe 477G) | Nhà (Viettel, CGNAT) | **PARENT** | Chạy 24/7, an toàn sau CGNAT |
| **centre** | ThinkCentre M75q Gen 2 (AMD Ryzen) | Phòng trọ | CHILD | GPU AMD → nhiệt qua amdgpu hwmon |
| **VPS** | Cloud VPS | Public internet | CHILD | Chạy Caddy reverse proxy, bắt buộc khóa UI 127.0.0.1 |

- Mesh: **Tailscale** (streaming đi trong WireGuard, không cần SSL riêng của Netdata)
- Domain: `xserver.io.vn` (Cloudflare) · DNS filtering: AdGuard Home (DoT `dns.xserver.io.vn`)
- Alert: Telegram bot (chat group `-100...`), dùng chung với toolkit `srvctl`

---

## 3. Kiến trúc Netdata parent–child

```
centre (phòng trọ) ──┐
                     ├── stream qua Tailscale ──►  nitro (PARENT)
VPS ─────────────────┘                             ├─ lưu toàn bộ data (dbengine)
                                                   ├─ health engine → Telegram
                                                   └─ UI: http://<ts-ip-nitro>:19999
```

Nguyên tắc đã chốt:

- **Child tắt health cục bộ** (`[health] enabled = no`) — parent chạy alert trên data stream, tránh thông báo đúp. Child rớt mạng thì parent tự phát hiện chart ngừng cập nhật → vẫn có alert.
- **Child khóa Web UI** về `127.0.0.1` (bắt buộc trên VPS public).
- **API key** = UUID, chỉ là mã ghép cặp (traffic đã được Tailscale mã hóa).
- **Ping internet chạy trên từng node** — mạng nhà chết không có nghĩa phòng trọ chết.
- **IP là inventory, không phải metric** → script cron 5'/lần, chỉ nhắn Telegram khi IP public ĐỔI.
- Parent + child đồng thời trên 1 máy là hợp lệ (proxy mode) — tool cho phép có chủ đích.

---

## 4. Tool `netdata-setup.sh` v1.12

Bash tool tương tác, tiếng Việt, chạy `sudo bash netdata-setup.sh`. Yêu cầu: Ubuntu/Debian, bash 4+, root, tty.

### Menu chính
```
[1] Setup PARENT     [2] Setup CHILD     [3] Trạng thái
[4] Gỡ / khôi phục   [5] Telegram alert  [0] Thoát
```

### Luồng chuẩn deploy 3 node
1. `scp netdata-setup.sh nitro:~/` → `sudo bash netdata-setup.sh` → chọn **1** (PARENT)
2. Cuối màn hình tool in chuỗi ghép **`NDPAIR:<tailscale-ip>:<api-key>`** → copy
3. Trên centre + VPS: chọn **2** (CHILD) → **dán chuỗi NDPAIR** vào câu hỏi đầu tiên → xong
4. Quên copy? Menu **3** trên parent in lại chuỗi bất cứ lúc nào (lưu tại `/etc/netdata/.ndpair`, chmod 600)

### Quét phần cứng tự động (hw_scan)
Chạy đầu mỗi flow, menu tính năng build **động** theo máy:

| Detect | Cách detect | Hành động |
|---|---|---|
| NVIDIA GPU | `nvidia-smi` hoặc PCI vendor `0x10de` | Bật collector `nvidia_smi`; chưa driver → hỏi cài `ubuntu-drivers install` (nhắc reboot) |
| Intel iGPU | PCI class `0x03*` vendor `0x8086` | Cài intel-gpu-tools + bật `intelgpu` |
| AMD GPU | vendor `0x1002` | Note vào mục lm-sensors (amdgpu hwmon cover) |
| Disk vật lý | `lsblk` (phân loại NVMe/SSD/HDD, lọc loop/zram) | Mục S.M.A.R.T. (smartmontools + module `smartctl`); máy ảo → khóa kèm lý do |
| Máy ảo | `systemd-detect-virt` | Default tắt lm-sensors, khóa SMART |
| IPMI/BMC | `/sys/class/ipmi` | Mục freeipmi (chỉ hiện khi có) |
| UPS | `upsd`/nut-server đang chạy | Mục collector `upsd` (chỉ hiện khi có) |
| Pin laptop / WiFi / RAPL | sysfs | Chỉ báo — Netdata tự có chart sẵn |

### Tính năng bật/tắt trong menu (checkbox, redraw tại chỗ)
lm-sensors (sensors-detect --auto) · NVIDIA · Intel iGPU · S.M.A.R.T. · Docker
(thiếu → hỏi cài qua get.docker.com, usermod netdata vào group docker) · ping internet
(1.1.1.1 + 8.8.8.8) · systemd services (`*.service`) · Telegram alert (validate token
qua getMe, test 3 tin WARNING/CRITICAL/CLEAR) · alert nhiệt độ (hỏi ngưỡng warn/crit
default 80/90, auto-detect context chart sau restart) · bind IP · UFW allow tailscale0
→ 19999 · IP-watch (cron 5', `/usr/local/bin/ip-watch.sh` chmod 700 vì chứa token)

### Cơ chế an toàn (đã test tự động)
- **Backup**: mọi file bị sửa → `/etc/netdata/setup-backups/<timestamp>/`, giữ **bản gốc lần đầu**
- **Idempotent**: `ini_set` (awk sửa đúng key trong đúng section, không nhân đôi, không đụng comment), `managed_block` (marker replace), `enable_god_module` — chạy lại N lần config vẫn sạch
- **Role guard**: đọc stream.conf → biết máy đang là parent/child/both/none, chặn setup chồng chéo vô thức (đặc biệt: setup CHILD trên máy đang PARENT = cảnh báo NHẦM MÁY, default n)
- **Validate**: child không được trỏ về chính nó (so 127.x + hostname + mọi IP interface), API key phải UUID 8-4-4-4-12, chat ID phải là số, ngưỡng CRIT > WARN, pre-flight TCP tới parent trước khi ghi config
- **Gỡ sạch = pipeline 5 bước tự động** (1 lần confirm): stop service → kickstart --uninstall (fallback apt purge) → gỡ bản static /opt/netdata → `docker rm -f` container netdata (kể cả host-network, detect qua cgroup) + pkill mồ côi → quét tàn dư mọi nơi (etc/var/usr dirs, cron, logrotate, systemd units, apt repo/keyring, dpkg rc-packages, user/group) → verify port 19999
- **Snapshot trước khi gỡ**: toàn bộ /etc/netdata → `/var/backups/netdata-etc-<ts>` (uninstaller chính thức xóa cả setup-backups!); cài lại tool tự offer khôi phục; có tùy chọn xóa sạch mọi backup
- UI: clear screen + breadcrumb (`Menu chính › Setup PARENT › Chọn tính năng`) khi chuyển màn hình; các bước apply cuộn bình thường để giữ log

---

## 5. Lịch sử version & bug đã fix

| Ver | Nội dung |
|---|---|
| 1.0 | Tool gốc: menu parent/child/status/gỡ, toggle tính năng, backup + idempotent. 18 test hàm thuần |
| 1.1 | `hw_scan` — quét phần cứng, menu build động (NVIDIA/iGPU/AMD/SMART/IPMI/UPS/pin/WiFi/RAPL) |
| 1.2 | Chuỗi ghép **NDPAIR** parent→child · menu gỡ 3 mức + restore từ backup **cũ nhất** |
| 1.3 | **Role guard** chống setup chồng chéo · validate self-IP/UUID/chat-ID/ngưỡng nhiệt |
| 1.4 | Audit đa góc độ: fix token world-readable (755→**700**) · guard curl · menu 5 Telegram độc lập |
| 1.5 | **3 bug từ chạy thật trên nitro** (xem mục 6): os-release đè $VERSION · VIRT "none\nnone" · curl (23) |
| 1.6 | UI mới: clear screen, breadcrumb, feat_menu redraw tại chỗ |
| 1.7 | Phát hiện từ log gỡ thật: uninstaller xóa cả setup-backups → **snapshot /etc/netdata ra /var/backups trước khi gỡ** + offer khôi phục khi cài lại |
| 1.8 | Tùy chọn xóa sạch backup khi gỡ + menu "Dọn backup/snapshot" riêng |
| 1.9 | `diagnose_port19999`: gỡ rồi mà :19999 vẫn sống → chỉ mặt docker-proxy / static / mồ côi |
| 1.10 | Nhận diện + gỡ bản static /opt/netdata, offer pkill mồ côi |
| 1.11 | Gỡ sạch **không hỏi vặt**: 5 bước tự động + `purge_netdata_residuals` quét mọi nơi |
| 1.12 | Bắt ca **netdata trong Docker host-network** (detect qua cgroup — pkill vô dụng vì restart policy) → tự `docker rm -f` container netdata trong gỡ sạch |

Kiểm định mỗi bản: `bash -n` + `shellcheck -S warning` sạch + bộ test tự động
(18 test hàm thuần + test theo tính năng, chạy bằng `source` + mock, tổng ~60 case).

## 6. Bài học kỹ thuật (gotchas đã dính thật)

1. **`source /etc/os-release` đè biến của script** — file này set `VERSION`, `NAME`, `ID`...
   Menu từng hiện "NETDATA SETUP v26.04 LTS (Resolute Raccoon)". Fix: đọc trong subshell
   `eval "$(. /etc/os-release; printf 'OS_ID=%q ...' ...)"` + đổi tên biến `TOOL_VERSION`.
2. **`systemd-detect-virt` in `none` nhưng exit code 1** trên máy thật → `$(cmd || echo none)`
   chạy cả 2 vế → `"none\nnone"` → mọi so sánh `!= none` đúng → nitro bị coi là VM
   (sensors tắt, SMART khóa oan). Fix: gán trước, rỗng mới default.
3. **curl exit 23 (write error)** khi tải về `/tmp` — tmpfs nằm trên RAM, máy 8GB dễ đầy.
   Fix: mọi file tải về chuyển `/var/tmp` (trên disk) + download() fallback wget + dọn file rác.
4. **`kickstart --uninstall` xóa TOÀN BỘ `/etc/netdata`** — kể cả thư mục backup của tool
   bên trong. Phải snapshot ra ngoài (`/var/backups`) TRƯỚC khi gọi uninstaller.
5. **Netdata container `network_mode: host`** không có docker-proxy trên port, process hiện
   là `netdata` y như bản cài native; `pkill` bị restart policy hồi sinh ngay. Nhận diện
   duy nhất: đọc `/proc/<pid>/cgroup` thấy `docker-<id>`. Xử: `docker rm -f`.
6. **Dashboard Netdata là SPA + service worker** — server chết rồi tab cũ vẫn render UI từ
   cache. Kiểm tra thật: tab ẩn danh, hoặc `curl 127.0.0.1:19999/api/v1/info` ngay trên máy.
7. **Pipeline bash tạo subshell** — `printf | ham_doi_bien` nuốt thay đổi biến; test phải dùng
   `ham < <(printf ...)`. Tương tự `hw_scan | head` từng làm mất flag HW_SCANNED.
8. `sensors-detect --auto` là lý do node_exporter trước đây trống nhiệt độ (thiếu kernel module).
9. Nhãn tiếng Việt có dấu làm lệch cột `printf %-Ns` (đếm byte, không đếm ký tự hiển thị).
10. `alarm-notify.sh` source config trực tiếp mỗi lần chạy → đổi Telegram token **không cần
    restart netdata**, test được ngay.

## 7. Trạng thái hiện tại & việc tiếp theo

**Hiện tại (2026-07-10):**
- nitro đã gỡ sạch Netdata (xác nhận: `pgrep -x netdata` rỗng, không container netdata).
  "Dashboard vẫn vào được" = browser cache (SPA) hoặc đang mở IP máy khác.
- Telegram bot đã verify hoạt động (3 tin test bắn OK tới group `-100...`).
- Tool v1.12 sẵn sàng deploy chuẩn từ nền trắng.

**Việc tiếp theo:**
1. nitro: `sudo bash netdata-setup.sh` → menu 1 (PARENT) → copy chuỗi NDPAIR
2. centre + VPS: menu 2 (CHILD) → dán NDPAIR
3. Nghiệm thu: dashboard parent đủ 3 node · sensors có nhiệt độ · Docker hiện đúng tên
   container · test alert (`docker stop` 1 container không quan trọng trên centre)
4. (Tùy chọn, chưa làm) Chế độ non-interactive `--child "NDPAIR:..." --defaults` cho node
   mới sau này · chỉnh retention dbengine nếu muốn giữ metric 3–6 tháng

## 8. Cheatsheet

```bash
# Deploy
scp netdata-setup.sh <node>:~/ && ssh <node> sudo bash netdata-setup.sh

# Ai đang giữ port 19999?
sudo ss -tlnp | grep 19999
# Process trong container? (host thấy docker-<id>, trong container chỉ thấy 0::/)
cat /proc/<pid>/cgroup | head -3

# Netdata còn sống thật không (bypass browser cache)
curl -s --max-time 3 http://127.0.0.1:19999/api/v1/info | head -3

# Streaming child → parent có nối không
journalctl -u netdata -n 200 | grep -iE 'stream|sender'
# Node nào đang stream về parent
curl -s localhost:19999/api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]'

# Test Telegram tay (không cần chờ sự cố)
sudo su -s /bin/bash netdata -c '/usr/libexec/netdata/plugins.d/alarm-notify.sh test'

# Dò context chart nhiệt độ (viết health rule)
curl -s localhost:19999/api/v1/charts | grep -o '"context":"[^"]*temp[^"]*"' | sort -u

# Vị trí quan trọng
/etc/netdata/stream.conf                  # cấu hình parent/child
/etc/netdata/.ndpair                      # chuỗi ghép (chỉ trên parent)
/etc/netdata/setup-backups/<ts>/          # backup config gốc
/var/backups/netdata-etc-<ts>/            # snapshot trước khi gỡ
/usr/local/bin/ip-watch.sh                # IP-watch (chmod 700)
/etc/cron.d/ip-watch
```
