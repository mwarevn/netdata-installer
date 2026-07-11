#!/usr/bin/env bash
#===============================================================================
#  netdata-setup.sh — Automated Netdata PARENT/CHILD install & configuration
#
#  Usage :  sudo bash netdata-setup.sh
#
#  Menu:
#    1) Setup PARENT — central node: receives streams, dashboard, Telegram alerts
#    2) Setup CHILD  — node streaming to a parent, UI locked, local alerts off
#    3) Status       — check service, streaming, sensors, IPs...
#    4) Remove / restore — full uninstall, or remove only tool-made configs
#
#  Parent-child pairing: at the end of PARENT setup the tool prints an
#  NDPAIR:<ip>:<key> string — copy it, then paste it into the first question
#  of CHILD setup. Done.
#
#  Hardware is auto-scanned (hw_scan) and the feature menu adapts per machine:
#    NVIDIA GPU (offers driver install if missing) · Intel iGPU · AMD (hwmon) ·
#    disk S.M.A.R.T. · IPMI/BMC · UPS (NUT) · laptop battery · WiFi · RAPL
#  Features are toggleable in the menu (type a number to flip, Enter to apply):
#    lm-sensors (temperature) · Docker (auto-install if missing) · internet ping ·
#    systemd services · Telegram alerts · temperature alerts · bind IP ·
#    UFW tailscale0 · IP-watch (notify when public IP changes)
#
#  Safety:
#    - Every modified config file is backed up to
#      /etc/netdata/setup-backups/<timestamp>/ before writing
#    - Safe to re-run (idempotent): edits exact keys, never duplicates
#===============================================================================
set -uo pipefail

TOOL_VERSION="1.14"
STAMP="$(date +%Y%m%d-%H%M%S)"
NDDIR="/etc/netdata"
BACKUP_DIR="$NDDIR/setup-backups/$STAMP"
KICKSTART_URL="https://get.netdata.cloud/kickstart.sh"

#--------------------------------- colors & output ----------------------------
if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; BU=$'\e[34m'; M=$'\e[35m'; C=$'\e[36m'
  B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; BU=""; M=""; C=""; B=""; D=""; N=""
fi

# ---- screen, box drawing & breadcrumb ----
UI_W=64
CRUMBS=()

cls() {
  [ -t 1 ] || return 0
  command clear 2>/dev/null || printf '\033[2J\033[H'
}

crumb_push() { CRUMBS+=("$1"); }
crumb_pop()  { [ ${#CRUMBS[@]} -gt 0 ] && unset "CRUMBS[$((${#CRUMBS[@]}-1))]"; }
crumb_str()  {
  local out="" c
  for c in "${CRUMBS[@]}"; do out="${out:+$out ${D}›${N} }${B}$c${N}"; done
  printf '%s' "$out"
}

strip_ansi() { printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g'; }

# Box drawing — width = UI_W inner columns, borders in cyan
ui_box_top() { printf '  %s╭%s╮%s\n' "$C" "$(printf '─%.0s' $(seq 1 "$UI_W"))" "$N"; }
ui_box_mid() { printf '  %s├%s┤%s\n' "$C" "$(printf '─%.0s' $(seq 1 "$UI_W"))" "$N"; }
ui_box_bot() { printf '  %s╰%s╯%s\n' "$C" "$(printf '─%.0s' $(seq 1 "$UI_W"))" "$N"; }
ui_box_line() { # $1 = text (may contain colors) → padded row inside the box
  local plain pad
  plain="$(strip_ansi "$1")"
  pad=$(( UI_W - 2 - ${#plain} ))
  [ "$pad" -lt 0 ] && pad=0
  printf '  %s│%s %s%*s %s│%s\n' "$C" "$N" "$1" "$pad" "" "$C" "$N"
}

ui_header() {
  cls
  local virt_lbl
  virt_lbl="bare metal"
  [ "$VIRT" != "none" ] && virt_lbl="VM: $VIRT"
  ui_box_top
  ui_box_line "${B}NETDATA SETUP${N} ${C}v${TOOL_VERSION}${N}  ${D}·${N}  $(hostname)  ${D}·${N}  ${OS_NAME}  ${D}·${N}  ${virt_lbl}"
  ui_box_mid
  ui_box_line "$(crumb_str)"
  ui_box_bot
}

pause_return() { echo; read -rp "  ${D}↵ Press Enter to return to the menu...${N}" _; }

run_screen() {
  crumb_push "$1"
  ui_header
  "$2"
  crumb_pop
  pause_return
}

say()   { printf '  %s %s\n' "${C}•${N}" "$*"; }
ok()    { printf '  %s %s\n' "${G}✓${N}" "$*"; }
warn()  { printf '  %s %s\n' "${Y}!${N}" "$*"; }
err()   { printf '  %s %s\n' "${R}✗${N}" "$*" >&2; }
die()   { err "$*"; exit 1; }
hr()    { printf '  %s\n' "${D}$(printf '─%.0s' $(seq 1 "$UI_W"))${N}"; }
title() { # section header:  ── TITLE ───────────────
  local t="$*" fill
  fill=$(( UI_W - ${#t} - 6 ))
  [ "$fill" -lt 3 ] && fill=3
  printf '\n  %s──%s %s%s%s %s%s%s\n' \
    "$C" "$N" "${B}" "$t" "$N" "$C" "$(printf '─%.0s' $(seq 1 "$fill"))" "$N"
}

# Yes/No question — accepts y/n (and Vietnamese co/khong), with a default
ask_yn() { # $1=question  $2=default(y|n)
  local p="$1" d="${2:-y}" a
  while true; do
    if [ "$d" = "y" ]; then
      read -rp "  ${G}?${N} $p ${D}[Y/n]${N}: " a; a="${a:-y}"
    else
      read -rp "  ${G}?${N} $p ${D}[y/N]${N}: " a; a="${a:-n}"
    fi
    case "${a,,}" in
      y|yes|c|co|có)        return 0 ;;
      n|no|k|khong|không)   return 1 ;;
      *) echo "    → type y or n" >&2 ;;
    esac
  done
}

# Ask for input — read -p writes the prompt to stderr, so $() capture stays clean
ask_input() { # $1=question  $2=default(optional)  $3=allow_empty(yes|no)
  local p="$1" d="${2:-}" ae="${3:-no}" a
  while true; do
    if [ -n "$d" ]; then
      read -rp "  ${G}?${N} $p ${D}[$d]${N}: " a; a="${a:-$d}"
    else
      read -rp "  ${G}?${N} $p: " a
    fi
    if [ -n "$a" ] || [ "$ae" = "yes" ]; then
      printf '%s' "$a"; return 0
    fi
    echo "    → cannot be empty" >&2
  done
}

#------------------------------ safe file editing ------------------------------
# One backup per run: the FIRST backup of a file is the original — never overwritten
backup_file() {
  local f="$1" dest
  [ -f "$f" ] || return 0
  mkdir -p "$BACKUP_DIR"
  dest="$BACKUP_DIR/$(printf '%s' "${f#/}" | tr '/' '_')"
  [ -e "$dest" ] || cp -a "$f" "$dest"
}

# ini_set file section key value
# Edit/add exactly 1 key inside 1 section (netdata.conf / stream.conf style),
# leaving everything else untouched. Re-run → value updated, never duplicated.
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
      # New section header encountered
      if (line ~ /^\[.*\]$/) {
        if (ins && !done) { print "    " key " = " val; done=1 }
        ins = (line == "[" sec "]")
        if (ins) found=1
        print raw; next
      }
      # Inside the target section: replace key on match (skip comment lines)
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

# ini_get file section key → prints trimmed value (empty if absent)
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
# Write one marked block — re-running replaces the old block, never appends on top
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

#------------------------------ system detection ------------------------------
OS_ID="unknown"; OS_LIKE=""; OS_NAME="unknown"
detect_os() {
  # Read os-release in a SUBSHELL — it sets VERSION/NAME/ID... which would
  # clobber the tool's variables if sourced directly (bug we hit before:
  # VERSION got replaced with "26.04 LTS (Resolute Raccoon)")
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

# systemd-detect-virt prints "none" but EXITS 1 on bare metal → must NOT
# use "|| echo none" (yields "none\nnone" and bare metal gets treated as a VM)
VIRT="$(systemd-detect-virt 2>/dev/null)"
[ -n "$VIRT" ] || VIRT="none"

nvidia_state() { # prints: driver | gpu | none
  if command -v nvidia-smi >/dev/null 2>&1; then
    echo driver
  elif grep -qs 0x10de /sys/bus/pci/devices/*/vendor 2>/dev/null; then
    echo gpu
  else
    echo none
  fi
}

#------------------------------ hardware scan -------------------------------
# Detect once, store in HW_* variables — the feature menu uses these to auto-enable/lock
HW_CPU=""; HW_RAM=""; HW_DISKS=""; HW_PHYS_DISK=0
HW_GPU_INTEL=0; HW_GPU_AMD=0; HW_GPU_NVIDIA=""; HW_IPMI=0; HW_UPS=0; HW_WIFI=""
HW_SCANNED=0

hw_scan() { # call "hw_scan force" to rescan & reprint
  [ "$HW_SCANNED" = 1 ] && [ "${1:-}" != "force" ] && return 0
  HW_SCANNED=1
  HW_GPU_INTEL=0; HW_GPU_AMD=0; HW_GPU_NVIDIA=""; HW_IPMI=0; HW_UPS=0; HW_PHYS_DISK=0
  title "HARDWARE SCAN — $(hostname)"

  # CPU + RAM
  HW_CPU="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
  [ -n "$HW_CPU" ] || HW_CPU="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ */,"",$2); print $2; exit}')"
  HW_RAM="$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
  printf "  ${D}%-10s${N} %s (%s threads)\n" "CPU" "${HW_CPU:-?}" "$(nproc 2>/dev/null || echo '?')"
  printf "  ${D}%-10s${N} %s\n" "RAM" "${HW_RAM:-?}"

  # GPU — walk PCI class 0x03xxxx (display controller)
  local d cls ven
  for d in /sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    read -r cls < "$d/class"
    case "$cls" in 0x03*) ;; *) continue ;; esac
    read -r ven < "$d/vendor" 2>/dev/null || continue
    case "$ven" in
      0x8086) HW_GPU_INTEL=1 ;;
      0x1002) HW_GPU_AMD=1 ;;
      0x10de) # NVIDIA — check driver by probing nvidia-smi
        if command -v nvidia-smi >/dev/null 2>&1; then
           HW_GPU_NVIDIA=driver
        else
           HW_GPU_NVIDIA=gpu
        fi
        ;;
    esac
  done
  case "${HW_GPU_NVIDIA:-none}" in
    driver) printf "  ${D}%-10s${N} NVIDIA %s  ${G}[driver OK]${N}\n" "GPU" \
              "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" ;;
    gpu)    printf "  ${D}%-10s${N} NVIDIA (PCI) — ${Y}driver MISSING${N}, tool can install it\n" "GPU" ;;
    *)      case "$(nvidia_state)" in
               driver) printf "  ${D}%-10s${N} NVIDIA %s  ${G}[driver OK]${N}\n" "GPU" \
                         "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" ;;
               gpu)    printf "  ${D}%-10s${N} NVIDIA (PCI) — ${Y}driver MISSING${N}, tool can install it\n" "GPU" ;;
            esac
            ;;
  esac
  [ "$HW_GPU_INTEL" = 1 ] && printf "  ${D}%-10s${N} Intel iGPU — intelgpu collector available\n" "GPU"
  [ "$HW_GPU_AMD"  = 1 ] && printf "  ${D}%-10s${N} AMD — temperature/power via lm-sensors (amdgpu hwmon)\n" "GPU"

  # Physical disks (skip loop/zram/ram/cdrom) — classified as NVMe / SSD / HDD
  HW_DISKS="$(lsblk -dno NAME,SIZE,ROTA,TYPE 2>/dev/null | awk '
    $4=="disk" && $1 !~ /^(loop|zram|ram|sr|fd)/ {
      kind = ($1 ~ /^nvme/) ? "NVMe" : ($3=="1" ? "HDD" : "SSD")
      printf "%s%s %s (%s)", sep, $1, $2, kind; sep=" · "
    }')"
  if [ -n "$HW_DISKS" ]; then
    printf "  ${D}%-10s${N} %s\n" "Disk" "$HW_DISKS"
    [ "$VIRT" = "none" ] && HW_PHYS_DISK=1
  fi

  # Laptop battery → Netdata ships the power_supply chart out of the box
  if compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
    printf "  ${D}%-10s${N} laptop — battery chart built into Netdata\n" "Battery"
  fi

  # IPMI/BMC (server)
  if compgen -G "/sys/class/ipmi/*" >/dev/null 2>&1 || [ -e /dev/ipmi0 ]; then
    HW_IPMI=1
    printf "  ${D}%-10s${N} BMC present — freeipmi collector available\n" "IPMI"
  fi

  # UPS qua NUT
  if systemctl is-active nut-server >/dev/null 2>&1 \
     || systemctl is-active upsd >/dev/null 2>&1 \
     || pgrep -x upsd >/dev/null 2>&1; then
    HW_UPS=1
    printf "  ${D}%-10s${N} NUT (upsd) running — upsd collector available\n" "UPS"
  fi

  # WiFi interface → signal chart built in
  local w ifaces=""
  for w in /sys/class/net/*/wireless; do
    [ -d "$w" ] && ifaces="$ifaces $(basename "$(dirname "$w")")"
  done
  HW_WIFI="${ifaces# }"
  [ -n "$HW_WIFI" ] && printf "  ${D}%-10s${N} %s — signal chart built in\n" "WiFi" "$HW_WIFI"

  [ -d /sys/class/powercap/intel-rapl ] \
    && printf "  ${D}%-10s${N} Intel RAPL — CPU power draw built in\n" "Power"

  if [ "$VIRT" = "none" ]; then
    printf "  ${D}%-10s${N} none (bare metal)\n" "Virt"
  else
    printf "  ${D}%-10s${N} %s\n" "Virt" "$VIRT"
  fi
  if command -v docker >/dev/null 2>&1; then
    printf "  ${D}%-10s${N} yes (%s containers running)\n" "Docker" "$(docker ps -q 2>/dev/null | wc -l)"
  else
    printf "  ${D}%-10s${N} not installed\n" "Docker"
  fi
  local tsip
  tsip="$(tailscale ip -4 2>/dev/null | head -1)"
  printf "  ${D}%-10s${N} %s\n" "Tailscale" "${tsip:-none}"
}

APT_UPDATED=0
apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    warn "apt-get not available — install these packages manually: $*"
    return 1
  fi
  if [ "$APT_UPDATED" != 1 ]; then
    say "apt-get update..."
    apt-get update -qq
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

#------------------------------ netdata basics -------------------------------
port19999_line() { ss -tlnp 2>/dev/null | grep ':19999 ' | head -1; }

_cgroup_container_id() { # parse container-id from cgroup content (stdin)
  grep -oE '(docker[-/]|containerd[-/]|cri-containerd[-/])[0-9a-f]{12,64}' 2>/dev/null \
    | head -1 | grep -oE '[0-9a-f]{12,64}$'
}
pid_in_container() { # $1=pid → prints container-id if the process lives in docker/containerd
  _cgroup_container_id < "/proc/$1/cgroup" 2>/dev/null
}

diagnose_port19999() { # port clean → silent; someone holding it → name it + how to fix
  local line
  line="$(port19999_line)"
  [ -n "$line" ] || return 0
  warn "Port 19999 STILL has a process listening:"
  printf '    %s\n' "$line"
  if printf '%s' "$line" | grep -q docker-proxy; then
    say "→ This is Netdata running in ${B}DOCKER${N} — removing the native package will NOT touch the container."
    if command -v docker >/dev/null 2>&1; then
      say "Containers publishing 19999:"
      docker ps --filter "publish=19999" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
      say "Stop for good:  docker stop <name> && docker rm <name>  (or drop it from the compose stack)"
    fi
  elif printf '%s' "$line" | grep -q netdata; then
    local dpid cid
    dpid="$(printf '%s' "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
    cid=""
    [ -n "$dpid" ] && cid="$(pid_in_container "$dpid" || true)"
    if [ -n "$cid" ]; then
      say "→ Netdata runs INSIDE a ${B}DOCKER container (host network)${N} — killing the process gets resurrected by its restart policy!"
      command -v docker >/dev/null 2>&1 \
        && docker ps -a --filter "id=$cid" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
      say "Remove for good:  docker rm -f ${cid:0:12}   (if it's in compose, drop it from the file or it comes back on up)"
    else
      say "→ Leftover netdata process: STATIC build or an orphaned process."
      [ -d /opt/netdata ] \
        && say "Found ${B}/opt/netdata${N} (static build) — remove: /opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh --yes" \
        || say "Kill the orphan:  pkill -x netdata"
    fi
  else
    say "→ A DIFFERENT process owns 19999 (name in the line above) — deal with it before installing Netdata."
  fi
  say "Note: the dashboard is an SPA — old browser tabs keep showing cached UI, do a hard refresh (Ctrl+Shift+R)."
}

netdata_installed() {
  command -v netdata >/dev/null 2>&1 && return 0
  [ -x /opt/netdata/usr/sbin/netdata ] && return 0   # static build
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

download() { # $1=url $2=dest — try curl, fall back to wget; clean up junk on failure
  rm -f "$2" 2>/dev/null
  if command -v curl >/dev/null 2>&1 && curl -fsSL "$1" -o "$2"; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1 && wget -qO "$2" "$1"; then
    return 0
  fi
  rm -f "$2" 2>/dev/null
  err "Download failed: $1"
  say "Check: network/DNS, and free space at destination:  df -h $(dirname "$2")"
  return 1
}

install_netdata() {
  if netdata_installed; then
    ok "Netdata already installed: $(netdata_version)"
    return 0
  fi
  warn "Netdata is not installed on this machine."
  if [ -n "$(port19999_line)" ]; then
    diagnose_port19999
    ask_yn "→ Port 19999 is busy — install anyway? (native netdata won't be able to bind)" n || return 1
  fi
  ask_yn "→ Install Netdata now (official kickstart, stable channel, telemetry off)?" y \
    || { err "Cannot continue without Netdata."; return 1; }
  say "Downloading kickstart..."
  local ks=/var/tmp/netdata-kickstart.sh
  download "$KICKSTART_URL" "$ks" || return 1
  # Make sure the netdata user/group exists before installing
  if ! getent group netdata >/dev/null; then groupadd -r netdata; fi
  if ! getent passwd netdata >/dev/null; then useradd -r -g netdata -s /usr/sbin/nologin netdata; fi

  say "Installing (takes 1-3 minutes)..."
  # Try a native install first; on failure retry with type 'any'
  if ! sh "$ks" --non-interactive --stable-channel --disable-telemetry; then
    warn "Native install failed, retrying with --install-type any..."
    sh "$ks" --non-interactive --stable-channel --disable-telemetry --install-type any \
      || { err "Netdata install failed."; return 1; }
  fi
  systemctl enable --now netdata >/dev/null 2>&1 || true
  netdata_installed || { err "Install finished but the netdata service is missing."; return 1; }
  ok "Netdata installed: $(netdata_version)"
  local snap
  snap="$(latest_snapshot || true)"
  if [ -n "$snap" ]; then
    say "Found a config snapshot from a previous uninstall: $snap"
    if ask_yn "→ Restore that old config now (stream, telegram, alerts... back as they were)?" n; then
      cp -a "$snap/." "$NDDIR/" && systemctl restart netdata         && ok "Config restored from snapshot + restarted."         || warn "Restore failed — copy manually: cp -a $snap/. $NDDIR/"
    fi
  fi
}

#===============================================================================
#  FEATURES (one function each — toggled via the menu)
#===============================================================================

#---- Temperature: lm-sensors + kernel module detection ------------------------
f_sensors() {
  title "Temperature (lm-sensors)"
  apt_install lm-sensors || { warn "lm-sensors install failed — skipping."; return 1; }
  say "Probing sensor chips (sensors-detect)..."
  yes '' | sensors-detect >/dev/null 2>&1 || true
  systemctl restart systemd-modules-load.service 2>/dev/null || true
  if sensors 2>/dev/null | grep -q '°C'; then
    ok "Temperature readings OK:"
    sensors 2>/dev/null | grep '°C' | head -6 | sed 's/^/    /'
  else
    warn "No temperature readings yet — VM, or a reboot is needed to load kernel modules."
  fi
}

#---- NVIDIA GPU collector (go.d nvidia_smi) ----------------------------------
enable_god_module() { # enable 1 module in /etc/netdata/go.d.conf without breaking the rest
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
    warn "NVIDIA GPU found on PCI but NO driver yet (nvidia-smi missing)."
    if [ "$OS_ID" = "ubuntu" ]; then
      if ask_yn "→ Install the recommended NVIDIA driver now (ubuntu-drivers)?" y; then
        apt_install ubuntu-drivers-common || return 1
        say "Installing driver (a few minutes, log: /var/tmp/nvidia-driver.log)..."
        if ubuntu-drivers install > /var/tmp/nvidia-driver.log 2>&1; then
          ok "Driver installed — ${B}REBOOT REQUIRED${N} to load the nvidia module."
          warn "After the reboot, run the tool again: the NVIDIA item will detect the driver and enable the collector."
        else
          err "Driver install failed — see: tail -30 /var/tmp/nvidia-driver.log"
        fi
      else
        warn "Skipped — install the driver manually, then run the tool again."
      fi
    else
      warn "OS is not Ubuntu — install the NVIDIA driver manually, then run the tool again."
    fi
    return 1
  fi
  if [ "$st" != "driver" ]; then
    warn "No NVIDIA GPU detected — skipping."
    return 1
  fi
  enable_god_module nvidia_smi
  ok "nvidia_smi collector enabled: GPU temperature, VRAM, power draw, utilization."
}

#---- Docker: auto-detect, offer install if missing ----------------------------
f_docker() {
  title "Docker integration"
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is NOT installed on this machine ($OS_NAME)."
    if ask_yn "→ Install Docker now? (official get.docker.com script — auto-detects the OS)" y; then
      say "Downloading & installing Docker..."
      if download https://get.docker.com /var/tmp/get-docker.sh \
         && sh /var/tmp/get-docker.sh > /var/tmp/get-docker.log 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1 || true
        ok "Installed: $(docker --version 2>/dev/null)"
      else
        err "Docker install failed — last 10 log lines:"
        tail -10 /var/tmp/get-docker.log 2>/dev/null | sed 's/^/    /'
        return 1
      fi
    else
      warn "Skipping Docker integration."
      return 1
    fi
  else
    ok "Docker present: $(docker --version 2>/dev/null)"
  fi
  # Let the netdata user read docker.sock → shows container NAMES + STATE
  if id -nG netdata 2>/dev/null | grep -qw docker; then
    ok "User netdata is already in the docker group."
  else
    if ask_yn "→ Add the netdata user to the docker group (so Netdata can read containers)?" y; then
      if usermod -aG docker netdata 2>/dev/null; then
        ok "netdata user added to the docker group (takes effect after netdata restarts)."
      else
        warn "Could not add netdata to the docker group — check root privileges."
      fi
    fi
  fi
  # Configure the cgroups plugin so Docker containers show up clearly on the dashboard
  local cgf="$NDDIR/netdata.conf"
  backup_file "$cgf"
  ini_set "$cgf" "plugin:cgroups" "check for new cgroups every" "5"
  ini_set "$cgf" "plugin:cgroups" "enable new cgroups detected at runtime" "yes"
  ini_set "$cgf" "plugin:cgroups" "enable cgroups-detailed" "yes"
  ini_set "$cgf" "plugin:cgroups" "enable by default" "docker"
  ok "Cgroups plugin: will monitor all Docker containers (CPU, mem, net, disk)."
}

#---- Internet ping: each node knows its own way out ---------------------------
f_ping() {
  title "Internet monitoring (ping)"
  local f="$NDDIR/go.d/ping.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Generated by netdata-setup.sh — ping the internet: this node's latency + packet loss
jobs:
  - name: internet
    hosts:
      - 1.1.1.1
      - 8.8.8.8
EOF
  ok "Pings 1.1.1.1 + 8.8.8.8 every second — the moment a node loses its uplink, you know which one."
}

#---- Systemd services: state of every *.service -------------------------------
f_systemd() {
  title "Systemd services monitoring"
  enable_god_module systemdunits
  local f="$NDDIR/go.d/systemdunits.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Generated by netdata-setup.sh — track the state of all service units
jobs:
  - name: services
    include:
      - '*.service'
EOF
  ok "Watching every *.service: active / failed / inactive — a dead service shows up instantly."
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
    warn "eBPF plugin not found in the Netdata package — trying the extra package..."
    apt_install netdata-plugin-ebpf 2>/dev/null || { warn "No separate netdata-plugin-ebpf package — the plugin ships with the default install."; }
  fi
  local f="$NDDIR/netdata.conf"
  backup_file "$f"
  ini_set "$f" "plugins" "ebpf" "yes"
  ini_set "$f" "plugin:ebpf" "load mode" "normal"
  ini_set "$f" "plugin:ebpf" "disable apps" "no"
  ini_set "$f" "plugin:ebpf" "process monitoring" "yes"
  ok "eBPF: per-process CPU, disk I/O, network traffic, memory (swap) — extremely detailed charts."
  say "Requires kernel ≥ 4.15 (with CONFIG_BPF) — virtually all Ubuntu 20.04+ qualifies."
}

#---- Network viewer: per-process network connections (netstat replacement) ----
f_netviewer() {
  title "Network viewer (per-process connections)"
  enable_god_module networkviewer
  local f="$NDDIR/go.d/networkviewer.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Generated by netdata-setup.sh — monitor socket connections per process
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
  ok "Network viewer: dashboard gets a 'Network Connections' chart — see which process listens/connects."
}

#---- Port check: watch specific ports -----------------------------------------
f_portcheck() {
  title "Port check (watch specific ports)"
  local f="$NDDIR/go.d/portcheck.conf"
  mkdir -p "$NDDIR/go.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Generated by netdata-setup.sh — check ports of critical services
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
  say "Edit /etc/netdata/go.d/portcheck.conf to add your own ports, then restart netdata."
}

#---- S.M.A.R.T.: physical disk health ------------------------------------------
f_smart() {
  title "S.M.A.R.T. — disk health (smartctl)"
  apt_install smartmontools || { warn "smartmontools install failed — skipping."; return 1; }
  enable_god_module smartctl
  ok "Tracking: drive temperature, reallocated sectors, SSD/NVMe wear %, power-on hours."
  say "Disks detected: ${HW_DISKS:-?} — a failing drive alerts before it dies for good."
}

#---- Intel iGPU ---------------------------------------------------------------
f_intelgpu() {
  title "Intel iGPU collector"
  apt_install intel-gpu-tools || { warn "intel-gpu-tools install failed — skipping."; return 1; }
  enable_god_module intelgpu
  ok "Tracking Intel iGPU: engine busy %, frequency, power."
}

#---- IPMI: sensors from the BMC (servers) --------------------------------------
f_ipmi() {
  title "IPMI sensors (BMC)"
  apt_install freeipmi netdata-plugin-freeipmi 2>/dev/null \
    || apt_install freeipmi \
    || { warn "freeipmi install failed — skipping."; return 1; }
  ok "freeipmi.plugin starts automatically after restart — temperature/fans/voltage from the BMC."
}

#---- UPS via NUT ----------------------------------------------------------------
f_ups() {
  title "UPS (NUT / upsd)"
  enable_god_module upsd
  ok "upsd collector reads 127.0.0.1:3493 — battery charge, load, remaining runtime."
  say "If upsd lives on another machine: edit /etc/netdata/go.d/upsd.conf, then restart netdata."
}

#---- Telegram (shared by alerts + ip-watch) ------------------------------------
TG_TOKEN=""
TG_CHAT=""
collect_tg() {
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && return 0
  say "Enter your Telegram bot (sharing the srvctl bot is fine):"
  local resp uname
  while true; do
    TG_TOKEN="$(ask_input '   Bot token')"
    resp="$(curl -s --max-time 8 "https://api.telegram.org/bot${TG_TOKEN}/getMe" || true)"
    if printf '%s' "$resp" | grep -q '"ok":true'; then
      uname="$(printf '%s' "$resp" | grep -o '"username":"[^"]*"' | cut -d'"' -f4)"
      ok "   Token valid: @${uname:-bot}"
      break
    fi
    warn "   Bad token or no network — try again."
  done
  while :; do
    TG_CHAT="$(ask_input '   Chat ID (numeric; groups usually start with -100)')"
    [[ "$TG_CHAT" =~ ^-?[0-9]+$ ]] && break
    warn "   Chat ID must be numeric (e.g. 123456789 or -1001234567890)."
  done
}

WANT_TG_TEST=0
f_telegram() {
  title "Telegram alerts"
  collect_tg
  # alarm-notify.sh sources this file AFTER the stock one → overriding 3 vars is enough
  managed_block "$NDDIR/health_alarm_notify.conf" "netdata-setup telegram" \
"SEND_TELEGRAM=\"YES\"
TELEGRAM_BOT_TOKEN=\"$TG_TOKEN\"
DEFAULT_RECIPIENT_TELEGRAM=\"$TG_CHAT\""
  chmod 640 "$NDDIR/health_alarm_notify.conf" 2>/dev/null || true
  chown netdata:netdata "$NDDIR/health_alarm_notify.conf" 2>/dev/null || true
  ok "Telegram channel enabled for the health engine (plus ~300 stock Netdata alerts)."
  WANT_TG_TEST=1
}

#---- Temperature alert: ask thresholds first, create rules after restart -------
TEMP_WARN=80
TEMP_CRIT=90
WANT_TEMP_ALERT=0
f_temp_alert_ask() {
  title "Temperature alert thresholds"
  while :; do
    TEMP_WARN="$(ask_input 'WARNING above (°C)' '80')"
    TEMP_CRIT="$(ask_input 'CRITICAL above (°C)' '90')"
    if ! [[ "$TEMP_WARN" =~ ^[0-9]+$ && "$TEMP_CRIT" =~ ^[0-9]+$ ]]; then
      warn "Thresholds must be integers (°C) — try again."
    elif [ "$TEMP_CRIT" -le "$TEMP_WARN" ]; then
      warn "CRITICAL ($TEMP_CRIT) must be GREATER than WARNING ($TEMP_WARN) — try again."
    else
      break
    fi
  done
  WANT_TEMP_ALERT=1
  say "Rules will be created after the restart (the actual temperature chart name must be probed first)."
}

detect_ctx() { # $1=grep -iE pattern on context, $2=exclude pattern (optional)
  local exc="${2:-__none__}"
  nd_api /api/v1/charts \
    | grep -o '"context":"[^"]*"' \
    | cut -d'"' -f4 | sort -u \
    | grep -iE "$1" | grep -viE "$exc" | head -1
}

post_temp_alert() {
  title "Creating temperature alerts"
  say "Waiting for collectors to start, then probing for temperature charts..."
  sleep 8
  local ctx nctx f="$NDDIR/health.d/temperature-setup.conf"
  ctx="$(detect_ctx 'temperature' 'nvidia|target' || true)"
  if [ -z "$ctx" ]; then
    ctx="sensors.sensor_temperature"
    warn "No temperature chart found (a reboot may be needed to load modules) — using default: $ctx"
  else
    ok "Temperature chart: $ctx"
  fi
  mkdir -p "$NDDIR/health.d"
  backup_file "$f"
  cat > "$f" << EOF
# Generated by netdata-setup.sh
template: setup_sensor_temp
      on: $ctx
  lookup: average -1m
   units: °C
   every: 30s
    warn: \$this > $TEMP_WARN
    crit: \$this > $TEMP_CRIT
   delay: up 1m down 5m
    info: Sensor temperature above threshold
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
    info: GPU temperature above threshold
      to: sysadmin
EOF
  fi
  netdatacli reload-health >/dev/null 2>&1 || systemctl restart netdata
  ok "Temperature alerts: warn > ${TEMP_WARN}°C, crit > ${TEMP_CRIT}°C  →  $f"
  say "The parent also applies these rules to data streamed from children (same chart context)."
}

#---- Child-disconnect alert (PARENT) -------------------------------------------
# Netdata >= v2.3 ships 2 stock alerts streaming_disconnected / streaming_never_connected
# on the netdata.streaming_inbound chart, BUT stock sets `to: silent` → they only
# show on the dashboard and NEVER send a notification. On top of that: a 30-min
# uptime guard + delay up 5m. This file overrides stock (same filename
# health.d/streaming.conf, must contain BOTH templates) → routes to the sysadmin
# role (Telegram) + reacts faster.
f_disconnect_alert() {
  title "Child-disconnect alert"
  local f="$NDDIR/health.d/streaming.conf"
  mkdir -p "$NDDIR/health.d"
  backup_file "$f"
  cat > "$f" << 'EOF'
# Generated by netdata-setup.sh — overrides stock health.d/streaming.conf
# Stock (Netdata >= 2.3) defaults to `to: silent`, so a dropped child sends NO Telegram.
# This version: to sysadmin, alerts after ~2min offline, silent for the first 10min
# after parent boot (lets children reconnect, avoids false alarms). Nodes marked
# ephemeral are not alerted on.

 template: streaming_disconnected
       on: netdata.streaming_inbound
    class: Availability
     type: Streaming
component: Streaming
chart labels: type=permanent
     calc: ${stale disconnected}
    units: nodes
    every: 10s
     warn: $netdata.uptime.uptime > 10 * 60 AND $this > 0
    delay: up 2m down 5m
  summary: Streaming node(s) disconnected
     info: A PERMANENT child node is disconnected from this parent
       to: sysadmin

 template: streaming_never_connected
       on: netdata.streaming_inbound
    class: Availability
     type: Streaming
component: Streaming
chart labels: type=permanent
     calc: ${stale archived}
    units: nodes
    every: 10s
     warn: $netdata.uptime.uptime > 30 * 60 AND $this > 0
    delay: up 5m down 5m multiplier 1.5 max 30m
  summary: Streaming nodes never connected
     info: A node has never reconnected to this parent
       to: sysadmin
EOF
  ok "Child offline for ~2 minutes → parent fires a WARNING to Telegram (sysadmin role)."
  say "Requires Netdata ≥ v2.3 (has the netdata.streaming_inbound chart); older versions silently skip these rules."
  say "Real test: on a child run  systemctl stop netdata  → wait 2-3 minutes → a message must arrive."
}

#---- IP-watch: 5-min cron, Telegram alert when the public IP changes -----------
f_ipwatch() {
  title "IP-watch (Telegram alert on public IP change)"
  [ -f /usr/local/bin/ip-watch.sh ] && say "ip-watch ALREADY exists on this machine — token/chat will be updated, old IP state kept."
  collect_tg
  local f=/usr/local/bin/ip-watch.sh
  backup_file "$f"
  cat > "$f" << 'EOF'
#!/bin/bash
# ip-watch.sh — generated by netdata-setup.sh
# Sends Telegram ONLY when the public IP CHANGES (an IP is inventory, not a metric)
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
    --data-urlencode text="🌐 [$(hostname)] Public IP changed: ${OLD:-none} → $NEW${TS:+ | tailscale: $TS}" >/dev/null
fi
EOF
  sed -i "s|__TOKEN__|$TG_TOKEN|; s|__CHAT__|$TG_CHAT|" "$f"
  chmod 700 "$f"   # file holds the bot token — root-only read (cron runs as root)
  cat > /etc/cron.d/ip-watch << 'EOF'
# Generated by netdata-setup.sh — check the public IP every 5 minutes
*/5 * * * * root /usr/local/bin/ip-watch.sh
EOF
  chmod 644 /etc/cron.d/ip-watch
  ok "Cron: /etc/cron.d/ip-watch (every 5 minutes). Running once now..."
  /usr/local/bin/ip-watch.sh && say "The first run sends 1 message (from 'none' → current IP)."
}

#---- Streaming: PARENT receives -------------------------------------------------
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

is_my_ip() { # $1=ip/hostname → true if it points at THIS very machine
  local t="$1"
  case "$t" in 127.*|localhost|::1) return 0 ;; esac
  [ "$t" = "$(hostname)" ] && return 0
  ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -qx "$t"
}

detect_role() { # prints: parent | child | both | none (read from stream.conf)
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

role_guard() { # $1 = role about to be set up (parent|child) — blocks accidental overlapping setups
  netdata_installed || return 0     # no netdata yet → nothing to overlap with
  local role key dest mh
  role="$(detect_role)"
  key="$(existing_parent_key || true)"
  dest="$(ini_get "$NDDIR/stream.conf" stream destination)"
  case "$1:$role" in
    *:none) return 0 ;;

    parent:parent|parent:both)
      title "DETECTED: this machine was ALREADY set up as PARENT"
      say "Current API key: ${B}${key}${N}"
      [ "$role" = both ] && warn "It is also still streaming up to $dest (dual role)."
      say "Continuing = UPDATING the existing config (idempotent, backed up) — not overwriting from scratch."
      ask_yn "→ Continue with the update?" y || return 1
      ;;

    parent:child)
      title "DETECTED: this machine is currently a CHILD"
      warn "Currently streaming to: $dest"
      say "Setting up PARENT on top = DUAL role (proxy): receives streams from other nodes AND relays up to $dest."
      if ask_yn "→ DISABLE the outgoing stream and become a pure PARENT?" n; then
        ini_set "$NDDIR/stream.conf" stream enabled no
        ok "Child streaming disabled — this machine will act as parent only."
      else
        say "Keeping the dual role (receive streams + relay up to $dest)."
      fi
      ;;

    child:child)
      title "DETECTED: this machine was ALREADY set up as CHILD"
      warn "Currently streaming to: $dest"
      say "Continuing will OVERWRITE the stream destination (new parent / new key). The old config is backed up."
      ask_yn "→ Continue?" y || return 1
      ;;

    child:parent|child:both)
      title "CAREFUL: this machine is currently a PARENT"
      warn "API key: $key"
      mh="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
      [ -n "$mh" ] && warn "Nodes currently streaming here: $mh"
      say "CHILD setup will NOT disable the parent role — this machine becomes a PROXY: receiving streams and relaying to the new parent."
      say "If you meant to set up a child on a different machine (centre/VPS), you are on the ${B}WRONG MACHINE${N} — choose n."
      ask_yn "→ Do you really want this PARENT to stream up to another parent?" n || return 1
      ;;
  esac
  return 0
}

f_stream_parent() {
  title "Streaming — PARENT receives data from children"
  local cur
  cur="$(existing_parent_key || true)"
  if [ -n "$cur" ]; then
    say "stream.conf already has an API key: ${B}$cur${N}"
    ask_yn "→ Reuse this key? (existing children keep working untouched)" y && API_KEY="$cur"
  fi
  if [ -z "$API_KEY" ]; then
    if ask_yn "Generate a new API key (UUID)?" y; then
      API_KEY="$(gen_uuid)"
    else
      API_KEY="$(ask_input 'Paste API key (UUID)')"
      while ! valid_key "$API_KEY"; do
        warn "Not a valid UUID (8-4-4-4-12 hex) — likely a character got lost in the copy."
        ask_yn "→ Enter it again? (n = keep this string anyway)" y || break
        API_KEY="$(ask_input 'Paste API key (UUID)')"
      done
    fi
  fi
  ini_set "$NDDIR/stream.conf" "$API_KEY" "enabled" "yes"
  ok "Parent accepts streams with key: ${B}$API_KEY${N}"
  say "The API key is just a pairing code — traffic is already encrypted by Tailscale (WireGuard)."
}

#---- Streaming: CHILD pushes to the parent --------------------------------------
PARENT_IP=""
f_stream_child() {
  title "Streaming — CHILD pushes data to the parent"
  # Fast path: paste the pairing string printed at the end of PARENT setup
  say "If the parent was set up with this tool, ${B}paste the NDPAIR pairing string${N} — no need to type IP + key separately."
  local pair rest
  pair="$(ask_input 'Pairing string (Enter to type manually)' '' yes)"
  if [ -n "$pair" ]; then
    case "$pair" in
      NDPAIR:*:*)
        rest="${pair#NDPAIR:}"
        PARENT_IP="${rest%%:*}"
        API_KEY="${rest#*:}"
        ok "Got it: parent = $PARENT_IP · key = $API_KEY"
        ;;
      *)
        warn "Not in NDPAIR:<ip>:<key> format — falling back to manual entry."
        ;;
    esac
  fi
  if [ -z "$PARENT_IP" ] || [ -z "$API_KEY" ]; then
    if command -v tailscale >/dev/null 2>&1; then
      say "Nodes in the Tailscale mesh (pick the parent's 100.x.y.z IP):"
      tailscale status 2>/dev/null | awk '/^100\./ {printf "    %-16s %s\n", $1, $2}' | head -12
    fi
    PARENT_IP="$(ask_input 'PARENT IP (tailscale 100.x.y.z recommended)')"
    API_KEY="$(ask_input 'API key (shown during parent setup)')"
  fi
  # Validate: a child must not point at itself (wrong machine / NDPAIR pasted on the parent)
  while is_my_ip "$PARENT_IP"; do
    err "Parent IP ($PARENT_IP) is THIS VERY MACHINE — a child cannot stream to itself."
    say "The NDPAIR string must be pasted on a DIFFERENT machine (centre/VPS), not on the parent."
    PARENT_IP="$(ask_input 'Enter the PARENT IP (another machine)')"
  done
  while ! valid_key "$API_KEY"; do
    warn "API key is not a valid UUID (8-4-4-4-12 hex) — likely a character got lost in the copy."
    ask_yn "→ Enter the key again? (n = keep this string anyway)" y || break
    API_KEY="$(ask_input 'API key (UUID)')"
  done
  # Pre-flight: attempt a TCP handshake to the parent before writing config
  if timeout 3 bash -c "exec 3<>/dev/tcp/$PARENT_IP/19999" 2>/dev/null; then
    ok "Reached $PARENT_IP:19999."
  else
    warn "COULD NOT reach $PARENT_IP:19999 — writing config anyway; check that the parent is running & the firewall."
  fi
  ini_set "$NDDIR/stream.conf" "stream" "enabled"     "yes"
  ini_set "$NDDIR/stream.conf" "stream" "destination" "$PARENT_IP:19999"
  ini_set "$NDDIR/stream.conf" "stream" "api key"     "$API_KEY"
  ok "Child will stream all metrics to $PARENT_IP:19999 after restart."
}

#---- Bind & health -----------------------------------------------------------
f_bind_local() {
  title "Lock the Web UI to localhost"
  ini_set "$NDDIR/netdata.conf" "web" "bind to" "127.0.0.1"
  ok "Port 19999 listens on 127.0.0.1 only — unreachable from outside (a must on a VPS)."
}

f_bind_parent_ts() {
  title "Parent listens on 127.0.0.1 + Tailscale IP only"
  local ts
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  if [ -z "$ts" ]; then
    warn "Could not get a tailscale IP (tailscale not installed/up) — skipping."
    return 1
  fi
  ini_set "$NDDIR/netdata.conf" "web" "bind to" "127.0.0.1 $ts"
  ok "Parent listening on 127.0.0.1 and $ts."
  warn "Boot-order note: if tailscaled comes up AFTER netdata, netdata cannot bind $ts until restarted."
}

f_health_off() {
  title "Disable local alerts on the child"
  ini_set "$NDDIR/netdata.conf" "health" "enabled" "no"
  ok "Child health engine = off — the parent handles alerts for this node, no duplicate notifications."
}

#---- UFW ----------------------------------------------------------------------
f_ufw() {
  title "UFW — open 19999 on the tailscale0 interface"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not installed — skipping."
    return 1
  fi
  if ! LANG=C ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw is inactive — skipping (no rule needed)."
    return 1
  fi
  if ufw allow in on tailscale0 to any port 19999 proto tcp >/dev/null 2>&1; then
    ok "Allowed in on tailscale0 → 19999/tcp (only the Tailscale mesh gets in)."
  else
    warn "Adding the ufw rule failed — run manually: ufw allow in on tailscale0 to any port 19999 proto tcp"
  fi
}

#===============================================================================
#  FEATURE TOGGLE MENU
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

feat_menu() {
  crumb_push "Select features"
  local i k mark sel msg=""
  while true; do
    ui_header
    title "Features — type a number to toggle · Enter to apply"
    echo
    i=1
    for k in "${FEAT_KEYS[@]}"; do
      if [ -n "${FEAT_LOCK[$k]}" ]; then
        printf "  ${D}%2d${N}  ${Y}[–]${N} ${D}%s — %s${N}\n" "$i" "${FEAT_LABEL[$k]}" "${FEAT_LOCK[$k]}"
      else
        if [ "${FEAT_ON[$k]}" = 1 ]; then
          mark="${G}[✓]${N}"
        else
          mark="${D}[ ]${N}"
        fi
        printf "  ${C}%2d${N}  %s %s" "$i" "$mark" "${FEAT_LABEL[$k]}"
        [ -n "${FEAT_NOTE[$k]}" ] && printf "  ${D}(%s)${N}" "${FEAT_NOTE[$k]}"
        printf '\n'
      fi
      i=$((i+1))
    done
    echo
    [ -n "$msg" ] && { warn "$msg"; msg=""; }
    read -rp "  ${C}❯${N} Number to toggle, Enter to apply: " sel
    [ -z "$sel" ] && break
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#FEAT_KEYS[@]}" ]; then
      k="${FEAT_KEYS[$((sel-1))]}"
      if [ -n "${FEAT_LOCK[$k]}" ]; then
        msg="Item $sel is locked: ${FEAT_LOCK[$k]}"
      else
        FEAT_ON[$k]=$((1 - FEAT_ON[$k]))
      fi
    else
      msg="Enter a number 1-${#FEAT_KEYS[@]} or press Enter"
    fi
  done
  crumb_pop
  ui_header
}

feat_common_add() { # shared features — built DYNAMICALLY from hw_scan results
  hw_scan

  local sens_on=1 sens_note=""
  if [ "$VIRT" != "none" ]; then
    sens_on=0
    sens_note="VM ($VIRT) — usually has no real sensors"
  elif [ "$HW_GPU_AMD" = 1 ]; then
    sens_note="includes AMD GPU temp/power (amdgpu hwmon)"
  fi
  feat_add sensors "$sens_on" "CPU/NVMe/mainboard temperature (lm-sensors)" "$sens_note"

  case "$(nvidia_state)" in
    driver) feat_add nvidia 1 "NVIDIA GPU (temperature, VRAM, power)" "nvidia-smi detected" ;;
    gpu)    feat_add nvidia 1 "NVIDIA GPU (temperature, VRAM, power)" "NO driver yet — the tool will offer to install" ;;
    none)   feat_add nvidia 0 "NVIDIA GPU" "" "no NVIDIA GPU detected" ;;
  esac

  # Only shown when the hardware actually exists — keeps the menu tidy
  [ "$HW_GPU_INTEL" = 1 ] \
    && feat_add igpu 1 "Intel iGPU (engine busy, freq, power)" "tool installs intel-gpu-tools"

  if [ "$HW_PHYS_DISK" = 1 ]; then
    feat_add smart 1 "S.M.A.R.T. disk health" "$HW_DISKS"
  else
    local smart_lock="no physical disk found"
    [ "$VIRT" != "none" ] && smart_lock="VM — virtual disks have no SMART"
    feat_add smart 0 "S.M.A.R.T. disk health" "" "$smart_lock"
  fi

  [ "$HW_IPMI" = 1 ] && feat_add ipmi 1 "IPMI sensors (BMC)" "/dev/ipmi detected"
  [ "$HW_UPS"  = 1 ] && feat_add ups  1 "UPS via NUT (upsd)" "upsd is running"

  local dk_note="docker NOT installed — the tool will offer to install"
  command -v docker >/dev/null 2>&1 && dk_note="docker present"
  feat_add docker 1 "Docker containers (names + state + resources)" "$dk_note"

  feat_add ping 1 "Internet ping (1.1.1.1, 8.8.8.8) — latency & outages"
  feat_add sysd 1 "Systemd services state (*.service)"
  feat_add ebpf 1 "eBPF per-process CPU/disk/network/memory" "kernel ≥ 4.15"
  feat_add netview 1 "Network viewer (per-process socket connections)"
  feat_add portcheck 0 "Port check (watch ports 80/443/DNS)"
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
  title "Restarting Netdata"
  systemctl restart netdata
  if wait_api; then
    ok "Netdata is running: v$(nd_api /api/v1/info | grep -o '"version":"[^"]*"' | cut -d'"' -f4)"
  else
    err "Netdata API unresponsive after 30s — see: journalctl -u netdata -n 50"
  fi
}

post_tg_test() {
  title "Telegram test (no need to wait for a real incident)"
  local an=""
  for an in /usr/libexec/netdata/plugins.d/alarm-notify.sh \
            /usr/lib/netdata/plugins.d/alarm-notify.sh \
            /opt/netdata/usr/libexec/netdata/plugins.d/alarm-notify.sh; do
    [ -x "$an" ] && break
    an=""
  done
  if [ -z "$an" ]; then
    warn "alarm-notify.sh not found — test manually later."
    return 1
  fi
  su -s /bin/bash netdata -c "$an test" 2>&1 | grep -iE 'telegram|sent|ok|fail' | sed 's/^/    /'
  say "Your phone must receive 3 messages: WARNING / CRITICAL / CLEAR."
}

verify_parent() {
  title "Verifying PARENT"
  sleep 3
  local hosts ts
  hosts="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
  say "Nodes currently on this parent: ${hosts:-<not available yet — children appear after their setup>}"
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  say "Dashboard: ${B}http://${ts:-<this-machine-IP>}:19999${N}"
}

verify_child() {
  title "Verifying CHILD → PARENT"
  sleep 5
  say "Latest streaming log (seeing 'connected' means it's fine):"
  journalctl -u netdata --no-pager -n 300 2>/dev/null \
    | grep -iE 'stream|sender' | tail -5 | sed 's/^/    /' \
    || warn "Could not read the journal — check manually: journalctl -u netdata | grep -i stream"
  say "Final check: open the PARENT dashboard → the Nodes dropdown must list ${B}$(hostname)${N}."
}

summary_parent() {
  local ts pair_ip choice opts
  ts="$(tailscale ip -4 2>/dev/null | head -1)"
  
  title "PICK THE IP CHILDREN WILL CONNECT TO (PARENT)"
  say "Pick the IP children will stream their data to:"
  
  # Build the option list
  opts=()
  [ -n "$ts" ] && opts+=("$ts" "Tailscale ($ts)")
  opts+=("$(hostname -I | awk '{print $1}')" "Local IP")
  local pub; pub="$(curl -s --max-time 3 https://ifconfig.me || curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://ifconfig.co || true)"
  [ -n "$pub" ] && opts+=("$pub" "Public IP ($pub)")
  opts+=("manual" "Enter an IP manually")

  # Print the menu
  for i in $(seq 0 2 $((${#opts[@]}-1))); do
    printf "  ${C}%d${N}  %s\n" "$((i/2 + 1))" "${opts[i+1]}"
  done

  # Read the choice
  while true; do
    read -rp "  ${C}❯${N} Choose (1-$(( ${#opts[@]} / 2 ))): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $(( ${#opts[@]} / 2 )) ]; then
       local idx=$(( (choice-1)*2 ))
       pair_ip="${opts[idx]}"
       [ "$pair_ip" = "manual" ] && pair_ip="$(ask_input 'Enter IP')"
       # "Listen on 127.0.0.1 + Tailscale only" is enabled → children CANNOT reach any other IP
       if [ "${FEAT_ON[bindts]:-0}" = 1 ] && [ -n "$ts" ] && [ "$pair_ip" != "$ts" ]; then
         warn "You enabled 'listen on 127.0.0.1 + Tailscale only' — netdata does NOT listen on $pair_ip."
         if ask_yn "→ Switch to the Tailscale IP $ts? (n = keep $pair_ip, children won't be able to connect)" y; then
           pair_ip="$ts"
         fi
       fi
       break
    fi
  done

  # Store the pairing string
  if [ -n "$pair_ip" ] && [ -n "$API_KEY" ]; then
    printf 'NDPAIR:%s:%s\n' "$pair_ip" "$API_KEY" > "$NDDIR/.ndpair"
    chmod 600 "$NDDIR/.ndpair"
  fi

  title "DONE — PARENT ($(hostname))"
  printf "  ${D}•${N}  Dashboard   ${D}→${N}  http://%s:19999\n" "${ts:-<this-machine-IP>}"
  printf "  ${D}•${N}  API key     ${D}→${N}  %s\n" "${API_KEY:-<not set>}"
  printf "  ${D}•${N}  Config bkp  ${D}→${N}  %s\n" "$BACKUP_DIR"
  say "Per-NIC traffic, uptime, disk I/O, load... come built in (Netdata defaults)."
  echo
  # Pairing box — width adapts to the pairing string so it never overflows
  local pair_str="NDPAIR:${pair_ip}:${API_KEY}"
  local hint="COPY THE LINE BELOW — paste it during CHILD setup"
  local bw=$(( ${#pair_str} + 4 ))
  [ "$bw" -lt "$UI_W" ] && bw=$UI_W
  printf '  %s╭%s╮%s\n'  "$G" "$(printf '─%.0s' $(seq 1 "$bw"))" "$N"
  printf '  %s│%s %s%*s %s│%s\n' "$G" "$N" "${B}${hint}${N}" "$((bw - 2 - ${#hint}))" "" "$G" "$N"
  printf '  %s│%*s│%s\n'  "$G" "$bw" "" "$N"
  printf '  %s│%s %s%*s %s│%s\n' "$G" "$N" "${C}${B}${pair_str}${N}" "$((bw - 2 - ${#pair_str}))" "" "$G" "$N"
  printf '  %s╰%s╯%s\n'  "$G" "$(printf '─%.0s' $(seq 1 "$bw"))" "$N"
  echo
  say "Forgot to copy it? Run the tool again → menu ${C}3${N} (Status) prints this string again."
}

summary_child() {
  title "DONE — CHILD ($(hostname))"
  printf "  ${D}•${N}  Streams to  ${D}→${N}  %s:19999\n" "${PARENT_IP:-<?>}"
  printf "  ${D}•${N}  Config bkp  ${D}→${N}  %s\n" "$BACKUP_DIR"
  printf "  ${D}•${N}  Dashboard   ${D}→${N}  http://%s:19999\n" "${PARENT_IP:-<parent>}"
  say "The local Web UI is locked to 127.0.0.1 if you enabled that feature."
}

#===============================================================================
#  FLOW: PARENT
#===============================================================================
setup_parent() {
  say "PARENT = the central node: receives child streams, stores data, runs alerts (e.g. nitro)."
  WANT_TG_TEST=0; WANT_TEMP_ALERT=0; API_KEY=""

  hw_scan
  role_guard parent || { say "Cancelled — back to the menu."; return 0; }
  install_netdata || return 1

  feat_reset
  feat_common_add
  feat_add tg   1 "Telegram alerts (plus ~300 stock alerts)"
  feat_add temp 1 "Temperature alerts with custom thresholds"
  feat_add dcalert 1 "Child-disconnect alert" "stock is to:silent — must override to get Telegram"

  local ufw_on=0 ufw_note="ufw not installed"
  if command -v ufw >/dev/null 2>&1; then
    if LANG=C ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw_on=1; ufw_note="ufw is active"
    else
      ufw_note="ufw present but inactive"
    fi
  fi
  feat_add ufw "$ufw_on" "UFW: allow tailscale0 → 19999" "$ufw_note"
  feat_add bindts 0 "Listen on 127.0.0.1 + Tailscale IP only" "off by default — mind the boot order"
  feat_add ipwatch 0 "IP-watch: Telegram alert when the public IP changes (5-min cron)"

  feat_menu

  f_stream_parent || return 1
  apply_common
  [ "${FEAT_ON[tg]:-0}"      = 1 ] && f_telegram
  [ "${FEAT_ON[temp]:-0}"    = 1 ] && f_temp_alert_ask
  [ "${FEAT_ON[dcalert]:-0}" = 1 ] && f_disconnect_alert
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
  say "CHILD = a node pushing all its metrics to the parent, viewed in one place (e.g. centre, VPS)."
  API_KEY=""; PARENT_IP=""

  hw_scan
  role_guard child || { say "Cancelled — back to the menu."; return 0; }
  install_netdata || return 1

  feat_reset
  feat_common_add
  feat_add bindloc 1 "Lock the Web UI to 127.0.0.1" "a must on a public VPS"
  feat_add hoff    1 "Disable local alerts" "the parent alerts for this node — avoids duplicates"
  feat_add ipwatch 0 "IP-watch: Telegram alert when the public IP changes (5-min cron)"

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
#  STATUS & REMOVAL
#===============================================================================
do_status() {
  hw_scan force
  title "Netdata"
  if ! netdata_installed; then
    warn "Netdata (native build) is not installed on this machine."
    diagnose_port19999
  else
    if systemctl is-active netdata >/dev/null 2>&1; then
      ok "netdata service: active — $(netdata_version)"
    else
      err "netdata service: $(systemctl is-active netdata 2>/dev/null)"
    fi
    say "Listening on:"
    ss -tlnp 2>/dev/null | awk '/:19999/ {print "  " $4}' | sort -u

    # CHILD role?
    local sen sdest
    sen="$(ini_get "$NDDIR/stream.conf" stream enabled)"
    sdest="$(ini_get "$NDDIR/stream.conf" stream destination)"
    if [ "$sen" = "yes" ] && [ -n "$sdest" ]; then
      say "Role CHILD → streaming to $sdest"
      journalctl -u netdata --no-pager -n 300 2>/dev/null \
        | grep -iE 'stream|sender' | tail -3 | sed 's/^/  /'
    fi
    # PARENT role?
    local pk mh
    pk="$(existing_parent_key || true)"
    if [ -n "$pk" ]; then
      say "Role PARENT — API key: $pk"
      [ -f "$NDDIR/.ndpair" ] \
        && say "Child pairing string: ${C}$(cat "$NDDIR/.ndpair")${N}"
      mh="$(nd_api /api/v1/info | grep -o '"mirrored_hosts":\[[^]]*\]' || true)"
      [ -n "$mh" ] && say "Nodes: $mh"
    fi

    if command -v sensors >/dev/null 2>&1; then
      say "Temperature:"
      sensors 2>/dev/null | grep '°C' | head -4 | sed 's/^/  /'
    fi
    id -nG netdata 2>/dev/null | grep -qw docker && ok "netdata ∈ group docker"
    [ -f "$NDDIR/go.d/ping.conf" ]         && ok "ping.conf: present"
    [ -f "$NDDIR/go.d/systemdunits.conf" ] && ok "systemdunits.conf: present"
    [ -f "$NDDIR/health.d/temperature-setup.conf" ] && ok "temperature alerts: present"
    [ -f "$NDDIR/health.d/streaming.conf" ]        && ok "child-disconnect alert: present (override, to: sysadmin)"
    [ -f /etc/cron.d/ip-watch ]            && ok "ip-watch cron: present"
    if grep -q '^SEND_TELEGRAM="YES"' "$NDDIR/health_alarm_notify.conf" 2>/dev/null; then
      ok "Telegram alerts: enabled (retest: menu 5)"
    else
      say "Telegram alerts: not enabled (enable via menu 5 or PARENT setup)"
    fi
  fi

  echo
  say "Current IPs of this machine:"
  ip -4 -o addr show scope global 2>/dev/null \
    | awk '{split($4,a,"/"); printf "  %-14s %s\n", $2, a[1]}'
  local tsip pub
  tsip="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$tsip" ] && printf "  ${D}%-14s${N} %s\n" "tailscale" "$tsip"
  pub="$(curl -s --max-time 3 https://ifconfig.me || curl -s --max-time 3 https://api.ipify.org || curl -s --max-time 3 https://ifconfig.co || true)"
  [ -n "$pub" ] && printf "  ${D}%-14s${N} %s\n" "public" "$pub"
}

#---- Remove / restore -----------------------------------------------------------
SNAP_BASE="/var/backups"

snapshot_etc() { # copy ALL of /etc/netdata (incl. setup-backups) somewhere safe → prints the path
  [ -d "$NDDIR" ] || return 1
  local dest
  dest="$SNAP_BASE/netdata-etc-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$SNAP_BASE"
  cp -a "$NDDIR" "$dest" || return 1
  printf '%s' "$dest"
}

purge_snapshots() { # delete every netdata-etc-* snapshot in SNAP_BASE
  local d
  for d in "$SNAP_BASE"/netdata-etc-*/; do
    [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}

latest_snapshot() { # newest snapshot (glob sorts ascending by timestamp)
  local d last=""
  for d in "$SNAP_BASE"/netdata-etc-*/; do [ -d "$d" ] && last="$d"; done
  [ -n "$last" ] || return 1
  printf '%s' "${last%/}"
}

oldest_backup_of() { # $1=file → prints the OLDEST backup path (= the original before the tool touched it)
  local rel d
  rel="$(printf '%s' "${1#/}" | tr '/' '_')"
  for d in "$NDDIR"/setup-backups/*/; do   # glob sorts ascending by timestamp
    [ -f "$d$rel" ] && { printf '%s' "$d$rel"; return 0; }
  done
  return 1
}

restore_or_remove() { # backup exists → restore the original; none → file was tool-created → delete
  local f="$1" b
  if b="$(oldest_backup_of "$f")"; then
    cp -a "$b" "$f"
    ok "Original restored: $f"
  elif [ -f "$f" ]; then
    rm -f "$f"
    ok "Deleted (tool-created file): $f"
  fi
}

remove_ipwatch() {
  if [ -f /etc/cron.d/ip-watch ] || [ -f /usr/local/bin/ip-watch.sh ]; then
    rm -f /etc/cron.d/ip-watch /usr/local/bin/ip-watch.sh /var/tmp/last_public_ip
    ok "ip-watch removed (cron + script + state)."
  else
    say "ip-watch is not present on this machine."
  fi
}

remove_tool_configs() {
  title "Remove tool-made configs — KEEP Netdata"
  say "Configs return to their exact state BEFORE the tool's first run (from the oldest backups)."
  ask_yn "Continue?" n || return 0
  local f
  for f in "$NDDIR/stream.conf" "$NDDIR/netdata.conf" "$NDDIR/go.d.conf" \
           "$NDDIR/health_alarm_notify.conf" "$NDDIR/go.d/ping.conf" \
           "$NDDIR/go.d/systemdunits.conf" "$NDDIR/health.d/temperature-setup.conf" \
           "$NDDIR/health.d/streaming.conf"; do
    restore_or_remove "$f"
  done
  rm -f "$NDDIR/.ndpair"
  remove_ipwatch
  command -v ufw >/dev/null 2>&1 \
    && ufw delete allow in on tailscale0 to any port 19999 proto tcp >/dev/null 2>&1
  if systemctl restart netdata 2>/dev/null; then
    ok "Netdata restarted with the restored configs."
  fi
  if ask_yn "→ Also delete the backup directory ($NDDIR/setup-backups)?" n; then
    rm -rf "$NDDIR/setup-backups"
    ok "Backups deleted — the current config is now the final state."
  else
    say "Backups kept intact at $NDDIR/setup-backups/ — nothing lost."
  fi
}

purge_netdata_residuals() { # sweep everywhere Netdata ever touched — wipe all leftovers
  local p n=0
  for p in /etc/netdata /var/lib/netdata /var/cache/netdata /var/log/netdata \
           /usr/libexec/netdata /usr/lib/netdata /usr/share/netdata \
           /etc/cron.daily/netdata-updater /etc/cron.d/netdata-updater \
           /etc/logrotate.d/netdata \
           /etc/systemd/system/netdata.service \
           /etc/systemd/system/netdata-updater.service \
           /etc/systemd/system/netdata-updater.timer; do
    [ -e "$p" ] || continue
    rm -rf "$p" && { n=$((n+1)); say "  cleaned: $p"; }
  done
  for p in /etc/apt/sources.list.d/netdata* /usr/share/keyrings/netdata*; do
    [ -e "$p" ] || continue
    rm -f "$p" && { n=$((n+1)); say "  cleaned: $p"; }
  done
  # config packages dpkg still remembers (rc state)
  if command -v dpkg >/dev/null 2>&1; then
    local rcs
    rcs="$(dpkg -l 'netdata*' 2>/dev/null | awk '/^rc/{print $2}' | tr '\n' ' ')"
    if [ -n "${rcs// /}" ]; then
      # shellcheck disable=SC2086
      apt-get purge -y $rcs >/dev/null 2>&1 && say "  purged config packages: $rcs"
    fi
  fi
  # leftover system user/group — only when no process is still running
  if id netdata >/dev/null 2>&1 && ! pgrep -x netdata >/dev/null 2>&1; then
    userdel netdata >/dev/null 2>&1 && say "  removed the netdata user"
    groupdel netdata >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed netdata 2>/dev/null || true
  if [ "$n" -gt 0 ]; then ok "Cleaned $n leftover items."; else say "No leftover files remain."; fi
}

uninstall_netdata_full() {
  title "FULL Netdata uninstall from this machine"
  if ! netdata_installed && [ -z "$(port19999_line)" ]; then
    warn "No Netdata (native/static) and nothing on 19999 — nothing to remove."
    remove_ipwatch
    return 0
  fi
  say "The tool will scan & clean everything by itself: native build (apt), static build (/opt/netdata),"
  say "orphaned processes, leftover units/cron/logrotate/apt-repos/users — no further questions."
  ask_yn "Really uninstall Netdata?" n || return 0
  local keep=1 snap=""
  if ask_yn "→ KEEP a config snapshot in $SNAP_BASE for a later restore? (n = wipe every backup)" y; then
    snap="$(snapshot_etc || true)"
    if [ -n "$snap" ]; then
      ok "Snapshotted /etc/netdata → $snap"
    else
      warn "Snapshot failed (/etc/netdata missing?) — continuing removal."
    fi
  else
    keep=0
    warn "ALL backups & snapshots will be WIPED after removal — no way back."
    ask_yn "→ Final confirmation?" n || return 0
  fi

  say "${B}[1/5]${N} Stopping & disabling the service..."
  systemctl disable --now netdata >/dev/null 2>&1 || true

  if netdata_installed; then
    say "${B}[2/5]${N} Removing the official install (kickstart --uninstall)..."
    local ks=/var/tmp/netdata-kickstart.sh
    if download "$KICKSTART_URL" "$ks"; then
      sh "$ks" --uninstall --non-interactive || warn "kickstart returned an error — cleaning up manually."
    else
      warn "Could not download kickstart — removing via apt directly."
      apt-get remove --purge -y 'netdata*' >/dev/null 2>&1 || true
    fi
  else
    say "${B}[2/5]${N} No official install left — skipping kickstart."
  fi

  say "${B}[3/5]${N} Scanning for a static build in /opt/netdata..."
  local static_un=/opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh
  if [ -x "$static_un" ]; then
    say "  static build found — removing automatically..."
    "$static_un" --yes --force || true
  fi
  if [ -d /opt/netdata ]; then
    rm -rf /opt/netdata
    ok "  /opt/netdata deleted."
  fi

  say "${B}[4/5]${N} Killing leftover processes + sweeping residue everywhere..."
  # Netdata containers (incl. host-network): pkill is useless due to restart policies — must docker rm -f
  if command -v docker >/dev/null 2>&1; then
    local cline_id cline_name cline_img
    docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null \
      | grep -i netdata | while IFS=$'\t' read -r cline_id cline_name cline_img; do
          say "  Netdata container: $cline_name ($cline_img) — docker rm -f..."
          docker rm -f "$cline_id" >/dev/null 2>&1 && ok "  container $cline_name removed"
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

  say "${B}[5/5]${N} Final check..."
  sleep 1
  local line
  line="$(port19999_line)"
  if [ -z "$line" ]; then
    ok "Port 19999 is CLEAN — no Netdata left on this machine."
  elif printf '%s' "$line" | grep -q docker-proxy; then
    warn "Netdata still lives in DOCKER — containers are separate workloads, the tool won't stop them:"
    command -v docker >/dev/null 2>&1 \
      && docker ps --filter "publish=19999" --format '    {{.Names}}  ({{.Image}})' 2>/dev/null
    say "Stop it:  docker stop <name> && docker rm <name>"
  else
    warn "A process is still holding 19999:"
    printf '    %s\n' "$line"
  fi

  if [ "$keep" = 0 ]; then
    purge_snapshots
    ok "Netdata removed and every backup/snapshot WIPED — the machine is completely clean."
  elif [ -n "$snap" ]; then
    ok "Netdata removed. The old config (incl. original backups) lives at: ${B}$snap${N}"
    say "Reinstall & restore: cp -a $snap/. /etc/netdata/ && systemctl restart netdata"
  else
    ok "Netdata removed."
  fi
}

do_tg_menu() {
  if ! netdata_installed; then
    warn "Netdata is not installed — run PARENT/CHILD setup first."
    return 0
  fi
  if grep -q '^SEND_TELEGRAM="YES"' "$NDDIR/health_alarm_notify.conf" 2>/dev/null; then
    ok "Telegram is ENABLED on this machine."
    if ask_yn "→ Send 3 test messages now (WARNING/CRITICAL/CLEAR)?" y; then
      post_tg_test
    fi
    if ask_yn "→ Change the bot token / chat ID?" n; then
      TG_TOKEN=""; TG_CHAT=""
      f_telegram
      post_tg_test
    fi
  else
    warn "Telegram is NOT configured on this machine."
    say "Note: only needed on the PARENT — children have health off, the parent alerts for them."
    ask_yn "→ Configure it now?" y || return 0
    f_telegram
    post_tg_test   # alarm-notify.sh reads the config directly — testable immediately, no restart needed
  fi
}

purge_backups() {
  title "Clean backups & snapshots"
  local d sb=0 sn=0
  if [ -d "$NDDIR/setup-backups" ]; then
    for d in "$NDDIR/setup-backups"/*/; do [ -d "$d" ] && sb=$((sb+1)); done
  fi
  for d in "$SNAP_BASE"/netdata-etc-*/; do [ -d "$d" ] && sn=$((sn+1)); done
  if [ "$sb" -eq 0 ] && [ "$sn" -eq 0 ]; then
    say "No backups/snapshots to clean — the machine is already clean."
    return 0
  fi
  say "Found: ${B}$sb${N} backups ($NDDIR/setup-backups) + ${B}$sn${N} snapshots ($SNAP_BASE)"
  warn "Deleting these LOSES the path back to the original configs — irreversible."
  ask_yn "→ Delete all of it?" n || return 0
  rm -rf "$NDDIR/setup-backups"
  purge_snapshots
  ok "All backups & snapshots cleaned out."
}

do_uninstall() {
  echo
  printf "   %s1%s  %-22s %s%s%s\n" "${C}${B}" "$N" "Full uninstall"      "$D" "kickstart --uninstall, also removes ip-watch" "$N"
  printf "   %s2%s  %-22s %s%s%s\n" "${C}${B}" "$N" "Remove tool configs" "$D" "keep Netdata, restore originals from backups" "$N"
  printf "   %s3%s  %-22s %s%s%s\n" "${C}${B}" "$N" "Remove IP-watch only" "$D" "cron + script + state" "$N"
  printf "   %s4%s  %-22s %s%s%s\n" "${C}${B}" "$N" "Clean backups"       "$D" "delete backups + snapshots in $SNAP_BASE" "$N"
  printf "   %s0%s  %-22s\n"        "${C}${B}" "$N" "Back"
  echo
  local c
  read -rp "  ${C}❯${N} Select: " c
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
  netdata-setup.sh v$TOOL_VERSION — Netdata parent/child install & configuration

  Usage:   sudo bash netdata-setup.sh

  Main menu:
    1. PARENT           — Receives child streams, central dashboard, Telegram alerts
    2. CHILD            — Streams to a parent, Web UI locked, local alerts off
    3. Status           — Service, streaming, sensors, IPs (+ NDPAIR)
    4. Remove / restore — Full uninstall / tool configs only / ip-watch only

  Parent-child pairing: PARENT setup prints an NDPAIR string; paste it into
  the first question of CHILD setup and the IP + key fill in automatically.

  Hardware is auto-scanned: NVIDIA, Intel iGPU, S.M.A.R.T., IPMI, UPS...
  Every config is backed up to /etc/netdata/setup-backups/<timestamp>/
EOF
}

main_menu() {
  CRUMBS=("Main menu")
  ui_header
  echo
  printf "   %s1%s  %-18s %s%s%s\n" "${C}${B}" "$N" "PARENT"           "$D" "Set up the central node — dashboard + centralized alerts" "$N"
  printf "   %s2%s  %-18s %s%s%s\n" "${C}${B}" "$N" "CHILD"            "$D" "Set up a node that streams its data to a parent" "$N"
  printf "   %s3%s  %-18s %s%s%s\n" "${C}${B}" "$N" "Status"           "$D" "Service · role · streaming · sensors · IPs" "$N"
  printf "   %s4%s  %-18s %s%s%s\n" "${C}${B}" "$N" "Remove / restore" "$D" "Full uninstall, or remove only tool-made configs" "$N"
  printf "   %s5%s  %-18s %s%s%s\n" "${C}${B}" "$N" "Telegram"         "$D" "Test · first-time setup · change bot" "$N"
  printf "   %s0%s  %-18s\n"        "${C}${B}" "$N" "Quit"
  echo
  local c
  read -rp "  ${C}❯${N} Select: " c
  case "$c" in
    1) run_screen "Setup PARENT"     setup_parent ;;
    2) run_screen "Setup CHILD"      setup_child ;;
    3) run_screen "Status"           do_status ;;
    4) run_screen "Remove / restore" do_uninstall ;;
    5) run_screen "Telegram alerts"  do_tg_menu ;;
    0) cls; exit 0 ;;
    *) : ;;
  esac
}

# Allow `source` for testing functions without launching the menu
(return 0 2>/dev/null) && return 0

case "${1:-}" in
  -h|--help)    usage; exit 0 ;;
  -v|--version) echo "$TOOL_VERSION"; exit 0 ;;
esac

[ "$(id -u)" -eq 0 ] || die "Root required: sudo bash $0"
if [ ! -t 0 ]; then
  if [ -r /dev/tty ]; then exec < /dev/tty; else die "This tool must run interactively (tty)."; fi
fi

detect_os
if ! command -v curl >/dev/null 2>&1; then
  warn "curl is missing (needed for API checks, Telegram, ip-watch) — installing now..."
  apt_install curl || die "Could not install curl — install manually, then re-run: apt install curl"
fi
if ! is_debian_like; then
  warn "OS: $OS_NAME — this tool targets Ubuntu/Debian; kickstart & get.docker.com still support many other distros."
fi

while true; do
  main_menu
done
