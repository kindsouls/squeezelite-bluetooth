#!/usr/bin/env bash
# install.sh — squeezelite-bluetooth installer for Raspberry Pi
#
# Usage:
#   sudo ./install.sh              # full install
#   sudo ./install.sh --update     # redeploy files and restart services
#   sudo ./install.sh --add-device # pair a new Bluetooth speaker
#        ./install.sh --status     # show current system state (no sudo needed)
#   sudo ./install.sh --uninstall  # remove everything (delegates to uninstall.sh)

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PYSERVER_DIR=/etc/pyserver
SERVICE_DIR=/etc/systemd/system
LMS_USER=lms
BLUEALSA_SRC="$HOME/bluez-alsa"
MANIFEST_DIR=/var/lib/squeezelite-bluetooth
MANIFEST="$MANIFEST_DIR/install.manifest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set by detect_audio_backend(); override with FORCE_AUDIO_BACKEND=pipewire|bluealsa
AUDIO_BACKEND=""

# Guard: manifest_add() only writes during main() to avoid polluting on --update
WRITING_MANIFEST=false

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
err()   { echo -e "  ${RED}✗${NC}  $*" >&2; }
die()   { err "$*"; exit 1; }

manifest_add() {
    $WRITING_MANIFEST || return 0
    echo "$1" >> "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "Please run as root: sudo $0 ${1:-}"
}

check_src() {
    [[ -d "$SCRIPT_DIR/src" ]] || die "Run this script from the repo root (src/ not found)"
}

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        armv6l|armv7l) ALSA_PLUGIN_DIR=/usr/lib/arm-linux-gnueabihf/alsa-lib ;;
        aarch64)        ALSA_PLUGIN_DIR=/usr/lib/aarch64-linux-gnu/alsa-lib   ;;
        *)
            warn "Unknown architecture '$machine' — defaulting to armhf alsa path"
            ALSA_PLUGIN_DIR=/usr/lib/arm-linux-gnueabihf/alsa-lib
            ;;
    esac
    ok "Architecture: $machine  →  plugin dir: $ALSA_PLUGIN_DIR"
}

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
install_system_deps() {
    step "Installing system packages"
    apt-get update -qq
    apt-get install -y \
        pi-bluetooth bluez bluez-tools \
        squeezelite \
        libasound2-dev dh-autoreconf libortp-dev libbluetooth-dev \
        libusb-dev libglib2.0-dev libudev-dev libical-dev \
        libreadline-dev libsbc1 libsbc-dev libdbus-glib-1-dev \
        python3-dbus python3-gi \
        git build-essential
    ok "System packages installed"
}

# ---------------------------------------------------------------------------
# bluez-alsa
# ---------------------------------------------------------------------------
build_bluealsa_from_source() {
    step "Building bluez-alsa from source (takes a few minutes)"
    if [[ -d "$BLUEALSA_SRC/.git" ]]; then
        ok "Found existing clone at $BLUEALSA_SRC — pulling latest"
        git -C "$BLUEALSA_SRC" pull --ff-only
    else
        git clone https://github.com/Arkq/bluez-alsa.git "$BLUEALSA_SRC"
    fi

    cd "$BLUEALSA_SRC"
    autoreconf --install

    local build_dir="$BLUEALSA_SRC/build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    ../configure \
        --prefix=/usr \
        --disable-hcitop \
        --with-alsaplugindir="$ALSA_PLUGIN_DIR"

    make -j"$(nproc)"
    make install
    ok "bluez-alsa installed to /usr/bin/bluealsa"
    manifest_add "BLUEALSA=source:${BLUEALSA_SRC}"
}

install_bluealsa() {
    if [[ "$AUDIO_BACKEND" == pipewire ]]; then
        step "Skipping bluealsa (PipeWire backend in use)"
        manifest_add "BLUEALSA=skipped-pipewire"
        return 0
    fi

    step "Checking for bluealsa"
    if command -v bluealsa &>/dev/null; then
        ok "bluealsa already installed at $(command -v bluealsa) — skipping build"
        manifest_add "BLUEALSA=preexisting"
        return 0
    fi

    # Try apt first (available on Raspberry Pi OS Bookworm+)
    if apt-cache show bluealsa &>/dev/null 2>&1; then
        step "Installing bluealsa via apt"
        apt-get install -y bluealsa
        ok "bluealsa installed via apt"
        manifest_add "BLUEALSA=apt"
        return 0
    fi

    build_bluealsa_from_source
}

# ---------------------------------------------------------------------------
# Audio backend detection
# ---------------------------------------------------------------------------
detect_audio_backend() {
    step "Detecting audio backend"

    # Allow explicit override via environment variable
    if [[ -n "${FORCE_AUDIO_BACKEND:-}" ]]; then
        AUDIO_BACKEND="$FORCE_AUDIO_BACKEND"
        ok "Audio backend forced to: $AUDIO_BACKEND"
        manifest_add "AUDIO_BACKEND=$AUDIO_BACKEND"
        return 0
    fi

    local is_pw=false

    # WirePlumber running — manages BT audio routing under PipeWire
    pgrep -x wireplumber &>/dev/null && is_pw=true || true

    # System-level PipeWire service
    systemctl is-active --quiet pipewire.service 2>/dev/null && is_pw=true || true

    # PipeWire socket for the default Pi user (uid 1000)
    [[ -S "/run/user/1000/pipewire-0" ]] && is_pw=true || true

    if $is_pw; then
        AUDIO_BACKEND=pipewire
        ok "PipeWire detected — using PipeWire audio backend"
        warn "bluez-alsa will not be installed (not needed with PipeWire)"
        warn "squeezelite must support -o pipewire; Bookworm's packaged version does"
        warn "To override: FORCE_AUDIO_BACKEND=bluealsa sudo ./install.sh"
    else
        AUDIO_BACKEND=bluealsa
        ok "PipeWire not detected — using bluez-alsa audio backend"
        warn "To override: FORCE_AUDIO_BACKEND=pipewire sudo ./install.sh"
    fi

    manifest_add "AUDIO_BACKEND=$AUDIO_BACKEND"
}

write_backend_config() {
    printf 'AUDIO_BACKEND=%s\n' "$AUDIO_BACKEND" > "$PYSERVER_DIR/audio-backend"
    manifest_add "FILE=$PYSERVER_DIR/audio-backend"
    ok "Wrote audio-backend config: $AUDIO_BACKEND"
}

# ---------------------------------------------------------------------------
# Old-format detection
# ---------------------------------------------------------------------------
warn_if_old_format() {
    local cfg="$PYSERVER_DIR/bt-devices"
    [[ -f "$cfg" ]] || return 0
    if grep -qE '^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}=' "$cfg" 2>/dev/null; then
        warn "bt-devices is in the old MAC=Name format"
        warn "The monitor will auto-migrate it to INI format on next start"
        warn "A backup will be saved as ${cfg}.bak"
    fi
}

# ---------------------------------------------------------------------------
# Deploy files
# ---------------------------------------------------------------------------
deploy_files() {
    step "Deploying files"
    mkdir -p "$PYSERVER_DIR"
    manifest_add "OWNED_DIR=$PYSERVER_DIR"

    cp "$SCRIPT_DIR/src/etc/pyserver/btspeaker-monitor.py" "$PYSERVER_DIR/"
    manifest_add "FILE=$PYSERVER_DIR/btspeaker-monitor.py"
    ok "btspeaker-monitor.py"

    # Never overwrite an existing bt-devices that may contain real entries
    if [[ ! -f "$PYSERVER_DIR/bt-devices" ]]; then
        cp "$SCRIPT_DIR/src/etc/pyserver/bt-devices" "$PYSERVER_DIR/"
        manifest_add "FILE=$PYSERVER_DIR/bt-devices"
        ok "bt-devices (new)"
    else
        ok "bt-devices (kept existing)"
    fi

    cp "$SCRIPT_DIR/src/etc/systemd/system/bluezalsa.service"         "$SERVICE_DIR/"
    cp "$SCRIPT_DIR/src/etc/systemd/system/btspeaker-monitor.service" "$SERVICE_DIR/"
    manifest_add "FILE=$SERVICE_DIR/bluezalsa.service"
    manifest_add "FILE=$SERVICE_DIR/btspeaker-monitor.service"
    ok "systemd service files"
}

# ---------------------------------------------------------------------------
# User & permissions
# ---------------------------------------------------------------------------
create_lms_user() {
    step "Creating lms system user"
    if id "$LMS_USER" &>/dev/null; then
        ok "User '$LMS_USER' already exists"
    else
        adduser --disabled-login --no-create-home --system "$LMS_USER"
        manifest_add "USER=$LMS_USER"
        ok "User '$LMS_USER' created"
    fi

    if groups "$LMS_USER" | grep -qw audio; then
        ok "User '$LMS_USER' already in audio group"
    else
        adduser "$LMS_USER" audio
        ok "Added '$LMS_USER' to audio group"
    fi
}

set_permissions() {
    step "Setting ownership and permissions"
    chown root:root \
        "$PYSERVER_DIR/btspeaker-monitor.py" \
        "$PYSERVER_DIR/bt-devices" \
        "$SERVICE_DIR/btspeaker-monitor.service" \
        "$SERVICE_DIR/bluezalsa.service"
    chmod +x "$PYSERVER_DIR/btspeaker-monitor.py"
    ok "Permissions set"
}

# ---------------------------------------------------------------------------
# Bluetooth auto-power-on
# ---------------------------------------------------------------------------
configure_bt_autopoweron() {
    step "Configuring Bluetooth to auto-power-on after boot"
    local conf=/etc/bluetooth/main.conf
    if grep -q 'AutoEnable=true' "$conf" 2>/dev/null; then
        ok "AutoEnable already set in $conf"
        return 0
    fi
    if grep -q '^\[Policy\]' "$conf" 2>/dev/null; then
        sed -i '/^\[Policy\]/a AutoEnable=true' "$conf"
    else
        printf '\n[Policy]\nAutoEnable=true\n' >> "$conf"
    fi
    manifest_add "BT_AUTOPOWER=$conf"
    ok "AutoEnable=true added to $conf"
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
enable_services() {
    step "Enabling and starting services"
    systemctl daemon-reload

    # bluezalsa is only needed on the bluez-alsa backend
    if [[ "$AUDIO_BACKEND" == bluealsa ]]; then
        systemctl enable  bluezalsa.service
        systemctl restart bluezalsa.service
        manifest_add "SERVICE=bluezalsa"
        ok "bluezalsa.service enabled and started"
    fi

    systemctl enable  btspeaker-monitor.service
    systemctl restart btspeaker-monitor.service
    manifest_add "SERVICE=btspeaker-monitor"
    ok "btspeaker-monitor.service enabled and started"
}

verify_install() {
    step "Verifying installation"
    local all_ok=true
    for svc in bluezalsa btspeaker-monitor; do
        if systemctl is-active --quiet "${svc}.service"; then
            ok "${svc}.service is running"
        else
            warn "${svc}.service is NOT running"
            systemctl status "${svc}.service" --no-pager -l || true
            all_ok=false
        fi
    done

    if $all_ok; then
        echo
        echo -e "${GREEN}${BOLD}Installation complete!${NC}"
        echo
        echo "  Pair your first Bluetooth speaker:"
        echo "    sudo $0 --add-device"
        echo
        echo "  Check system state at any time:"
        echo "    $0 --status"
        echo
        echo "  To remove everything later:"
        echo "    sudo ./uninstall.sh"
    else
        echo
        warn "One or more services failed to start. Check the logs above."
        echo "  Troubleshoot: sudo journalctl -fu bluezalsa"
    fi
}

# ---------------------------------------------------------------------------
# Status — show current system state (no root required)
# ---------------------------------------------------------------------------
show_status() {
    echo -e "\n${BOLD}squeezelite-bluetooth status${NC}  ($(date '+%Y-%m-%d %H:%M:%S'))\n"

    # Install manifest
    if [[ -f "$MANIFEST" ]]; then
        local inst_date arch backend
        inst_date="$(grep '^DATE=' "$MANIFEST" | cut -d= -f2)"
        arch="$(grep '^ARCH=' "$MANIFEST" | cut -d= -f2)"
        backend="$(grep '^AUDIO_BACKEND=' "$MANIFEST" | cut -d= -f2)"
        echo -e "  ${BOLD}Installed:${NC} ${inst_date}  |  arch: ${arch}  |  audio: ${backend:-bluealsa}"
    else
        warn "No install manifest found — install may be incomplete"
    fi
    echo

    # Services
    echo -e "${BOLD}Services${NC}"
    for svc in bluezalsa btspeaker-monitor; do
        local state
        state="$(systemctl is-active "${svc}.service" 2>/dev/null || echo inactive)"
        if [[ "$state" == "active" ]]; then
            local since
            since="$(systemctl show "${svc}.service" \
                        --property=ActiveEnterTimestamp --value 2>/dev/null)"
            echo -e "  ${GREEN}●${NC} ${svc}  (running since ${since})"
        else
            echo -e "  ${RED}●${NC} ${svc}  [${state}]"
        fi
    done
    echo

    # Configured devices — parse INI format
    echo -e "${BOLD}Configured devices${NC}  (${PYSERVER_DIR}/bt-devices)"
    local cfg="${PYSERVER_DIR}/bt-devices"
    if [[ -f "$cfg" ]]; then
        local current_mac="" count=0
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^\[([A-Fa-f0-9:]+)\]$ ]]; then
                current_mac="${BASH_REMATCH[1]^^}"
                count=$((count + 1))
            elif [[ -n "$current_mac" && "$line" =~ ^name[[:space:]]*=[[:space:]]*(.+)$ ]]; then
                echo "  ${current_mac}  →  ${BASH_REMATCH[1]}"
            fi
        done < "$cfg"
        [[ $count -eq 0 ]] && echo "  (none — run: sudo $0 --add-device)"
    else
        echo "  (file not found — run: sudo ./install.sh)"
    fi
    echo

    # Bluetooth device connection state
    echo -e "${BOLD}Bluetooth devices${NC}  (trusted)"
    local connected=0
    while IFS= read -r dev_line; do
        [[ "$dev_line" =~ ^Device[[:space:]]+([A-Fa-f0-9:]+)[[:space:]]+(.*) ]] || continue
        local mac="${BASH_REMATCH[1]}"
        local bt_name="${BASH_REMATCH[2]}"
        if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
            echo -e "  ${GREEN}✓${NC} $mac  $bt_name"
            connected=$((connected + 1))
        else
            echo    "    $mac  $bt_name  (not connected)"
        fi
    done < <(bluetoothctl devices 2>/dev/null)
    [[ $connected -eq 0 ]] && echo "  (none connected)"
    echo

    # Running squeezelite processes
    echo -e "${BOLD}squeezelite processes${NC}"
    local sq_lines
    sq_lines="$(pgrep -a squeezelite 2>/dev/null || true)"
    if [[ -n "$sq_lines" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && echo "  $line"
        done <<< "$sq_lines"
    else
        echo "  (none running)"
    fi
    echo
}

# ---------------------------------------------------------------------------
# Device pairing wizard
# ---------------------------------------------------------------------------
add_device_wizard() {
    [[ $EUID -eq 0 ]] || die "Please run as root: sudo $0 --add-device"

    echo -e "\n${BOLD}Bluetooth Speaker Pairing Wizard${NC}\n"

    bluetoothctl power on >/dev/null

    echo "Put your speaker into pairing mode, then press Enter to start scanning..."
    read -r

    step "Scanning for 15 seconds"
    bluetoothctl scan on &
    local scan_pid=$!
    sleep 15
    kill "$scan_pid" 2>/dev/null || true
    bluetoothctl scan off >/dev/null 2>&1 || true

    echo
    echo "Recently discovered devices:"
    bluetoothctl devices 2>/dev/null | grep -v '^$' || echo "(none — try again, or check speaker pairing mode)"
    echo

    local mac
    while true; do
        read -rp "Enter MAC address (e.g. AA:BB:CC:DD:EE:FF): " mac
        mac="${mac^^}"
        [[ "$mac" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] && break
        warn "Invalid format — must be 6 hex pairs separated by colons"
    done

    step "Pairing $mac"
    bluetoothctl pair    "$mac" || warn "Pair returned an error (device may already be paired)"
    bluetoothctl trust   "$mac"
    bluetoothctl connect "$mac" || warn "Connect failed — ensure speaker is in range and powered on"

    local name
    while true; do
        read -rp "Player name for LMS (no spaces, e.g. Livingroom): " name
        name="${name// /_}"
        [[ -n "$name" ]] && break
        warn "Name cannot be empty"
    done

    local lms_addr=""
    read -rp "LMS server address (leave blank to auto-discover on LAN): " lms_addr

    local config="$PYSERVER_DIR/bt-devices"
    if grep -q "^\[${mac}\]" "$config" 2>/dev/null; then
        warn "[$mac] already in bt-devices — updating name"
        sed -i "/^\[${mac}\]/,/^\[/{s/^name[[:space:]]*=.*/name = ${name}/}" "$config"
    else
        {
            printf '\n[%s]\n' "$mac"
            printf 'name = %s\n' "$name"
            [[ -n "$lms_addr" ]] && printf 'lms = %s\n' "$lms_addr"
        } >> "$config"
    fi
    ok "Saved: $name ($mac)"

    step "Restarting btspeaker-monitor"
    systemctl restart btspeaker-monitor.service
    ok "Done!  Turn your speaker off and on again to test."
    echo
    echo "  Check status: $0 --status"
    echo "  Watch live:   sudo journalctl -fu btspeaker-monitor"
}

# ---------------------------------------------------------------------------
# Update (files only, no build)
# ---------------------------------------------------------------------------
do_update() {
    check_src
    deploy_files
    set_permissions
    warn_if_old_format
    step "Restarting services"
    systemctl daemon-reload
    systemctl restart bluezalsa.service
    systemctl restart btspeaker-monitor.service
    ok "Update complete"
}

# ---------------------------------------------------------------------------
# Uninstall — delegate to uninstall.sh
# ---------------------------------------------------------------------------
do_uninstall() {
    local uninstaller="$SCRIPT_DIR/uninstall.sh"
    if [[ -x "$uninstaller" ]]; then
        exec "$uninstaller" "${@}"
    fi
    # Fallback if uninstall.sh is missing
    warn "uninstall.sh not found — running basic removal"
    for svc in btspeaker-monitor bluezalsa; do
        systemctl stop    "${svc}.service" 2>/dev/null || true
        systemctl disable "${svc}.service" 2>/dev/null || true
        rm -f "$SERVICE_DIR/${svc}.service"
    done
    systemctl daemon-reload
    rm -rf "$PYSERVER_DIR"
    warn "The '$LMS_USER' user and bluealsa binary were NOT removed"
    ok "Basic removal complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    check_root
    check_src
    detect_arch

    # Initialise manifest (fresh on every full install)
    WRITING_MANIFEST=true
    mkdir -p "$MANIFEST_DIR"
    {
        echo "# squeezelite-bluetooth install manifest — do not edit"
        echo "DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "ARCH=$(uname -m)"
        echo "MANIFEST_DIR=$MANIFEST_DIR"
    } > "$MANIFEST"

    detect_audio_backend
    install_system_deps
    install_bluealsa
    deploy_files
    write_backend_config
    create_lms_user
    set_permissions
    warn_if_old_format
    configure_bt_autopoweron
    enable_services
    verify_install

    ok "Install manifest written to $MANIFEST"
}

case "${1:-}" in
    "")             main ;;
    --update)       check_root; check_src; do_update ;;
    --uninstall)    check_root; do_uninstall "${@:2}" ;;
    --add-device)   add_device_wizard ;;
    --status)       show_status ;;
    *)
        echo "Usage: sudo $0 [--update | --uninstall | --add-device | --status]"
        echo
        echo "  (no flag)      Full install: dependencies, bluez-alsa, files, services"
        echo "  --update       Redeploy files and restart services (no rebuild)"
        echo "  --add-device   Pair a new Bluetooth speaker and register it"
        echo "  --status       Show service state, configured and connected devices"
        echo "  --uninstall    Remove everything (delegates to uninstall.sh)"
        echo
        echo "  --status does not require sudo"
        exit 1
        ;;
esac
