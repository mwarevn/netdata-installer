#!/usr/bin/env bash
#===============================================================================
#  netdata-setup.sh — Tool cài & cấu hình Netdata PARENT/CHILD tự động
#
#  Cách dùng :  sudo bash netdata-setup.sh
#
#  Menu:
#    1) Setup PARENT — máy trung tâm: nhận stream, dashboard, alert Telegram
#    2) Setup CHILD  — node stream về parent, khóa UI, tắt alert cục bộ
#    3) Trạng thái   — kiểm tra service, streaming, sensors, IP...
#    4) Gỡ / khôi phục — gỡ sạch Netdata, hoặc chỉ gỡ config tool tạo
#
#  Ghép parent-child: cuối bước setup PARENT tool in chuỗi NDPAIR:<ip>:<key>
#  — copy lại, khi setup CHILD dán vào câu hỏi đầu tiên là xong.
#
#  Tự quét phần cứng (hw_scan) rồi build menu tính năng theo máy:
#    GPU NVIDIA (tự hỏi cài driver nếu thiếu) · Intel iGPU · AMD (hwmon) ·
#    S.M.A.R.T. ổ cứng · IPMI/BMC · UPS (NUT) · pin laptop · WiFi · RAPL
#  Tính năng bật/tắt được trong menu (nhập số để đảo, Enter để áp dụng):
#    lm-sensors (nhiệt độ) · Docker (tự cài nếu thiếu) · ping internet ·
#    systemd services · Telegram alert · alert nhiệt độ · bind IP ·
#    UFW tailscale0 · IP-watch (báo khi IP public đổi)
#
#  An toàn:
#    - Mọi file config bị sửa đều được backup vào
#      /etc/netdata/setup-backups/<timestamp>/ trước khi ghi
#    - Chạy lại nhiều lần không sao (idempotent): sửa đúng key, không nhân đôi
#===============================================================================
set -uo pipefail

TOOL_VERSION="1.12"
STAMP="$(date +%Y%m%d-%H%M%S)"
NDDIR="/etc/netdata"
BACKUP_DIR="$NDDIR/setup-backups/$STAMP"
KICKSTART_URL="https://get.netdata.cloud/kickstart.sh"

#--------------------------------- màu & in ----------------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; C=""; B=""; N=""
fi

# ---- màn hình & breadcrumb ----
UI_W=54
CRUMBS=()

cls() { # chỉ clear khi stdout là tty (test/pipe thì thôi)
  [ -t 1 ] || return 0
  command clear 2>/dev/null || printf '\033[2J\033[H'
}

crumb_push() { CRUMBS+=("$1"); }
crumb_pop()  { [ ${#CRUMBS[@]} -gt 0 ] && unset "CRUMBS[$((${#CRUMBS[@]}-1))]"; }
crumb_str()  {
  local out="" c
  for c in "${CRUMBS[@]}"; do out="${out:+$out › }$c"; done
  printf '%s' "$out"
}

ui_header() { # clear + banner + breadcrumb — gọi khi CHUYỂN màn hình
  cls
  local bar virt_lbl
  bar="$(printf '═%.0s' $(seq 1 "$UI_W"))"
  virt_lbl="máy thật"
  [ "$VIRT" != "none" ] && virt_lbl="VM: $VIRT"
  printf '%s\n' "${B}${bar}${N}"
  printf '%s\n' " ${B}NETDATA SETUP v${TOOL_VERSION}${N} · $(hostname) · ${OS_NAME} · ${virt_lbl}"
  printf '%s\n' " ${C}$(crumb_str)${N}"
  printf '%s\n' "${B}${bar}${N}"
}

pause_return() { echo; read -rp "   ↩  Enter để về menu..." _; }

run_screen() { # $1=tên breadcrumb  $2=hàm — quản lý header/crumb/pause tập trung
  crumb_push "$1"
  ui_header
  "$2"
  crumb_pop
  pause_return
}

say()   { printf '%s\n' "${C}▸${N} $*"; }
ok()    { printf '%s\n' "${G}✔${N} $*"; }
warn()  { printf '%s\n' "${Y}⚠${N} $*"; }
err()   { printf '%s\n' "${R}✘${N} $*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '%s\n' "──────────────────────────────────────────────────"; }
title() { printf '\n%s── %s ──────────%s\n' "${C}${B}" "$*" "${N}"; }

# Hỏi Yes/No — chấp nhận y/n/co/khong, có default
ask_yn() { # $1=câu hỏi  $2=default(y|n)
  local p="$1" d="${2:-y}" a
  while true; do
    if [ "$d" = "y" ]; then
      read -rp "$p [Y/n]: " a; a="${a:-y}"
    else
      read -rp "$p [y/N]: " a; a="${a:-n}"
    fi
    case "${a,,}" in
      y|yes|c|co|có)        return 0 ;;
      n|no|k|khong|không)   return 1 ;;
      *) echo "   → gõ y hoặc n" >&2 ;;
    esac
  done
}

# Hỏi input — read -p in prompt ra stderr nên capture bằng $() vẫn sạch
ask_input() { # $1=câu hỏi  $2=default(tùy chọn)  $3=allow_empty(yes|no)
  local p="$1" d="${2:-}" ae="${3:-no}" a
  while true; do
    if [ -n "$d" ]; then
      read -rp "$p [$d]: " a; a="${a:-$d}"
    else
      read -rp "$p: " a
    fi
    if [ -n "$a" ] || [ "$ae" = "yes" ]; then
      printf '%s' "$a"; return 0
    fi
    echo "   → không được để trống" >&2
  done
}

#------------------------------ sửa file an toàn ------------------------------
# Backup 1 lần/lần chạy: lần backup ĐẦU TIÊN của file là bản gốc, không ghi đè
backup_file() {
  local f="$1" dest
  [ -f "$f" ] || return 0
  mkdir -p "$BACKUP_DIR"
  dest="$BACKUP_DIR/$(printf '%s' "${f#/}" | tr '/' '_')"
  [ -e "$dest" ] || cp -a "$f" "$dest"
}

# ini_set file section key value
# Sửa/thêm đúng 1 key trong 1 section kiểu netdata.conf / stream.conf,
# giữ nguyên phần còn lại. Chạy lại → chỉ cập nhật giá trị, không nhân đôi.
ini_set() {
  local file="$1" sec="$2" key="$3" val="$4" tmp
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  backup_file "$file"
  tmp="$(mktemp)"
  awk -v sec="$sec" -v key="$key" -v val="$val" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { ins=0; done=0; found=0 }
    {
      raw=$0; line=trim(raw)
      # Gặp section header mới
      if (line ~ /^\[.*\]$/) {
        if (ins && !done) { print "    " key " = " val; done=1 }
        ins = (line == "[" sec "]")
        if (ins) found=1
        print raw; next
      }
      # Đang trong section đích: thay key nếu trùng (bỏ qua dòng comment)
      if (ins && !done && line !~ /^#/) {
        eq = index(line, "=")
        if (eq > 0) {
          k = trim(substr(line, 1, eq-1))
          if (k == key) { print "    " key " = " val; done=1; next }
        }
      }
      print raw
    }
    END {
      if (ins && !done)  { print "    " key " = " val }
      if (!found)        { print "[" sec "]"; print "    " key " = " val }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# ini_get file section key → in value đã trim (rỗng nếu không có)
ini_get() {
  awk -v sec="$2" -v key="$3" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      line=trim($0)
      if (line ~ /^\[.*\]$/) { ins=(line=="[" sec "]"); next }
      if (ins && line !~ /^#/) {
        eq=index(line,"=")
        if (eq>0 && trim(substr(line,1,eq-1))==key) { print trim(substr(line,eq+1)); exit }
      }
    }' "$1" 2>/dev/null
}

# managed_block file marker content
# Ghi 1 khối có đánh dấu — chạy lại sẽ thay khối cũ, không append chồng
managed_block() {
  local file="$1" marker="$2" content="$3"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"
  backup_file "$file"
  sed -i "/^# >>> $marker >>>/,/^# <<< $marker <<</d" "$file"
  {
    printf '# >>> %s >>>\n' "$marker"
    printf '%s\n' "$content"
    printf '# <<< %s <<<\n' "$marker"
  } >> "$file"
}

#------------------------------ detect hệ thống ------------------------------
OS_ID="unknown"; OS_LIKE=""; OS_NAME="unknown"
detect_os() {
  # Đọc os-release trong SUBSHELL — file này set VERSION/NAME/ID... sẽ
  # ghi đè biến của tool nếu source thẳng (bug từng dính: VERSION bị thay
  # bằng "26.04 LTS (Resolute Raccoon)")
  [ -r /etc/os-release ] || return 0
  eval "$(
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null
    printf 'OS_ID=%q OS_LIKE=%q OS_NAME=%q\n' \
      "${ID:-unknown}" "${ID_LIKE:-}" "${PRETTY_NAME:-unknown}"
  )"
}
is_debian_like() {
  case "$OS_ID" in ubuntu|debian) return 0 ;; esac
  [[ "$OS_LIKE" == *debian* ]]
}

# systemd-detect-virt in "none" nhưng EXIT 1 trên máy thật → không được
# dùng "|| echo none" (sẽ ra "none\nnone" và tool tưởng máy thật là VM)
VIRT="$(systemd-detect-virt 2>/dev/null)"
[ -n "$VIRT" ] || VIRT="none"

nvidia_state() { # in ra: driver | gpu | none
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo driver
  elif grep -qs 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null; then
    echo gpu
  else
    echo none
  fi
}

#------------------------------ quét phần cứng -------------------------------
# Detect 1 lần, lưu vào biến HW_* — menu tính năng dựa vào đây để tự bật/khóa
HW_CPU=""; HW_RAM=""; HW_DISKS=""; HW_PHYS_DISK=0
HW_GPU_INTEL=0; HW_GPU_AMD=0; HW_GPU_NVIDIA=""; HW_IPMI=0; HW_UPS=0; HW_WIFI=""
HW_SCANNED=0

hw_scan() { # gọi "hw_scan force" để quét & in lại
  [ "$HW_SCANNED" = 1 ] && [ "${1:-}" != "force" ] && return 0
  HW_SCANNED=1
  HW_GPU_INTEL=0; HW_GPU_AMD=0; HW_GPU_NVIDIA=""; HW_IPMI=0; HW_UPS=0; HW_PHYS_DISK=0
  title "QUÉT PHẦN CỨNG — $(hostname)"

  # CPU + RAM
  HW_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
  [ -n "$HW_CPU" ] || HW_CPU="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ */,"",$2); print $2; exit}')"
  HW_RAM="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
  printf '   %-10s %s (%s threads)\n' "CPU" "${HW_CPU:-?}" "$(nproc 2>/dev/null || echo '?')"
  printf '   %-10s %s\n' "RAM" "${HW_RAM:-?}"

  # GPU — duyệt PCI class 0x03xxxx (display controller)
  local d cls ven
  for d in /sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    read -r cls < "$d/class"
    case "$cls" in 0x03*) ;; *) continue ;; esac
    read -r ven < "$d/vendor" 2>/dev/null || continue
    case "$ven" in
      0x8086) HW_GPU_INTEL=1 ;;
      0x1002) HW_GPU_AMD=1 ;;
      0x10de) # NVIDIA — kiểm tra driver bằng cách thử chạy nvidia-smi
        if command -v nvidia-smi >/dev/null 2>&1; then
           HW_GPU_NVIDIA=driver
        else
           HW_GPU_NVIDIA=gpu
        fi
        ;;
    esac
  done
  case "${HW_GPU_NVIDIA:-none}" in
    driver) printf '   %-10s NVIDIA %s [driver OK]\n' "GPU" \
              "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" ;;
    gpu)    printf '   %-10s NVIDIA (PCI) — %sCHƯA có driver%s, tool có thể cài\n' "GPU" "$Y" "$N" ;;
    *)      case "$(nvidia_state)" in
               driver) printf '   %-10s NVIDIA %s [driver OK]\n' "GPU" \
                         "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" ;;
               gpu)    printf '   %-10s NVIDIA (PCI) — %sCHƯA có driver%s, tool có thể cài\n' "GPU" "$Y" "$N" ;;
            esac
            ;;
  esac
  [ "$HW_GPU_INTEL" = 1 ] && printf '   %-10s Intel iGPU — collector intelgpu khả dụng\n' "GPU"
  [ "$HW_GPU_AMD"  = 1 ] && printf '   %-10s AMD — nhiệt độ/power qua lm-sensors (amdgpu hwmon)\n' "GPU"

  # Disk vật lý (bỏ loop/zram/ram/cdrom) — phân loại NVMe / SSD / HDD
  HW_DISKS="$(lsblk -dno NAME,SIZE,ROTA,TYPE 2>/dev/null | awk '
    $4=="disk" && $1 !~ /^(loop|zram|ram|sr|fd)/ {
      kind = ($1 ~ /^nvme/) ? "NVMe" : ($3=="1" ? "HDD" : "SSD")
      printf "%s%s %s (%s)", sep, $1, $2, kind; sep=" · "
    }')"
  if [ -n "$HW_DISKS" ]; then
    printf '   %-10s %s\n' "Disk" "$HW_DISKS"
    [ "$VIRT" = "none" ] && HW_PHYS_DISK=1
  fi

  # Pin laptop → chart power_supply Netdata tự có
  if compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
    printf '   %-10s laptop — chart pin Netdata tự có\n' "Pin"
  fi

  # IPMI/BMC (server)
  if compgen -G "/sys/class/ipmi/*" >/dev/null 2>&1 || [ -e /dev/ipmi0 ]; then
    HW_IPMI=1
    printf '   %-10s có BMC — collector freeipmi khả dụng\n' "IPMI"
  fi

  # UPS qua NUT
  if systemctl is-active nut-server >/dev/null 2>&1 \
     || systemctl is-active upsd >/dev/null 2>&1 \
     || pgrep -x upsd >/dev/null 2>&1; then
    HW_UPS=1
    printf '   %-10s NUT (upsd) đang chạy — collector upsd khả dụng\n' "UPS"
  fi

  # WiFi interface → chart tín hiệu tự có
  local w ifaces=""
  for w in /sys/class/net/*/wireless; do
    [ -d "$w" ] && ifaces="$ifaces $(basename "$(dirname "$w")")"
  done
  HW_WIFI="${ifaces# }"
  [ -n "$HW_WIFI" ] && printf '   %-10s %s — chart tín hiệu tự có\n' "WiFi" "$HW_WIFI"

  [ -d /sys/class/powercap/intel-rapl ] \
    && printf '   %-10s Intel RAPL — điện năng CPU tự có\n' "Power"

  if [ "$VIRT" = "none" ]; then
    printf '   %-10s không (máy thật)\n' "Virt"
  else
    printf '   %-10s %s\n' "Virt" "$VIRT"
  fi
  if command -v docker >/dev/null 2>&1; then
    printf '   %-10s có (%s container đang chạy)\n' "Docker" "$(docker ps -q 2>/dev/null | wc -l)"
  else
    printf '   %-10s chưa cài\n' "Docker"
  fi
  local tsip
  tsip="$(tailscale ip -4 2>/dev/null | head -1)"
  printf '   %-10s %s\n' "Tailscale" "${tsip:-chưa có}"
}

APT_UPDATED=0
apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "Không có apt-get — tự cài thủ công gói: $*"
    return 1
  fi
  if [ "$APT_UPDATED" != 1 ]; then
    say "apt-get update..."
    apt-get update -qq
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

#------------------------------ netdata cơ bản -------------------------------
port19999_line() { ss -tlnp 2>/dev/null | grep ':19999 ' | head -1; }

_cgroup_container_id() { # parse container-id từ nội dung cgroup (stdin)
  grep -oE '(docker[-/]|containerd[-/]|cri-containerd[-/])[0-9a-f]{12,64}' 2>/dev/null \
    | head -1 | grep -oE '[0-9a-f]{12,64}$'
}
pid_in_container() { # $1=pid → in container-id nếu process thuộc docker/containerd
  _cgroup_container_id < "/proc/$1/cgroup" 2>/dev/null
}

diagnose_port19999() { # port sạch → im lặng; còn ai giữ → chỉ mặt + hướng xử lý
  local line
  line="$(port19999_line)"
  [ -n "$line" ] || return 0
  warn "Port 19999 VẪN có tiến trình đang listen:"
  printf '    %s\n' "$line"
  if printf '%s' "$line" | grep -q docker-proxy; then
    say "→ Là Netdata chạy trong ${B}DOCKER${N} — gỡ package native KHÔNG đụng tới container."
    if command -v docker >/dev/null 2>&1; then
      say "Container đang publish 19999:"
      docker ps --filter "publish=19999" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
      say "Tắt hẳn:  docker stop <tên> && docker rm <tên>  (hoặc gỡ khỏi compose stack)"
    fi
  elif printf '%s' "$line" | grep -q netdata; then
    local dpid cid
    dpid="$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    cid=""
    [ -n "$dpid" ] && cid="$(pid_in_container "$dpid" || true)"
    if [ -n "$cid" ]; then
      say "→ Netdata chạy TRONG ${B}DOCKER container (host network)${N} — kill process sẽ bị restart policy hồi sinh!"
      command -v docker >/dev/null 2>&1 \
        && docker ps -a --filter "id=$cid" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
      say "Xóa hẳn:  docker rm -f ${cid:0:12}   (nằm trong compose thì bỏ khỏi file kẻo up lại mọc ra)"
    else
      say "→ Còn tiến trình netdata: bản STATIC hoặc process mồ côi."
      [ -d /opt/netdata ] \
        && say "Thấy ${B}/opt/netdata${N} (bản static) — gỡ: /opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh --yes" \
        || say "Diệt process mồ côi:  pkill -x netdata"
    fi
  else
    say "→ Một tiến trình KHÁC đang chiếm 19999 (tên trong dòng trên) — xử lý trước khi cài Netdata."
  fi
  say "Lưu ý: dashboard là SPA — tab trình duyệt cũ vẫn hiện UI từ cache, hãy hard-refresh (Ctrl+Shift+R)."
}

netdata_installed() {
  command -v netdata >/dev/null 2>&1 && return 0
  [ -x /opt/netdata/usr/sbin/netdata ] && return 0   # bản static
  systemctl list-unit-files 2>/dev/null | grep -q '^netdata\.service'
}
netdata_version() { netdata -v 2>/dev/null | head -1; }

nd_api() { curl -s --max-time 3 "http://127.0.0.1:19999$1"; }

wait_api() {
  local i
  for i in $(seq 1 30); do
    if nd_api /api/v1/info | grep -q '"version"'; then return 0; fi
    sleep 1
  done
  return 1
}

download() { # $1=url $2=đích — thử curl, hỏng thì wget; dọn file rác nếu fail
  rm -f "$2" 2>/dev/null
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$1" -o "$2"; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1 && wget -qO "$2" "$1"; then
    return 0
  fi
  rm -f "$2" 2>/dev/null
  err "Tải thất bại: $1"
  say "Kiểm tra: mạng/DNS, và dung lượng đích:  df -h $(dirname "$2")"
  return 1
}

install_netdata() {
  if netdata_installed; then
    ok "Netdata đã cài: $(netdata_version)"
    return 0
  fi
  warn "Netdata chưa có trên máy này."
  if [ -n "$(port19999_line)" ]; then
    diagnose_port19999
    ask_yn "→ Port 19999 đang bận — vẫn cài tiếp? (netdata native sẽ không bind được)" n || return 1
  fi
  ask_yn "→ Cài Netdata ngay (kickstart chính thức, kênh stable, tắt telemetry)?" y \
    || { err "Không thể tiếp tục khi chưa có Netdata."; return 1; }
  say "Tải kickstart..."
  local ks=/var/tmp/netdata-kickstart.sh
  download "$KICKSTART_URL" "$ks" || return 1
  # Đảm bảo user/group netdata tồn tại trước khi cài
  if ! getent group netdata >/dev/null; then groupadd -r netdata; fi
  if ! getent passwd netdata >/dev/null; then useradd -r -g netdata -s /usr/sbin/nologin netdata; fi

  say "Đang cài (mất 1-3 phút)..."
  # Thử cài native, nếu lỗi thì thử lại với type 'any'
  if ! sh "$ks" --non-interactive --stable-channel --disable-telemetry; then
    warn "Cài native thất bại, thử lại với --install-type any..."
    sh "$ks" --non-interactive --stable-channel --disable-telemetry --install-type any \
      || { err "Cài Netdata thất bại."; return 1; }
  fi
  systemctl enable --now netdata >/dev/null 2>&1 || true
  netdata_installed || { err "Cài xong nhưng không thấy service netdata."; return 1; }
  ok "Đã cài Netdata: $(netdata_version)"
  local snap
  snap="$(latest_snapshot || true)"
  if [ -n "$snap" ]; then
    say "Thấy snapshot config từ lần gỡ trước: $snap"
    if ask_yn "→ Khôi phục config cũ luôn (stream, telegram, alert... về như trước)?" n; then
      cp -a "$snap/." "$NDDIR/" && systemctl restart netdata         && ok "Đã khôi phục config từ snapshot + restart."         || warn "Khôi phục lỗi — copy tay: cp -a $snap/. $NDDIR/"
    fi
  fi
}

#===============================================================================
#  CÁC TÍNH NĂNG (mỗi cái 1 hàm — bật/tắt qua menu)
#===============================================================================

#---- Nhiệt độ: lm-sensors + dò module kernel ---------------------------------
f_sensors() {
  title "Nhiệt độ (lm-sensors)"
  apt_install lm-sensors || { warn "Cài lm-sensors thất bại — bỏ qua."; return 1; }
  say "Dò sensor chip (sensors-detect)..."
  yes '' | sensors-detect >/dev/null 2>&1 || true
  systemctl restart systemd-modules-load.service 2>/dev/null || true
  if sensors 2>/dev/null | grep -q '°C'; then
    ok "Đọc được nhiệt độ:"
    sensors 2>/dev/null | grep '°C' | head -6 | sed 's/^/    /'
  else
    warn "Chưa đọc được nhiệt độ — máy ảo, hoặc cần reboot để load kernel module."
  fi
}

#---- NVIDIA GPU collector (go.d nvidia_smi) ----------------------------------
enable_god_module() { # bật 1 module trong /etc/netdata/go.d.conf, không phá phần khác
  local mod="$1" f="$NDDIR/go.d.conf"
  backup_file "$f"
  local esc_mod
  esc_mod="$(printf '%s' "$mod" | sed 's/[^^]/[&]/g; s/\^/\\^/g')"
  if [ ! -f "$f" ]; then
    printf 'enabled: yes\ndefault_run: yes\nmodules:\n  %s: yes\n' "$mod" > "$f"
  elif grep -Eq "^[#[:space:]]*${esc_mod}:" "$f"; then
    sed -i -E "s|^[#[:space:]]*(${esc_mod}:).*|  \1 yes|" "$f"
  elif grep -q '^modules:' "$f"; then
    sed -i "/^modules:/a\\  ${mod}: yes" "$f"
  else
    printf 'modules:\n  %s: yes\n' "$mod" >> "$f"
  fi
}

f_nvidia() {
  title "NVIDIA GPU collector"
  local st
  st="$(nvidia_state)"
  if [ "$st" = "gpu" ]; then
    warn "Thấy GPU NVIDIA qua PCI nhưng CHƯA có driver (không có nvidia-smi)."
    if [ "$OS_ID" = "ubuntu" ]; then
      if ask_yn "→ Cài driver NVIDIA bản khuyến nghị luôn (ubuntu-drivers)?" y; then
        apt_install ubuntu-drivers-common || return 1
        say "Đang cài driver (vài phút, log: /var/tmp/nvidia-driver.log)..."
        if ubuntu-drivers install > /var/tmp/nvidia-driver.log 2>&1; then
          ok "Đã cài driver — ${B}CẦN REBOOT${N} để load module nvidia."
          warn "Reboot xong chạy lại tool: mục NVIDIA sẽ tự nhận driver và bật collector."
        else
          err "Cài driver thất bại — xem: tail -30 /var/tmp/nvidia-driver.log"
        fi
      else
        warn "Bỏ qua — cài driver thủ công rồi chạy lại tool."
      fi
    else
      warn "HĐH không phải Ubuntu — cài driver NVIDIA thủ công rồi chạy lại tool."
    fi
    return 1
  fi
  if [ "$st" != "driver" ]; then
    warn "Không phát hiện GPU NVIDIA — bỏ qua."
    return 1
  fi
  enable_god_module nvidia_smi
  ok "Đã bật collector nvidia_smi: nhiệt độ GPU, VRAM, power draw, utilization."
}

#---- Docker: tự phát hiện, hỏi cài nếu thiếu ---------------------------------
f_docker() {
  title "Tích hợp Docker"
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker CHƯA được cài trên máy này ($OS_NAME)."
    if ask_yn "→ Cài Docker luôn? (script chính thức get.docker.com — tự nhận diện HĐH)" y; then
      say "Đang tải & cài Docker..."
      if download https://get.docker.com /var/tmp/get-docker.sh \
         && sh /var/tmp/get-docker.sh > /var/tmp/get-docker.log 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        ok "Đã cài: $(docker --version 2>/dev/null)"
      else
        err "Cài Docker thất bại — 10 dòng log cuối:"
        tail -10 /var/tmp/get-docker.log 2>/dev/null | sed 's/^/    /'
        return 1
      fi
    else
      warn "Bỏ qua tích hợp Docker."
      return 1
    fi
  else
    ok "Docker có sẵn: $(docker --version 2>/dev/null)"
  fi
  # Cho user netdata đọc docker.sock → thấy TÊN + TRẠNG THÁI container
  if id -nG netdata 2>/dev/null | grep -qw docker; then
    ok "User netdata đã ở trong group docker."
  else
    if ask_yn "→ Thêm user netdata vào group docker (để Netdata đọc được container)?" y; then
      if usermod -aG docker netdata 2>/dev/null; then
        ok "Đã thêm user netdata vào group docker (áp dụng sau khi restart netdata)."
      else
        warn "Không thêm được netdata vào group docker — kiểm tra quyền root."
      fi
    fi
  fi
  # Cấu hình cgroups plugin để thấy Docker containers rõ ràng trên dashboard
  local cgf="$NDDIR/netdata.conf"
  backup_file "$cgf"
  ini_set "$cgf" "plugin:cgroups" "check for new cgroups every" "5"
  ini_set "$cgf" "plugin:cgroups" "enable new cgroups detected at runtime" "yes"
  ini_set "$cgf" "plugin:cgroups" "enable cgroups-detailed" "yes"
  ini_set "$cgf" "plugin:cgroups" "enable by default" "docker"
  ok "Cgroups plugin: sẽ monitor toàn bộ Docker containers (CPU, mem, net, disk)."
}

#---- Ping internet: node tự biết đường ra ngoài của chính nó -----------------
f_ping() {
  title "Giám sát internet (ping)"
  local f="$NDDIR/go.d/ping.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Sinh bởi netdata-setup.sh — ping ra internet: latency + packet loss của node này
jobs:
  - name: internet
    hosts:
      - 1.1.1.1
      - 8.8.8.8
EOF
  ok "Ping 1.1.1.1 + 8.8.8.8 mỗi giây — mất mạng là biết ngay node nào chết đường ra."
}

#---- Systemd services: trạng thái toàn bộ *.service --------------------------
f_systemd() {
  title "Giám sát systemd services"
  enable_god_module systemdunits
  local f="$NDDIR/go.d/systemdunits.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Sinh bởi netdata-setup.sh — theo dõi trạng thái toàn bộ service units
jobs:
  - name: services
    include:
      - '*.service'
EOF
  ok "Theo dõi mọi *.service: active / failed / inactive — service chết là thấy."
}

#---- eBPF: per-process CPU, disk, network, memory ----------------------------
f_ebpf() {
  title "eBPF (per-process CPU/disk/network/memory)"
  local plugdir
  for plugdir in /usr/libexec/netdata/plugins.d /usr/lib/netdata/plugins.d; do
    [ -f "$plugdir/ebpf.plugin" ] && break
    plugdir=""
  done
  if [ -z "$plugdir" ]; then
    warn "eBPF plugin không tìm thấy trong gói Netdata — thử cài gói bổ sung..."
    apt_install netdata-plugin-ebpf 2>/dev/null || { warn "Không có gói netdata-plugin-ebpf riêng — plugin có sẵn trong bản cài default."; }
  fi
  local f="$NDDIR/netdata.conf"
  backup_file "$f"
  ini_set "$f" "plugins" "ebpf" "yes"
  ini_set "$f" "plugin:ebpf" "load mode" "normal"
  ini_set "$f" "plugin:ebpf" "disable apps" "no"
  ini_set "$f" "plugin:ebpf" "process monitoring" "yes"
  ok "eBPF: per-process CPU, disk I/O, network traffic, memory (swap) — chart cực kỳ chi tiết."
  say "Yêu cầu kernel ≥ 4.15 (có CONFIG_BPF) — hầu hết Ubuntu 20.04+ đều đủ."
}

#---- Network viewer: kết nối mạng per-process (thay netstat) ------------------
f_netviewer() {
  title "Network viewer (kết nối mạng per-process)"
  enable_god_module networkviewer
  local f="$NDDIR/go.d/networkviewer.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Sinh bởi netdata-setup.sh — monitor socket connections per process
jobs:
  - name: connections
    protocols:
      - tcp
      - udp
    listen: yes
    states:
      - established
      - listen
      - time_wait
      - close_wait
EOF
  ok "Network viewer: dashboard có chart 'Network Connections' — biết process nào đang listen/connect."
}

#---- Port check: kiểm tra port cụ thể -----------------------------------------
f_portcheck() {
  title "Port check (giám sát port cụ thể)"
  local f="$NDDIR/go.d/portcheck.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Sinh bởi netdata-setup.sh — kiểm tra port dịch vụ quan trọng
jobs:
  - name: web
    hosts:
      - 127.0.0.1
    ports:
      - 80
      - 443
  - name: dns
    hosts:
      - 1.1.1.1
      - 8.8.8.8
    ports:
      - 53
EOF
  ok "Port check: dashboard chart port/service availability + response time."
  say "Sửa /etc/netdata/go.d/portcheck.conf để thêm port theo ý muốn, rồi restart netdata."
}

#---- S.M.A.R.T.: sức khỏe ổ cứng vật lý --------------------------------------
f_smart() {
  title "S.M.A.R.T. — sức khỏe ổ cứng (smartctl)"
  apt_install smartmontools || { warn "Cài smartmontools thất bại — bỏ qua."; return 1; }
  enable_god_module smartctl
  ok "Theo dõi: nhiệt độ ổ, reallocated sectors, % hao mòn SSD/NVMe, power-on hours."
  say "Disk phát hiện: ${HW_DISKS:-?} — ổ sắp hỏng sẽ có alert trước khi chết hẳn."
}

#---- Intel iGPU ---------------------------------------------------------------
f_intelgpu() {
  title "Intel iGPU collector"
  apt_install intel-gpu-tools || { warn "Cài intel-gpu-tools thất bại — bỏ qua."; return 1; }
  enable_god_module intelgpu
  ok "Theo dõi iGPU Intel: engine busy %, frequency, power."
}

#---- IPMI: sensor từ BMC (máy chủ) --------------------------------------------
f_ipmi() {
  title "IPMI sensors (BMC)"
  apt_install freeipmi netdata-plugin-freeipmi 2>/dev/null \
    || apt_install freeipmi \
    || { warn "Cài freeipmi thất bại — bỏ qua."; return 1; }
  ok "freeipmi.plugin tự chạy sau restart — nhiệt độ/quạt/điện áp từ BMC."
}

#---- UPS qua NUT ---------------------------------------------------------------
f_ups() {
  title "UPS (NUT / upsd)"
  enable_god_module upsd
  ok "Collector upsd đọc 127.0.0.1:3493 — battery charge, load, runtime còn lại."
  say "Nếu upsd nằm ở máy khác: sửa /etc/netdata/go.d/upsd.conf rồi restart netdata."
}

#---- Telegram (dùng chung cho alert + ip-watch) ------------------------------
TG_TOKEN=""
TG_CHAT=""
collect_tg() {
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && return 0
  say "Nhập bot Telegram (dùng chung bot với srvctl cũng được):"
  local resp uname
  while true; do
    TG_TOKEN="$(ask_input '   Bot token')"
    resp="$(curl -s --max-time 8 "https://api.telegram.org/bot${TG_TOKEN}/getMe" || true)"
    if printf '%s' "$resp" | grep -q '"ok":true'; then
      uname="$(printf '%s' "$resp" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)"
      ok "   Token hợp lệ: @${uname:-bot}"
      break
    fi
    warn "   Token sai hoặc không có mạng — nhập lại."
  done
  while :; do
    TG_CHAT="$(ask_input '   Chat ID (số; group thường bắt đầu -100)')"
    [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]] && break
    warn "   Chat ID phải là số (vd 123456789 hoặc -1001234567890)."
  done
}

WANT_TG_TEST=0
f_telegram() {
  title "Cảnh báo qua Telegram"
  collect_tg
  # File này được alarm-notify.sh source SAU file stock → chỉ cần override 3 biến
  managed_block "$NDDIR/health_alarm_notify.conf" "netdata-setup telegram" \
"SEND_TELEGRAM=\"YES\"
TELEGRAM_BOT_TOKEN=\"$TG_TOKEN\"
DEFAULT_RECIPIENT_TELEGRAM=\"$TG_CHAT\""
  chmod 640 "$NDDIR/health_alarm_notify.conf" 2>/dev/null || true
  chown netdata:netdata "$NDDIR/health_alarm_notify.conf" 2>/dev/null || true
  ok "Đã bật kênh Telegram cho health engine (kèm ~300 alert mặc định của Netdata)."
  WANT_TG_TEST=1
}

#---- Alert nhiệt độ: hỏi ngưỡng trước, tạo rule sau khi restart --------------
TEMP_WARN=80
TEMP_CRIT=90
WANT_TEMP_ALERT=0
f_temp_alert_ask() {
  title "Ngưỡng cảnh báo nhiệt độ"
  while :; do
    TEMP_WARN="$(ask_input 'WARNING khi vượt (°C)' '80')"
    TEMP_CRIT="$(ask_input 'CRITICAL khi vượt (°C)' '90')"
    if ! [[ "$TEMP_WARN" =~ ^[0-9]+$ && "$TEMP_CRIT" =~ ^[0-9]+$ ]]; then
      warn "Ngưỡng phải là số nguyên (°C) — nhập lại."
    elif [ "$TEMP_CRIT" -le "$TEMP_WARN" ]; then
      warn "CRITICAL ($TEMP_CRIT) phải LỚN HƠN WARNING ($TEMP_WARN) — nhập lại."
    else
      break
    fi
  done
  WANT_TEMP_ALERT=1
  say "Rule sẽ được tạo sau khi restart (cần dò tên chart nhiệt độ thực tế)."
}

detect_ctx() { # $1=pattern grep -iE trên context, $2=exclude pattern (tùy chọn)
  local exc="${2:-__none__}"
  nd_api /api/v1/charts \
    | grep -o '"context":"[^"]*"' \
    | cut -d'"' -f4 | sort -u \
    | grep -iE "$1" | grep -viE "$exc" | head -1
}

post_temp_alert() {
  title "Tạo alert nhiệt độ"
  say "Chờ collector khởi động rồi dò chart nhiệt độ..."
  sleep 8
  local ctx nctx f="$NDDIR/health.d/temperature-setup.conf"
  ctx="$(detect_ctx 'temperature' 'nvidia|target' || true)"
  if [ -z "$ctx" ]; then
    ctx="sensors.sensor_temperature"
    warn "Chưa thấy chart nhiệt độ (có thể cần reboot để load module) — dùng mặc định: $ctx"
  else
    ok "Chart nhiệt độ: $ctx"
  fi
  mkdir -p "$NDDIR/health.d"
  backup_file "$f"
  cat > "$f" << EOF
# Sinh bởi netdata-setup.sh
template: setup_sensor_temp
      on: $ctx
  lookup: average -1m
   units: °C
   every: 30s
    warn: \$this > $TEMP_WARN
    crit: \$this > $TEMP_CRIT
   delay: up 1m down 5m
    info: Nhiet do sensor vuot nguong
      to: sysadmin
EOF
  if [ "${FEAT_ON[nvidia]:-0}" = 1 ]; then
    nctx="$(detect_ctx 'nvidia.*temp|gpu_temperature' || true)"
    [ -n "$nctx" ] || nctx="nvidia_smi.gpu_temperature"
    cat >> "$f" << EOF

template: setup_gpu_temp
      on: $nctx
  lookup: average -1m
   units: °C
   every: 30s
    warn: \$this > $TEMP_WARN
    crit: \$this > $TEMP_CRIT
   delay: up 1m down 5m
    info: Nhiet do GPU vuot nguong
      to: sysadmin
EOF
  fi
  netdatacli reload-health >/dev/null 2>&1 || systemctl restart netdata
  ok "Alert nhiệt độ: warn > ${TEMP_WARN}°C, crit > ${TEMP_CRIT}°C  →  $f"
  say "Parent cũng tự áp rule này cho dữ liệu stream từ child (cùng context chart)."
}

#---- IP-watch: cron 5 phút, báo Telegram khi IP public đổi -------------------
f_ipwatch() {
  title "IP-watch (báo Telegram khi IP public đổi)"
  [ -f /usr/local/bin/ip-watch.sh ] && say "ip-watch ĐÃ có trên máy — sẽ cập nhật lại token/chat, giữ state IP cũ."
  collect_tg
  local f=/usr/local/bin/ip-watch.sh
  backup_file "$f"
  cat > "$f" << 'EOF'
#!/bin/bash
# ip-watch.sh — sinh bởi netdata-setup.sh
# Chỉ nhắn Telegram khi IP public THAY ĐỔI (IP là inventory, không phải metric)
TOKEN="__TOKEN__"
CHAT="__CHAT__"
STATE=/var/tmp/last_public_ip
NEW=$(curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ifconfig.co)
[ -z "$NEW" ] && exit 0
OLD=$(cat "$STATE" 2>/dev/null)
if [ "$NEW" != "$OLD" ]; then
  echo "$NEW" > "$STATE"
  TS=""
  command -v tailscale >/dev/null 2>&1 && TS=$(tailscale ip -4 2>/dev/null | head -1)
  curl -s "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT" \
    --data-urlencode text="🌐 [$(hostname)] IP public đổi: ${OLD:-chưa có} → $NEW${TS:+ | tailscale: $TS}" >/dev/null
fi
EOF
  sed -i "s|__TOKEN__|$TG_TOKEN|; s|__CHAT__|$TG_CHAT|" "$f"
  chmod 700 "$f"   # file chứa bot token — chỉ root được đọc (cron chạy bằng root)
  cat > /etc/cron.d/ip-watch << 'EOF'
# Sinh bởi netdata-setup.sh — kiểm tra IP public mỗi 5 phút
*/5 * * * * root /usr/local/bin/ip-watch.sh
EOF
  chmod 644 /etc/cron.d/ip-watch
  ok "Cron: /etc/cron.d/ip-watch (5 phút/lần). Chạy thử ngay..."
  /usr/local/bin/ip-watch.sh && say "Lần đầu sẽ nhận 1 tin (từ 'chưa có' → IP hiện tại)."
}

#---- Streaming: PARENT nhận --------------------------------------------------
API_KEY=""
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen; else cat /proc/sys/kernel/random/uuid; fi
}
existing_parent_key() {
  grep -oE '^\[[0-9a-fA-F-]{36}\]' "$NDDIR/stream.conf" 2>/dev/null | head -1 | tr -d '[]'
}

valid_key() { # UUID 8-4-4-4-12 hex
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_my_ip() { # $1=ip/hostname → true nếu trỏ về CHÍNH máy này
  local t="$1"
  case "$t" in 127.*|localhost|::1) return 0 ;; esac
  [ "$t" = "$(hostname)" ] && return 0
  ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qx "$t"
}

detect_role() { # in ra: parent | child | both | none (đọc từ stream.conf)
  local p en dest c=""
  p="$(existing_parent_key || true)"
  en="$(ini_get "$NDDIR/stream.conf" stream enabled)"
  dest="$(ini_get "$NDDIR/stream.conf" stream destination)"
  [ "$en" = "yes" ] && [ -n "$dest" ] && c="$dest"
  if   [ -n "$p" ] && [ -n "$c" ]; then echo both
  elif [ -n "$p" ];                then echo parent
  elif [ -n "$c" ];                then echo child
  else                                  echo none
  fi
}

role_guard() { # $1 = vai trò định setup (parent|child) — chặn setup chồng chéo vô thức
  netdata_installed || return 0     # máy chưa có netdata → không có gì để chồng
  local role key dest mh
  role="$(detect_role)"
  key="$(existing_parent_key || true)"
  dest="$(ini_get "$NDDIR/stream.conf" stream destination)"
  case "$1:$role" in
    *:none) return 0 ;;

    parent:parent|parent:both)
      title "PHÁT HIỆN: máy này ĐÃ setup PARENT trước đó"
      say "API key hiện tại: ${B}${key}${N}"
      [ "$role" = both ] && warn "Máy còn đang stream tiếp lên $dest (vai trò kép)."
      say "Chạy tiếp = CẬP NHẬT cấu hình có sẵn (idempotent, có backup) — không phải cài đè."
      ask_yn "→ Tiếp tục cập nhật?" y || return 1
      ;;

    parent:child)
      title "PHÁT HIỆN: máy này đang là CHILD"
      warn "Đang stream về: $dest"
      say "Setup PARENT chồng lên = vai trò KÉP (proxy): vừa nhận stream từ node khác, vừa đẩy tiếp lên $dest."
      if ask_yn "→ TẮT chiều stream đi, chuyển hẳn thành PARENT thuần?" n; then
        ini_set "$NDDIR/stream.conf" stream enabled no
        ok "Đã tắt streaming child — máy sẽ chỉ làm parent."
      else
        say "Giữ vai trò kép (nhận stream + đẩy tiếp lên $dest)."
      fi
      ;;

    child:child)
      title "PHÁT HIỆN: máy này ĐÃ setup CHILD trước đó"
      warn "Đang stream về: $dest"
      say "Chạy tiếp sẽ GHI ĐÈ đích stream (đổi parent / đổi key). Config cũ có backup."
      ask_yn "→ Tiếp tục?" y || return 1
      ;;

    child:parent|child:both)
      title "CẨN THẬN: máy này đang là PARENT"
      warn "API key: $key"
      mh="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
      [ -n "$mh" ] && warn "Node đang stream về đây: $mh"
      say "Setup CHILD sẽ KHÔNG tắt vai trò parent — máy thành PROXY: nhận stream rồi đẩy tiếp lên parent mới."
      say "Nếu anh định setup child cho máy khác (centre/VPS) thì đây là ${B}NHẦM MÁY${N} — chọn n."
      ask_yn "→ Đúng là muốn máy PARENT này stream lên một parent khác?" n || return 1
      ;;
  esac
  return 0
}

f_stream_parent() {
  title "Streaming — PARENT nhận dữ liệu từ child"
  local cur
  cur="$(existing_parent_key || true)"
  if [ -n "$cur" ]; then
    say "stream.conf đã có API key từ trước: ${B}$cur${N}"
    ask_yn "→ Dùng lại key này? (child cũ khỏi cấu hình lại)" y && API_KEY="$cur"
  fi
  if [ -z "$API_KEY" ]; then
    if ask_yn "Tự sinh API key mới (UUID)?" y; then
      API_KEY="$(gen_uuid)"
    else
      API_KEY="$(ask_input 'Dán API key (UUID)')"
      while ! valid_key "$API_KEY"; do
        warn "Không đúng dạng UUID (8-4-4-4-12 hex) — dễ là copy thiếu ký tự."
        ask_yn "→ Nhập lại? (n = vẫn dùng chuỗi này)" y || break
        API_KEY="$(ask_input 'Dán API key (UUID)')"
      done
    fi
  fi
  ini_set "$NDDIR/stream.conf" "$API_KEY" "enabled" "yes"
  ok "Parent chấp nhận stream với key: ${B}$API_KEY${N}"
  say "API key chỉ là mã ghép cặp — traffic đã được Tailscale (WireGuard) mã hóa sẵn."
}

#---- Streaming: CHILD đẩy về parent ------------------------------------------
PARENT_IP=""
f_stream_child() {
  title "Streaming — CHILD đẩy dữ liệu về parent"
  # Cách nhanh: dán chuỗi ghép in ra ở cuối bước setup PARENT
  say "Nếu parent setup bằng tool này, ${B}dán chuỗi ghép NDPAIR${N} — khỏi nhập IP + key riêng."
  local pair rest
  pair="$(ask_input 'Chuỗi ghép (Enter để nhập tay)' '' yes)"
  if [ -n "$pair" ]; then
    case "$pair" in
      NDPAIR:*:*)
        rest="${pair#NDPAIR:}"
        PARENT_IP="${rest%%:*}"
        API_KEY="${rest#*:}"
        ok "Đã nhận: parent = $PARENT_IP · key = $API_KEY"
        ;;
      *)
        warn "Không đúng định dạng NDPAIR:<ip>:<key> — chuyển sang nhập tay."
        ;;
    esac
  fi
  if [ -z "$PARENT_IP" ] || [ -z "$API_KEY" ]; then
    if command -v tailscale >/dev/null 2>&1; then
      say "Node trong Tailscale mesh (chọn IP 100.x.y.z của parent):"
      tailscale status 2>/dev/null | awk '/^100\./ {printf "    %-16s %s\n", $1, $2}' | head -12
    fi
    PARENT_IP="$(ask_input 'IP của PARENT (khuyên dùng IP tailscale 100.x.y.z)')"
    API_KEY="$(ask_input 'API key (hiện ở bước setup parent)')"
  fi
  # Validate: child không được trỏ về chính nó (đứng nhầm máy / dán NDPAIR trên parent)
  while is_my_ip "$PARENT_IP"; do
    err "Parent IP ($PARENT_IP) là CHÍNH MÁY NÀY — child không thể stream về chính nó."
    say "Chuỗi NDPAIR phải được dán trên MÁY KHÁC (centre/VPS), không phải trên parent."
    PARENT_IP="$(ask_input 'Nhập IP của PARENT (máy khác)')"
  done
  while ! valid_key "$API_KEY"; do
    warn "API key không đúng dạng UUID (8-4-4-4-12 hex) — dễ là copy thiếu ký tự."
    ask_yn "→ Nhập lại key? (n = vẫn dùng chuỗi này)" y || break
    API_KEY="$(ask_input 'API key (UUID)')"
  done
  # Pre-flight: thử bắt tay TCP tới parent trước khi ghi config
  if timeout 3 bash -c "exec 3<>/dev/tcp/$PARENT_IP/19999" 2>/dev/null; then
    ok "Kết nối được $PARENT_IP:19999."
  else
    warn "KHÔNG kết nối được $PARENT_IP:19999 — vẫn ghi config; kiểm tra parent đã chạy & firewall."
  fi
  ini_set "$NDDIR/stream.conf" "stream" "enabled"     "yes"
  ini_set "$NDDIR/stream.conf" "stream" "destination" "$PARENT_IP:19999"
  ini_set "$NDDIR/stream.conf" "stream" "api key"     "$API_KEY"
  ok "Child sẽ stream toàn bộ metric về $PARENT_IP:19999 sau khi restart."
}

#---- Bind & health -----------------------------------------------------------
f_bind_local() {
  title "Khóa Web UI về localhost"
  ini_set "$NDDIR/netdata.conf" "web" "bind to" "127.0.0.1"
  ok "Port 19999 chỉ nghe 127.0.0.1 — bên ngoài không truy cập được (bắt buộc nên bật trên VPS)."
}

f_bind_parent_ts() {
  title "Parent chỉ nghe 127.0.0.1 + IP Tailscale"
  local ts
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  if [ -z "$ts" ]; then
    warn "Không lấy được IP tailscale (tailscale chưa cài/chưa up) — bỏ qua."
    return 1
  fi
  ini_set "$NDDIR/netdata.conf" "web" "bind to" "127.0.0.1 $ts"
  ok "Parent nghe trên 127.0.0.1 và $ts."
  warn "Lưu ý boot: nếu tailscaled lên SAU netdata, netdata không bind được $ts tới khi restart."
}

f_health_off() {
  title "Tắt alert cục bộ trên child"
  ini_set "$NDDIR/netdata.conf" "health" "enabled" "no"
  ok "Health engine child = off — parent chạy alert cho node này, tránh thông báo đúp."
}

#---- UFW ----------------------------------------------------------------------
f_ufw() {
  title "UFW — mở 19999 trên interface tailscale0"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "Chưa cài ufw — bỏ qua."
    return 1
  fi
  if ! LANG=C ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw đang inactive — bỏ qua (không cần rule)."
    return 1
  fi
  if ufw allow in on tailscale0 to any port 19999 proto tcp >/dev/null 2>&1; then
    ok "Đã allow in on tailscale0 → 19999/tcp (chỉ mesh Tailscale vào được)."
  else
    warn "Thêm rule ufw thất bại — chạy tay: ufw allow in on tailscale0 to any port 19999 proto tcp"
  fi
}

#===============================================================================
#  MENU BẬT/TẮT TÍNH NĂNG
#===============================================================================
declare -a FEAT_KEYS=()
declare -A FEAT_LABEL=() FEAT_ON=() FEAT_LOCK=() FEAT_NOTE=()

feat_reset() { FEAT_KEYS=(); FEAT_LABEL=(); FEAT_ON=(); FEAT_LOCK=(); FEAT_NOTE=(); }

feat_add() { # key  on(1/0)  label  [note]  [lock-reason]
  local k="$1"
  FEAT_KEYS+=("$k")
  FEAT_ON[$k]="$2"
  FEAT_LABEL[$k]="$3"
  FEAT_NOTE[$k]="${4:-}"
  FEAT_LOCK[$k]="${5:-}"
  [ -n "${FEAT_LOCK[$k]}" ] && FEAT_ON[$k]=0
}

feat_menu() { # màn hình riêng — redraw tại chỗ sau mỗi lần bật/tắt
  crumb_push "Chọn tính năng"
  local i k mark sel msg=""
  while true; do
    ui_header
    printf '\n   Nhập %ssố%s để bật/tắt · %sEnter%s để áp dụng\n\n' "$B" "$N" "$B" "$N"
    i=1
    for k in "${FEAT_KEYS[@]}"; do
      if [ -n "${FEAT_LOCK[$k]}" ]; then
        printf '   %2d. [--] %s  %s(%s)%s\n' "$i" "${FEAT_LABEL[$k]}" "$Y" "${FEAT_LOCK[$k]}" "$N"
      else
        mark=" "; [ "${FEAT_ON[$k]}" = 1 ] && mark="${G}x${N}"
        printf '   %2d. [%s] %s%s\n' "$i" "$mark" "${FEAT_LABEL[$k]}" \
          "${FEAT_NOTE[$k]:+  $C(${FEAT_NOTE[$k]})$N}"
      fi
      i=$((i+1))
    done
    echo
    [ -n "$msg" ] && { warn "$msg"; msg=""; }
    read -rp "   ➜ " sel
    [ -z "$sel" ] && break
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#FEAT_KEYS[@]}" ]; then
      k="${FEAT_KEYS[$((sel-1))]}"
      if [ -n "${FEAT_LOCK[$k]}" ]; then
        msg="Mục $sel đang khóa: ${FEAT_LOCK[$k]}"
      else
        FEAT_ON[$k]=$((1 - FEAT_ON[$k]))
      fi
    else
      msg="Nhập số 1-${#FEAT_KEYS[@]} hoặc Enter"
    fi
  done
  crumb_pop
  ui_header   # về màn hình flow sạch sau khi chốt tính năng
}

feat_common_add() { # các tính năng chung — build ĐỘNG theo kết quả hw_scan
  hw_scan

  local sens_on=1 sens_note=""
  if [ "$VIRT" != "none" ]; then
    sens_on=0
    sens_note="máy ảo ($VIRT) — thường không có sensor thật"
  elif [ "$HW_GPU_AMD" = 1 ]; then
    sens_note="kèm nhiệt độ/power GPU AMD (amdgpu hwmon)"
  fi
  feat_add sensors "$sens_on" "Nhiệt độ CPU/NVMe/mainboard (lm-sensors)" "$sens_note"

  case "$(nvidia_state)" in
    driver) feat_add nvidia 1 "NVIDIA GPU (nhiệt độ, VRAM, power)" "đã thấy nvidia-smi" ;;
    gpu)    feat_add nvidia 1 "NVIDIA GPU (nhiệt độ, VRAM, power)" "CHƯA có driver — tool sẽ hỏi cài" ;;
    none)   feat_add nvidia 0 "NVIDIA GPU" "" "không phát hiện GPU NVIDIA" ;;
  esac

  # Chỉ hiện khi phần cứng thật sự tồn tại — đỡ rối menu
  [ "$HW_GPU_INTEL" = 1 ] \
    && feat_add igpu 1 "Intel iGPU (engine busy, freq, power)" "tool tự cài intel-gpu-tools"

  if [ "$HW_PHYS_DISK" = 1 ]; then
    feat_add smart 1 "S.M.A.R.T. sức khỏe ổ cứng" "$HW_DISKS"
  else
    local smart_lock="không thấy disk vật lý"
    [ "$VIRT" != "none" ] && smart_lock="máy ảo — disk ảo không có SMART"
    feat_add smart 0 "S.M.A.R.T. sức khỏe ổ cứng" "" "$smart_lock"
  fi

  [ "$HW_IPMI" = 1 ] && feat_add ipmi 1 "IPMI sensors (BMC)" "đã thấy /dev/ipmi"
  [ "$HW_UPS"  = 1 ] && feat_add ups  1 "UPS qua NUT (upsd)" "upsd đang chạy"

  local dk_note="docker CHƯA cài — sẽ hỏi cài trong lúc chạy"
  command -v docker >/dev/null 2>&1 && dk_note="docker có sẵn"
  feat_add docker 1 "Docker containers (tên + trạng thái + tài nguyên)" "$dk_note"

  feat_add ping 1 "Ping internet (1.1.1.1, 8.8.8.8) — latency & mất mạng"
  feat_add sysd 1 "Trạng thái systemd services (*.service)"
  feat_add ebpf 1 "eBPF per-process CPU/disk/network/memory" "kernel ≥ 4.15"
  feat_add netview 1 "Network viewer (socket connections per process)"
  feat_add portcheck 0 "Port check (giám sát port 80/443/DNS)"
}

apply_common() {
  [ "${FEAT_ON[sensors]:-0}"  = 1 ] && f_sensors
  [ "${FEAT_ON[nvidia]:-0}"   = 1 ] && f_nvidia
  [ "${FEAT_ON[igpu]:-0}"     = 1 ] && f_intelgpu
  [ "${FEAT_ON[smart]:-0}"    = 1 ] && f_smart
  [ "${FEAT_ON[ipmi]:-0}"     = 1 ] && f_ipmi
  [ "${FEAT_ON[ups]:-0}"      = 1 ] && f_ups
  [ "${FEAT_ON[docker]:-0}"   = 1 ] && f_docker
  [ "${FEAT_ON[ping]:-0}"     = 1 ] && f_ping
  [ "${FEAT_ON[sysd]:-0}"     = 1 ] && f_systemd
  [ "${FEAT_ON[ebpf]:-0}"     = 1 ] && f_ebpf
  [ "${FEAT_ON[netview]:-0}"  = 1 ] && f_netviewer
  [ "${FEAT_ON[portcheck]:-0}" = 1 ] && f_portcheck
  return 0
}

#===============================================================================
#  RESTART / VERIFY / SUMMARY
#===============================================================================
restart_netdata() {
  title "Khởi động lại Netdata"
  systemctl restart netdata
  if wait_api; then
    ok "Netdata đang chạy: v$(nd_api /api/v1/info | grep -o '"version":"[^"]*"' | cut -d'"' -f4)"
  else
    err "Netdata không phản hồi API sau 30s — xem: journalctl -u netdata -n 50"
  fi
}

post_tg_test() {
  title "Test Telegram (không cần chờ sự cố thật)"
  local an=""
  for an in /usr/libexec/netdata/plugins.d/alarm-notify.sh \
            /usr/lib/netdata/plugins.d/alarm-notify.sh \
            /opt/netdata/usr/libexec/netdata/plugins.d/alarm-notify.sh; do
    [ -x "$an" ] && break
    an=""
  done
  if [ -z "$an" ]; then
    warn "Không tìm thấy alarm-notify.sh — test tay sau."
    return 1
  fi
  su -s /bin/bash netdata -c "$an test" 2>&1 | grep -iE 'telegram|sent|ok|fail' | sed 's/^/    /'
  say "Điện thoại phải nhận 3 tin: WARNING / CRITICAL / CLEAR."
}

verify_parent() {
  title "Kiểm tra PARENT"
  sleep 3
  local hosts ts
  hosts="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
  say "Node hiện có trên parent: ${hosts:-<chưa lấy được — child sẽ hiện sau khi setup>}"
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  say "Dashboard: ${B}http://${ts:-<IP-máy-này>}:19999${N}"
}

verify_child() {
  title "Kiểm tra CHILD → PARENT"
  sleep 5
  say "Log streaming gần nhất (tìm chữ 'connected' là ổn):"
  journalctl -u netdata --no-pager -n 300 2>/dev/null \
    | grep -iE 'stream|sender' | tail -5 | sed 's/^/    /' \
    || warn "Không đọc được journal — kiểm tra tay: journalctl -u netdata | grep -i stream"
  say "Xác nhận cuối: mở dashboard PARENT → dropdown Nodes phải có ${B}$(hostname)${N}."
}

summary_parent() {
  local ts pair_ip choice opts
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  
  title "CHỌN IP ĐỂ CHILD KẾT NỐI (PARENT)"
  say "Chọn IP để CHILD stream dữ liệu về:"
  
  # Tạo danh sách lựa chọn
  opts=()
  [ -n "$ts" ] && opts+=("$ts" "Tailscale ($ts)")
  opts+=("$(hostname -I | awk '{print $1}')" "IP Local")
  local pub; pub="$(curl -s --max-time 3 https://ifconfig.me || curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://ifconfig.co || true)"
  [ -n "$pub" ] && opts+=("$pub" "IP Public ($pub)")
  opts+=("manual" "Nhập IP tay")

  # In menu
  for i in $(seq 0 2 $((${#opts[@]}-1))); do
    printf '   %d) %s\n' "$((i/2 + 1))" "${opts[i+1]}"
  done

  # Lấy lựa chọn
  while true; do
    read -rp "   ➜ Chọn (1-$(( ${#opts[@]} / 2 ))): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $(( ${#opts[@]} / 2 )) ]; then
       local idx=$(( (choice-1)*2 ))
       pair_ip="${opts[idx]}"
       [ "$pair_ip" = "manual" ] && pair_ip="$(ask_input 'Nhập IP')"
       break
    fi
  done

  # Lưu chuỗi ghép
  if [ -n "$pair_ip" ] && [ -n "$API_KEY" ]; then
    printf 'NDPAIR:%s:%s\n' "$pair_ip" "$API_KEY" > "$NDDIR/.ndpair"
    chmod 600 "$NDDIR/.ndpair"
  fi

  title "XONG — PARENT ($(hostname))"
  cat << EOF
   Dashboard  : http://${ts:-<IP-máy-này>}:19999
   API key    : ${API_KEY:-<chưa đặt>}
   Backup cfg : $BACKUP_DIR
   Có sẵn     : per-NIC traffic, uptime, disk I/O, load... (Netdata mặc định)
EOF
  hr
  say "${B}COPY DÒNG DƯỚI${N} — khi setup CHILD, dán vào câu hỏi đầu tiên:"
  printf '\n   %sNDPAIR:%s:%s%s\n\n' "$B" "$pair_ip" "$API_KEY" "$N"
  hr
  say "Quên copy? Chạy lại tool → menu 3 (Trạng thái) sẽ in lại chuỗi này."
}

summary_child() {
  title "XONG — CHILD ($(hostname))"
  cat << EOF
   Stream về  : ${PARENT_IP:-<?>}:19999
   Backup cfg : $BACKUP_DIR
   Xem dữ liệu node này tại dashboard PARENT: http://${PARENT_IP:-<parent>}:19999
   (Web UI cục bộ đã khóa 127.0.0.1 nếu anh bật tính năng đó)
EOF
}

#===============================================================================
#  FLOW: PARENT
#===============================================================================
setup_parent() {
  say "PARENT = máy trung tâm: nhận stream từ child, lưu dữ liệu, chạy alert (vd: nitro)."
  WANT_TG_TEST=0; WANT_TEMP_ALERT=0; API_KEY=""

  hw_scan
  role_guard parent || { say "Hủy — quay lại menu."; return 0; }
  install_netdata || return 1

  feat_reset
  feat_common_add
  feat_add tg   1 "Cảnh báo Telegram (kèm ~300 alert mặc định)"
  feat_add temp 1 "Alert nhiệt độ theo ngưỡng tùy chọn"

  local ufw_on=0 ufw_note="chưa cài ufw"
  if command -v ufw >/dev/null 2>&1; then
    if LANG=C ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw_on=1; ufw_note="ufw đang active"
    else
      ufw_note="ufw có nhưng inactive"
    fi
  fi
  feat_add ufw "$ufw_on" "UFW: allow tailscale0 → 19999" "$ufw_note"
  feat_add bindts 0 "Chỉ nghe 127.0.0.1 + IP Tailscale" "mặc định tắt — cẩn thận thứ tự boot"
  feat_add ipwatch 0 "IP-watch: báo Telegram khi IP public đổi (cron 5')"

  feat_menu

  f_stream_parent || return 1
  apply_common
  [ "${FEAT_ON[tg]:-0}"      = 1 ] && f_telegram
  [ "${FEAT_ON[temp]:-0}"    = 1 ] && f_temp_alert_ask
  [ "${FEAT_ON[ufw]:-0}"     = 1 ] && f_ufw
  [ "${FEAT_ON[bindts]:-0}"  = 1 ] && f_bind_parent_ts
  [ "${FEAT_ON[ipwatch]:-0}" = 1 ] && f_ipwatch

  restart_netdata
  [ "$WANT_TEMP_ALERT" = 1 ] && post_temp_alert
  [ "$WANT_TG_TEST"    = 1 ] && post_tg_test
  verify_parent
  summary_parent
}

#===============================================================================
#  FLOW: CHILD
#===============================================================================
setup_child() {
  say "CHILD = node đẩy toàn bộ metric về parent, xem tập trung 1 chỗ (vd: centre, VPS)."
  API_KEY=""; PARENT_IP=""

  hw_scan
  role_guard child || { say "Hủy — quay lại menu."; return 0; }
  install_netdata || return 1

  feat_reset
  feat_common_add
  feat_add bindloc 1 "Khóa Web UI về 127.0.0.1" "bắt buộc nên bật trên VPS public"
  feat_add hoff    1 "Tắt alert cục bộ" "parent chạy alert cho node này — tránh đúp"
  feat_add ipwatch 0 "IP-watch: báo Telegram khi IP public đổi (cron 5')"

  feat_menu

  f_stream_child || return 1
  apply_common
  [ "${FEAT_ON[bindloc]:-0}" = 1 ] && f_bind_local
  [ "${FEAT_ON[hoff]:-0}"    = 1 ] && f_health_off
  [ "${FEAT_ON[ipwatch]:-0}" = 1 ] && f_ipwatch

  restart_netdata
  verify_child
  summary_child
}

#===============================================================================
#  TRẠNG THÁI & GỠ
#===============================================================================
do_status() {
  hw_scan force
  title "Netdata"
  if ! netdata_installed; then
    warn "Netdata (bản native) chưa cài trên máy này."
    diagnose_port19999
  else
    if systemctl is-active netdata >/dev/null 2>&1; then
      ok "Service netdata: active — $(netdata_version)"
    else
      err "Service netdata: $(systemctl is-active netdata 2>/dev/null)"
    fi
    say "Đang nghe:"
    ss -tlnp 2>/dev/null | awk '/:19999/ {print "    " $4}' | sort -u

    # Vai trò CHILD?
    local sen sdest
    sen="$(ini_get "$NDDIR/stream.conf" stream enabled)"
    sdest="$(ini_get "$NDDIR/stream.conf" stream destination)"
    if [ "$sen" = "yes" ] && [ -n "$sdest" ]; then
      say "Vai trò CHILD → stream về $sdest"
      journalctl -u netdata --no-pager -n 300 2>/dev/null \
        | grep -iE 'stream|sender' | tail -3 | sed 's/^/    /'
    fi
    # Vai trò PARENT?
    local pk mh
    pk="$(existing_parent_key || true)"
    if [ -n "$pk" ]; then
      say "Vai trò PARENT — API key: $pk"
      [ -f "$NDDIR/.ndpair" ] \
        && say "Chuỗi ghép child (copy dán khi setup child): ${B}$(cat "$NDDIR/.ndpair")${N}"
      mh="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
      [ -n "$mh" ] && say "Nodes: $mh"
    fi

    if command -v sensors >/dev/null 2>&1; then
      say "Nhiệt độ:"
      sensors 2>/dev/null | grep '°C' | head -4 | sed 's/^/    /'
    fi
    id -nG netdata 2>/dev/null | grep -qw docker && ok "netdata ∈ group docker"
    [ -f "$NDDIR/go.d/ping.conf" ]         && ok "ping.conf: có"
    [ -f "$NDDIR/go.d/systemdunits.conf" ] && ok "systemdunits.conf: có"
    [ -f "$NDDIR/health.d/temperature-setup.conf" ] && ok "alert nhiệt độ: có"
    [ -f /etc/cron.d/ip-watch ]            && ok "ip-watch cron: có"
    if grep -q '^SEND_TELEGRAM="YES"' "$NDDIR/health_alarm_notify.conf" 2>/dev/null; then
      ok "Telegram alert: đã bật (test lại: menu 5)"
    else
      say "Telegram alert: chưa bật (bật: menu 5 hoặc Setup PARENT)"
    fi
  fi

  echo
  say "IP hiện tại của máy này:"
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); printf "    %-14s %s\n", $2, a[1]}'
  local tsip pub
  tsip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$tsip" ] && printf '    %-14s %s\n' "tailscale" "$tsip"
  pub="$(curl -s --max-time 3 https://ifconfig.me || curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://ifconfig.co || true)"
  [ -n "$pub" ] && printf '    %-14s %s\n' "public" "$pub"
}

#---- Gỡ / khôi phục -----------------------------------------------------------
SNAP_BASE="/var/backups"

snapshot_etc() { # copy TOÀN BỘ /etc/netdata (kèm setup-backups) ra nơi an toàn → in đường dẫn
  [ -d "$NDDIR" ] || return 1
  local dest
  dest="$SNAP_BASE/netdata-etc-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SNAP_BASE"
  cp -a "$NDDIR" "$dest" || return 1
  printf '%s' "$dest"
}

purge_snapshots() { # xóa mọi snapshot netdata-etc-* trong SNAP_BASE
  local d
  for d in "$SNAP_BASE"/netdata-etc-*/; do
    [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}

latest_snapshot() { # snapshot mới nhất (glob sort tăng dần theo timestamp)
  local d last=""
  for d in "$SNAP_BASE"/netdata-etc-*/; do [ -d "$d" ] && last="$d"; done
  [ -n "$last" ] || return 1
  printf '%s' "${last%/}"
}

oldest_backup_of() { # $1=file → in đường dẫn bản backup CŨ NHẤT (= bản gốc trước khi tool đụng)
  local rel d
  rel="$(printf '%s' "${1#/}" | tr '/' '_')"
  for d in "$NDDIR"/setup-backups/*/; do   # glob sort tăng dần theo timestamp
    [ -f "$d$rel" ] && { printf '%s' "$d$rel"; return 0; }
  done
  return 1
}

restore_or_remove() { # có backup → khôi phục bản gốc; không → file do tool tạo mới → xóa
  local f="$1" b
  if b="$(oldest_backup_of "$f")"; then
    cp -a "$b" "$f"
    ok "Khôi phục bản gốc: $f"
  elif [ -f "$f" ]; then
    rm -f "$f"
    ok "Xóa (file do tool tạo): $f"
  fi
}

remove_ipwatch() {
  if [ -f /etc/cron.d/ip-watch ] || [ -f /usr/local/bin/ip-watch.sh ]; then
    rm -f /etc/cron.d/ip-watch /usr/local/bin/ip-watch.sh /var/tmp/last_public_ip
    ok "Đã gỡ ip-watch (cron + script + state)."
  else
    say "ip-watch không có trên máy này."
  fi
}

remove_tool_configs() {
  title "Gỡ cấu hình do tool tạo — GIỮ Netdata"
  say "Config sẽ về đúng trạng thái TRƯỚC lần chạy tool đầu tiên (từ backup cũ nhất)."
  ask_yn "Tiếp tục?" n || return 0
  local f
  for f in "$NDDIR/stream.conf" "$NDDIR/netdata.conf" "$NDDIR/go.d.conf" \
           "$NDDIR/health_alarm_notify.conf" "$NDDIR/go.d/ping.conf" \
           "$NDDIR/go.d/systemdunits.conf" "$NDDIR/health.d/temperature-setup.conf"; do
    restore_or_remove "$f"
  done
  rm -f "$NDDIR/.ndpair"
  remove_ipwatch
  command -v ufw >/dev/null 2>&1 \
    && ufw delete allow in on tailscale0 to any port 19999 proto tcp >/dev/null 2>&1
  if systemctl restart netdata 2>/dev/null; then
    ok "Đã restart Netdata với config đã khôi phục."
  fi
  if ask_yn "→ Xóa luôn thư mục backup ($NDDIR/setup-backups)?" n; then
    rm -rf "$NDDIR/setup-backups"
    ok "Đã xóa backup — config hiện tại là bản chốt."
  else
    say "Backup vẫn giữ nguyên tại $NDDIR/setup-backups/ — không mất gì."
  fi
}

purge_netdata_residuals() { # quét mọi nơi Netdata từng đụng — xóa sạch tàn dư
  local p n=0
  for p in /etc/netdata /var/lib/netdata /var/cache/netdata /var/log/netdata \
           /usr/libexec/netdata /usr/lib/netdata /usr/share/netdata \
           /etc/cron.daily/netdata-updater /etc/cron.d/netdata-updater \
           /etc/logrotate.d/netdata \
           /etc/systemd/system/netdata.service \
           /etc/systemd/system/netdata-updater.service \
           /etc/systemd/system/netdata-updater.timer; do
    [ -e "$p" ] || continue
    rm -rf "$p" && { n=$((n+1)); say "  dọn: $p"; }
  done
  for p in /etc/apt/sources.list.d/netdata* /usr/share/keyrings/netdata*; do
    [ -e "$p" ] || continue
    rm -f "$p" && { n=$((n+1)); say "  dọn: $p"; }
  done
  # config packages dpkg còn nhớ (trạng thái rc)
  if command -v dpkg >/dev/null 2>&1; then
    local rcs
    rcs="$(dpkg -l 'netdata*' 2>/dev/null | awk '/^rc/{print $2}' | tr '\n' ' ')"
    if [ -n "${rcs// /}" ]; then
      # shellcheck disable=SC2086
      apt-get purge -y $rcs >/dev/null 2>&1 && say "  purge config packages: $rcs"
    fi
  fi
  # user/group hệ thống còn sót — chỉ khi không còn process nào chạy
  if id netdata >/dev/null 2>&1 && ! pgrep -x netdata >/dev/null 2>&1; then
    userdel netdata >/dev/null 2>&1 && say "  xóa user netdata"
    groupdel netdata >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed netdata 2>/dev/null || true
  if [ "$n" -gt 0 ]; then ok "Đã dọn $n mục tàn dư."; else say "Không còn tàn dư file."; fi
}

uninstall_netdata_full() {
  title "GỠ SẠCH Netdata khỏi máy này"
  if ! netdata_installed && [ -z "$(port19999_line)" ]; then
    warn "Không thấy Netdata (native/static) lẫn tiến trình trên 19999 — không có gì để gỡ."
    remove_ipwatch
    return 0
  fi
  say "Tool sẽ TỰ quét & dọn tất cả: bản native (apt), bản static (/opt/netdata),"
  say "process mồ côi, unit/cron/logrotate/apt-repo/user còn sót — không hỏi thêm."
  ask_yn "Chắc chắn gỡ Netdata?" n || return 0
  local keep=1 snap=""
  if ask_yn "→ GIỮ snapshot config ở $SNAP_BASE để sau này khôi phục? (n = xóa sạch mọi backup)" y; then
    snap="$(snapshot_etc || true)"
    if [ -n "$snap" ]; then
      ok "Đã snapshot /etc/netdata → $snap"
    else
      warn "Không snapshot được (/etc/netdata không có?) — gỡ tiếp."
    fi
  else
    keep=0
    warn "Sẽ XÓA SẠCH mọi backup & snapshot sau khi gỡ — không còn đường khôi phục."
    ask_yn "→ Xác nhận lần cuối?" n || return 0
  fi

  say "${B}[1/5]${N} Dừng & disable service..."
  systemctl disable --now netdata >/dev/null 2>&1 || true

  if netdata_installed; then
    say "${B}[2/5]${N} Gỡ bản cài chính thức (kickstart --uninstall)..."
    local ks=/var/tmp/netdata-kickstart.sh
    if download "$KICKSTART_URL" "$ks"; then
      sh "$ks" --uninstall --non-interactive || warn "kickstart trả lỗi — dọn tiếp bằng tay."
    else
      warn "Không tải được kickstart — gỡ thẳng qua apt."
      apt-get remove --purge -y 'netdata*' >/dev/null 2>&1 || true
    fi
  else
    say "${B}[2/5]${N} Không còn bản cài chính thức — bỏ qua kickstart."
  fi

  say "${B}[3/5]${N} Quét bản static /opt/netdata..."
  local static_un=/opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh
  if [ -x "$static_un" ]; then
    say "  thấy bản static — gỡ tự động..."
    "$static_un" --yes --force || true
  fi
  if [ -d /opt/netdata ]; then
    rm -rf /opt/netdata
    ok "  đã xóa /opt/netdata."
  fi

  say "${B}[4/5]${N} Diệt process sót + dọn tàn dư mọi nơi..."
  # Container netdata (kể cả host-network): pkill vô dụng vì restart policy — phải docker rm -f
  if command -v docker >/dev/null 2>&1; then
    local cline_id cline_name cline_img
    docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null \
      | grep -i netdata | while IFS=$'\t' read -r cline_id cline_name cline_img; do
          say "  container Netdata: $cline_name ($cline_img) — docker rm -f..."
          docker rm -f "$cline_id" >/dev/null 2>&1 && ok "  đã xóa container $cline_name"
        done
  fi
  if port19999_line | grep -q '"netdata"'; then
    pkill -x netdata 2>/dev/null
    sleep 2
    port19999_line | grep -q '"netdata"' && { pkill -9 -x netdata 2>/dev/null; sleep 1; }
  fi
  purge_netdata_residuals
  remove_ipwatch
  command -v ufw >/dev/null 2>&1 \
    && ufw delete allow in on tailscale0 to any port 19999 proto tcp >/dev/null 2>&1

  say "${B}[5/5]${N} Kiểm tra cuối..."
  sleep 1
  local line
  line="$(port19999_line)"
  if [ -z "$line" ]; then
    ok "Port 19999 SẠCH — không còn Netdata nào trên máy."
  elif printf '%s' "$line" | grep -q docker-proxy; then
    warn "Còn Netdata trong DOCKER — container là workload riêng, tool không tự stop:"
    command -v docker >/dev/null 2>&1 \
      && docker ps --filter "publish=19999" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
    say "Tắt:  docker stop <tên> && docker rm <tên>"
  else
    warn "Vẫn còn tiến trình giữ 19999:"
    printf '    %s\n' "$line"
  fi

  if [ "$keep" = 0 ]; then
    purge_snapshots
    ok "Đã gỡ Netdata và XÓA SẠCH mọi backup/snapshot — máy trắng hoàn toàn."
  elif [ -n "$snap" ]; then
    ok "Đã gỡ Netdata. Config cũ (kèm backup gốc) nằm ở: ${B}$snap${N}"
    say "Cài lại & khôi phục: cp -a $snap/. /etc/netdata/ && systemctl restart netdata"
  else
    ok "Đã gỡ Netdata."
  fi
}

do_tg_menu() {
  if ! netdata_installed; then
    warn "Netdata chưa cài — setup parent/child trước."
    return 0
  fi
  if grep -q '^SEND_TELEGRAM="YES"' "$NDDIR/health_alarm_notify.conf" 2>/dev/null; then
    ok "Telegram đang BẬT trên máy này."
    if ask_yn "→ Gửi 3 tin test ngay (WARNING/CRITICAL/CLEAR)?" y; then
      post_tg_test
    fi
    if ask_yn "→ Đổi bot token / chat ID?" n; then
      TG_TOKEN=""; TG_CHAT=""
      f_telegram
      post_tg_test
    fi
  else
    warn "Telegram CHƯA cấu hình trên máy này."
    say "Lưu ý: chỉ cần trên PARENT — child đã tắt health, parent alert thay."
    ask_yn "→ Cấu hình ngay?" y || return 0
    f_telegram
    post_tg_test   # alarm-notify.sh đọc config trực tiếp — test được luôn, khỏi restart
  fi
}

purge_backups() {
  title "Dọn backup & snapshot"
  local d sb=0 sn=0
  if [ -d "$NDDIR/setup-backups" ]; then
    for d in "$NDDIR/setup-backups"/*/; do [ -d "$d" ] && sb=$((sb+1)); done
  fi
  for d in "$SNAP_BASE"/netdata-etc-*/; do [ -d "$d" ] && sn=$((sn+1)); done
  if [ "$sb" -eq 0 ] && [ "$sn" -eq 0 ]; then
    say "Không có backup/snapshot nào để dọn — máy đang sạch."
    return 0
  fi
  say "Tìm thấy: ${B}$sb${N} bản backup ($NDDIR/setup-backups) + ${B}$sn${N} snapshot ($SNAP_BASE)"
  warn "Xóa rồi là MẤT đường khôi phục config gốc — không hoàn tác được."
  ask_yn "→ Xóa hết?" n || return 0
  rm -rf "$NDDIR/setup-backups"
  purge_snapshots
  ok "Đã dọn sạch toàn bộ backup & snapshot."
}

do_uninstall() {
  cat << EOF

   [1]  Gỡ SẠCH Netdata        kickstart --uninstall, dọn cả ip-watch
   [2]  Gỡ config tool tạo     giữ Netdata, khôi phục config gốc từ backup
   [3]  Chỉ gỡ IP-watch        cron + script + state
   [4]  Dọn backup/snapshot    xóa setup-backups + snapshot trong $SNAP_BASE
   [0]  Quay lại

EOF
  local c
  read -rp "   ➜ Chọn: " c
  case "$c" in
    1) uninstall_netdata_full ;;
    2) remove_tool_configs ;;
    3) remove_ipwatch ;;
    4) purge_backups ;;
    *) : ;;
  esac
}

#===============================================================================
#  ENTRY
#===============================================================================
usage() {
  cat << EOF
netdata-setup.sh v$TOOL_VERSION — cài & cấu hình Netdata parent/child tự động

Cách dùng:   sudo bash netdata-setup.sh

Menu chính:
  1) PARENT : nhận stream từ child, dashboard tổng, Telegram alert, alert nhiệt độ
  2) CHILD  : stream về parent, khóa Web UI localhost, tắt alert cục bộ
  3) Trạng thái : service, streaming, sensors, các IP của máy (+ in lại NDPAIR)
  4) Gỡ / khôi phục : gỡ sạch / chỉ gỡ config tool tạo (restore backup) / gỡ ip-watch

Ghép parent-child: setup PARENT xong tool in chuỗi NDPAIR:<ip>:<key> —
copy lại, setup CHILD dán vào câu hỏi đầu tiên là tự điền IP + key.

Tool TỰ QUÉT PHẦN CỨNG rồi build menu theo máy: NVIDIA (hỏi cài driver nếu
thiếu), Intel iGPU, S.M.A.R.T. ổ cứng, IPMI, UPS/NUT, pin, WiFi... Kèm menu
bật/tắt: lm-sensors, Docker (tự hỏi cài), ping, systemd, Telegram, IP-watch,
UFW, bind IP.

Mọi file config bị sửa đều được backup: /etc/netdata/setup-backups/<timestamp>/
Chạy lại nhiều lần an toàn — tool sửa đúng key, không nhân đôi config.
EOF
}

main_menu() {
  CRUMBS=("Menu chính")
  ui_header
  cat << EOF

   [1]  Setup PARENT      máy trung tâm — dashboard + alert tập trung
   [2]  Setup CHILD       node stream dữ liệu về parent
   [3]  Trạng thái        service · vai trò · streaming · sensors · IP
   [4]  Gỡ / khôi phục    gỡ sạch Netdata, hoặc chỉ gỡ config tool tạo
   [5]  Telegram alert    test · cấu hình lần đầu · đổi bot
   [0]  Thoát

EOF
  local c
  read -rp "   ➜ Chọn: " c
  case "$c" in
    1) run_screen "Setup PARENT"    setup_parent ;;
    2) run_screen "Setup CHILD"     setup_child ;;
    3) run_screen "Trạng thái"      do_status ;;
    4) run_screen "Gỡ / khôi phục"  do_uninstall ;;
    5) run_screen "Telegram alert"  do_tg_menu ;;
    0) cls; exit 0 ;;
    *) : ;;
  esac
}

# Cho phép `source` để test hàm mà không chạy menu
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  -h|--help)    usage; exit 0 ;;
  -v|--version) echo "$TOOL_VERSION"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Cần quyền root: sudo bash $0"
if [ ! -t 0 ]; then
  if [ -r /dev/tty ]; then exec < /dev/tty; else die "Tool cần chạy tương tác (tty)."; fi
fi

detect_os
if ! command -v curl >/dev/null 2>&1; then
  warn "Thiếu curl (cần cho API check, Telegram, ip-watch) — cài ngay..."
  apt_install curl || die "Không cài được curl — cài tay rồi chạy lại: apt install curl"
fi
if ! is_debian_like; then
  warn "HĐH: $OS_NAME — tool tối ưu cho Ubuntu/Debian; kickstart & get.docker.com vẫn hỗ trợ nhiều distro khác."
fi

while true; do
  main_menu
done