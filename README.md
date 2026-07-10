# Netdata Installer

Công cụ tự động cài đặt và cấu hình **Netdata** với kiến trúc **Parent-Child**, hỗ trợ giám sát toàn diện: CPU, RAM, disk, network, Docker containers, GPU, nhiệt độ, systemd services, v.v.

## Cài đặt nhanh (1 lệnh)

### Bằng curl

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/mwarevn/netdata-installer/main/run.sh)"
```

### Bằng wget

```bash
wget -qO- https://raw.githubusercontent.com/mwarevn/netdata-installer/main/run.sh | sudo bash
```

> **Yêu cầu:** Ubuntu 20.04+ / Debian 11+, kết nối internet, quyền `sudo`.

## Menu chính

```
[1]  Setup PARENT      — máy trung tâm, dashboard tổng, alert Telegram
[2]  Setup CHILD       — node stream dữ liệu về parent
[3]  Trạng thái        — service · streaming · sensors · IP (in cả NDPAIR)
[4]  Gỡ / khôi phục    — gỡ sạch Netdata hoặc chỉ gỡ config tool tạo
[5]  Telegram alert    — test · cấu hình lần đầu · đổi bot
[0]  Thoát
```

## Tính năng

| Tính năng | Mô tả | Bật/tắt |
|---|---|---|
| Nhiệt độ CPU/NVMe (lm-sensors) | Quét sensor chip, load kernel module | menu |
| NVIDIA GPU | Nhiệt độ, VRAM, power draw, utilization | menu |
| Intel iGPU | Engine busy %, frequency, power | menu |
| S.M.A.R.T. | Sức khỏe ổ cứng: reallocated sectors, % hao mòn | menu |
| IPMI/BMC | Sensor từ BMC (máy chủ) | menu |
| UPS (NUT/upsd) | Battery charge, load, runtime | menu |
| Docker containers | CPU, RAM, network, disk từng container | menu |
| eBPF | Per-process CPU, disk I/O, network, memory | menu |
| Network viewer | Socket connections per process (listen/connect) | menu |
| Ping internet | Latency + packet loss ra 1.1.1.1 / 8.8.8.8 | menu |
| Systemd services | Trạng thái active / failed / inactive | menu |
| Port check | Giám sát port 80/443/DNS availability | menu |
| Cảnh báo Telegram | ~300 alert mặc định + alert nhiệt độ tùy chỉnh | menu |
| IP-watch | Báo Telegram khi IP public thay đổi | menu |
| UFW | Mở port 19999 trên tailscale0 | menu |
| Bind IP | Khóa Web UI về 127.0.0.1 hoặc Tailscale | menu |

## Kiến trúc Parent-Child

```
                  ┌──────────────┐
                  │   PARENT     │ ← dashboard tổng + alert Telegram
                  │  (nitro)     │
                  └──────┬───────┘
                         │ Tailscale (WireGuard)
            ┌────────────┼────────────┐
            ▼            ▼            ▼
       ┌────────┐  ┌────────┐  ┌────────┐
       │ CHILD  │  │ CHILD  │  │ CHILD  │
       │(centre)│  │ (VPS)  │  │  ...   │
       └────────┘  └────────┘  └────────┘
```

1. **Setup PARENT** trên máy trung tâm → tool in chuỗi `NDPAIR:<ip>:<key>`
2. **Copy chuỗi đó** → setup CHILD trên từng node → dán vào câu hỏi đầu tiên
3. Mở dashboard PARENT để xem toàn bộ node tập trung

## An toàn

- **Backup tự động:** mọi file config bị sửa đều backup vào `/etc/netdata/setup-backups/<timestamp>/`
- **Idempotent:** chạy lại nhiều lần không nhân đôi config, không hỏng cấu hình cũ
- **Chạy lại → cập nhật:** thay đổi tính năng, đổi bot token, thêm tính năng mới

## Gỡ cài đặt

Chọn menu `4) Gỡ / khôi phục` → `[1] Gỡ SẠCH Netdata`:

- Dừng + disable service
- Kickstart --uninstall (bản native)
- Xóa bản static (`/opt/netdata`)
- Dọn container Netdata (nếu chạy Docker)
- Quét tàn dư: user, group, apt repo, logrotate, cron
- Snapshot config trước khi gỡ — khôi phục được sau

Hoặc chỉ gỡ config tool tạo: menu `4` → `[2]` — giữ Netdata, khôi phục config gốc từ backup.
