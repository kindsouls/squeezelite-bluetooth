#!/usr/bin/env bash
# uninstall.sh — squeezelite-bluetooth uninstaller
#
# Reads the install manifest written by install.sh to know exactly what was
# installed, then removes it interactively. Falls back to known default paths
# if the manifest is missing.
#
# Usage:
#   sudo ./uninstall.sh        # interactive — prompts before sensitive removals
#   sudo ./uninstall.sh --yes  # non-interactive — auto-confirms all prompts

set -euo pipefail

MANIFEST=/var/lib/squeezelite-bluetooth/install.manifest

# Defaults used when manifest is absent
DEFAULT_SERVICES=(btspeaker-monitor bluezalsa)
DEFAULT_FILES=(
    /etc/systemd/system/bluezalsa.service
    /etc/systemd/system/btspeaker-monitor.service
    /etc/pyserver/btspeaker-monitor.py
)
DEFAULT_OWNED_DIR=/etc/pyserver
DEFAULT_USER=lms
DEFAULT_BT_CONF=/etc/bluetooth/main.conf

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
YES=false
for arg in "${@}"; do
    case "$arg" in
        --yes) YES=true ;;
        --help|-h)
            echo "Usage: sudo $0 [--yes]"
            echo
            echo "  --yes   Non-interactive: answer yes to all prompts"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

step() { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
info() { echo    "    $*"; }
die()  { echo -e "  ${RED}✗${NC}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root: sudo $0"

# ---------------------------------------------------------------------------
# Read manifest into typed arrays
# ---------------------------------------------------------------------------
declare -a M_SERVICES=()
declare -a M_FILES=()
declare -a M_OWNED_DIRS=()
declare -a M_USERS=()
declare -a M_BT_CONFS=()
M_BLUEALSA_METHOD=""
M_BLUEALSA_SRC=""
M_MANIFEST_DIR=""
M_DATE="unknown"
M_ARCH="unknown"

if [[ -f "$MANIFEST" ]]; then
    echo -e "${BOLD}Install manifest:${NC} $MANIFEST"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]]          && continue
        [[ "$line" =~ ^([^=]+)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            DATE)         M_DATE="$val" ;;
            ARCH)         M_ARCH="$val" ;;
            SERVICE)      M_SERVICES+=("$val") ;;
            FILE)         M_FILES+=("$val") ;;
            OWNED_DIR)    M_OWNED_DIRS+=("$val") ;;
            USER)         M_USERS+=("$val") ;;
            BT_AUTOPOWER) M_BT_CONFS+=("$val") ;;
            BLUEALSA)
                case "$val" in
                    apt)        M_BLUEALSA_METHOD=apt ;;
                    source:*)   M_BLUEALSA_METHOD=source; M_BLUEALSA_SRC="${val#source:}" ;;
                    preexisting) M_BLUEALSA_METHOD=preexisting ;;
                esac ;;
            MANIFEST_DIR) M_MANIFEST_DIR="$val" ;;
        esac
    done < "$MANIFEST"
    echo -e "  Installed: ${M_DATE}  |  arch: ${M_ARCH}\n"
else
    warn "No manifest at $MANIFEST — using default known paths"
    echo
    M_SERVICES=("${DEFAULT_SERVICES[@]}")
    M_FILES=("${DEFAULT_FILES[@]}")
    M_OWNED_DIRS=("$DEFAULT_OWNED_DIR")
    M_USERS=("$DEFAULT_USER")
    M_BT_CONFS=("$DEFAULT_BT_CONF")
fi

# ---------------------------------------------------------------------------
# Preview everything that will be removed
# ---------------------------------------------------------------------------
echo -e "${BOLD}The following will be removed:${NC}\n"

if [[ ${#M_SERVICES[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Services${NC} (stop + disable)"
    for s in "${M_SERVICES[@]}"; do printf "    %s.service\n" "$s"; done
    echo
fi

if [[ ${#M_FILES[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Files${NC}"
    for f in "${M_FILES[@]}"; do
        [[ -f "$f" ]] \
            && printf "    %s\n" "$f" \
            || printf "    %s  ${YELLOW}(not found)${NC}\n" "$f"
    done
    echo
fi

if [[ ${#M_OWNED_DIRS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Directories${NC} (contents shown before removal)"
    for d in "${M_OWNED_DIRS[@]}"; do
        [[ -d "$d" ]] \
            && printf "    %s/\n" "$d" \
            || printf "    %s/  ${YELLOW}(not found)${NC}\n" "$d"
    done
    echo
fi

if [[ ${#M_BT_CONFS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}Config reverts${NC}"
    for f in "${M_BT_CONFS[@]}"; do
        printf "    Remove AutoEnable=true from %s\n" "$f"
    done
    echo
fi

if [[ -n "$M_BLUEALSA_METHOD" && "$M_BLUEALSA_METHOD" != preexisting ]]; then
    echo -e "  ${BOLD}bluealsa${NC} — optional, will prompt  (installed via ${M_BLUEALSA_METHOD})"
    echo
fi

if [[ ${#M_USERS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}System users${NC} — optional, will prompt"
    for u in "${M_USERS[@]}"; do printf "    %s\n" "$u"; done
    echo
fi

# ---------------------------------------------------------------------------
# Confirmation helper
# ---------------------------------------------------------------------------
confirm() {
    local prompt="$1"
    if $YES; then
        echo -e "  ${YELLOW}⚠${NC}  ${prompt} [auto-confirmed --yes]"
        return 0
    fi
    read -rp "  ${prompt} [y/N] " ans
    [[ "${ans,,}" == "y" ]]
}

confirm "Proceed with uninstall?" || { echo "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Step 1: Stop and disable services
# ---------------------------------------------------------------------------
if [[ ${#M_SERVICES[@]} -gt 0 ]]; then
    step "Stopping and disabling services"
    for svc in "${M_SERVICES[@]}"; do
        if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            systemctl stop "${svc}.service"
            ok "Stopped ${svc}.service"
        else
            info "${svc}.service was not running"
        fi
        if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
            systemctl disable "${svc}.service"
            ok "Disabled ${svc}.service"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Step 2: Remove tracked files
# ---------------------------------------------------------------------------
if [[ ${#M_FILES[@]} -gt 0 ]]; then
    step "Removing files"
    removed_count=0
    for f in "${M_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            ok "Removed $f"
            removed_count=$((removed_count + 1))
        else
            info "Already gone: $f"
        fi
    done
    if [[ $removed_count -gt 0 ]]; then
        systemctl daemon-reload
        ok "systemctl daemon-reload"
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Handle owned directories
# ---------------------------------------------------------------------------
for d in "${M_OWNED_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    step "Directory: $d"

    # Collect remaining contents
    mapfile -d '' remaining < <(find "$d" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)

    if [[ ${#remaining[@]} -eq 0 ]]; then
        rmdir "$d"
        ok "Removed empty directory $d"
        continue
    fi

    echo "  Contents:"
    for item in "${remaining[@]}"; do
        printf "    %s\n" "$item"
    done

    # Warn if bt-devices has real device entries
    btdev_path="$d/bt-devices"
    if [[ -f "$btdev_path" ]] && grep -qE '^\[[A-Fa-f0-9:]+\]' "$btdev_path" 2>/dev/null; then
        warn "bt-devices contains configured speaker entries"
    fi
    echo

    if confirm "Remove $d and all its contents?"; then
        rm -rf "$d"
        ok "Removed $d"
    else
        warn "Kept $d"
    fi
done

# ---------------------------------------------------------------------------
# Step 4: Revert Bluetooth auto-power-on
# ---------------------------------------------------------------------------
for conf in "${M_BT_CONFS[@]}"; do
    if [[ -f "$conf" ]] && grep -q 'AutoEnable=true' "$conf" 2>/dev/null; then
        step "Reverting Bluetooth auto-power setting"
        sed -i '/^AutoEnable=true$/d' "$conf"
        ok "Removed AutoEnable=true from $conf"
    fi
done

# ---------------------------------------------------------------------------
# Step 5: Optionally remove lms user
# ---------------------------------------------------------------------------
for user in "${M_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        step "System user '$user'"
        if confirm "Remove system user '$user'?"; then
            userdel "$user" 2>/dev/null \
                || userdel --force "$user" 2>/dev/null \
                || warn "userdel failed — remove manually: userdel $user"
            ok "Removed user '$user'"
        else
            warn "Kept user '$user'"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Step 6: Optionally remove bluealsa
# ---------------------------------------------------------------------------
if [[ -n "$M_BLUEALSA_METHOD" && "$M_BLUEALSA_METHOD" != preexisting ]]; then
    if command -v bluealsa &>/dev/null; then
        step "bluealsa (installed via $M_BLUEALSA_METHOD)"
        if confirm "Remove bluealsa?"; then
            case "$M_BLUEALSA_METHOD" in
                apt)
                    apt-get remove -y bluealsa 2>/dev/null \
                        && ok "Removed bluealsa via apt" \
                        || warn "apt remove failed — try: apt-get remove bluealsa"
                    ;;
                source)
                    if [[ -n "$M_BLUEALSA_SRC" && -f "$M_BLUEALSA_SRC/build/Makefile" ]]; then
                        make -C "$M_BLUEALSA_SRC/build" uninstall 2>/dev/null \
                            && ok "Removed bluealsa (make uninstall)" \
                            || { rm -f /usr/bin/bluealsa; ok "Removed /usr/bin/bluealsa"; }
                    else
                        rm -f /usr/bin/bluealsa
                        ok "Removed /usr/bin/bluealsa"
                    fi
                    ;;
            esac
        else
            warn "Kept bluealsa"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: Remove manifest
# ---------------------------------------------------------------------------
if [[ -f "$MANIFEST" ]]; then
    rm -f "$MANIFEST"
    ok "Removed install manifest"
fi
if [[ -n "$M_MANIFEST_DIR" && -d "$M_MANIFEST_DIR" ]]; then
    rmdir "$M_MANIFEST_DIR" 2>/dev/null && ok "Removed manifest directory" || true
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
