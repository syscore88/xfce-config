#!/bin/bash
# ==========================================
# SKRYPT KONFIGURACJI WIZUALNEJ XFCE
# ==========================================

set -Eeuo pipefail

FAILED_PACKAGES=()
export PATH="/usr/sbin:/sbin:$PATH"

# ==========================================
# 1. WYKRYWANIE JĘZYKA SYSTEMU I ZMIENNE
# ==========================================
detect_system_lang() {
    local sys_lang="${LANG:-}"
    [[ -z "$sys_lang" ]] && sys_lang="${LC_ALL:-${LC_MESSAGES:-}}"
    if [[ "$sys_lang" == pl_PL* || "$sys_lang" == pl* ]]; then
        echo "pl"
    else
        echo "en"
    fi
}
SCRIPT_LANG="$(detect_system_lang)"

INFO='\033[0;34m'
SUCCESS='\033[0;32m'
WARN='\033[0;33m'
ERR='\033[0;31m'
NC='\033[0m'

TMP_LOG="$(mktemp /tmp/install-log.XXXXXX)"
LOG_FILE="$HOME/install_error_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1
exec >>"$TMP_LOG" 2>&1

cleanup_on_exit() {
    local exit_code=$?
    [[ -n "${RUN0_NOPASSWD_FILE:-}" && -f "$RUN0_NOPASSWD_FILE" ]] && { sudo rm -f "$RUN0_NOPASSWD_FILE"; sudo systemctl try-restart polkit 2>/dev/null || true; }
    [[ -f /etc/sudoers.d/99-temp-installer ]] && sudo rm -f /etc/sudoers.d/99-temp-installer
    declare -F restore_packagekit >/dev/null && restore_packagekit || true
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        else
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${WARN}⚠ Niektóre pakiety nie zostały zainstalowane. Log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${WARN}⚠ Some packages failed to install. Log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() {
    echo -e "$1"
    echo -e "$1" >&3
}
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}✔ $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}✘ ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}⚠ WARN: $m${NC}"; }

trap 'log_err "Błąd w linii $LINENO. Polecenie: $BASH_COMMAND" "Error at line $LINENO. Command: $BASH_COMMAND"' ERR

# ==========================================================
# PACKAGEKIT + BLOKADA MENEDŻERA PAKIETÓW
# ==========================================================
PACKAGEKIT_MASKED=0
PACKAGEKIT_UNITS=(packagekit.service packagekit-offline-update.service)

disable_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] && return 0
    local kill_cmd="pkill -x packagekitd"
    command -v killall >/dev/null 2>&1 && kill_cmd="killall -q packagekitd"
    sudo bash -c "systemctl stop ${PACKAGEKIT_UNITS[*]} 2>/dev/null; $kill_cmd 2>/dev/null; systemctl mask ${PACKAGEKIT_UNITS[*]} 2>/dev/null; true"
    PACKAGEKIT_MASKED=1
}

restore_packagekit() {
    [[ "${PACKAGEKIT_MASKED:-0}" -eq 1 ]] || return 0
    sudo systemctl unmask "${PACKAGEKIT_UNITS[@]}" 2>/dev/null || true
    PACKAGEKIT_MASKED=0
}

_pkg_lock_busy() {
    local f
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
             /run/zypp.pid /var/run/zypp.pid /var/lib/pacman/db.lck \
             /var/cache/dnf/metadata_lock.pid /var/lib/rpm/.rpm.lock; do
        [[ -e "$f" ]] || continue
        sudo fuser "$f" >/dev/null 2>&1 && return 0
    done
    pgrep -x 'apt|apt-get|dpkg|zypper|pacman|dnf|dnf5|packagekitd' >/dev/null 2>&1 && return 0
    return 1
}

wait_for_pkg_lock() {
    local timeout="${1:-300}" waited=0
    disable_packagekit
    while _pkg_lock_busy; do
        if (( waited >= timeout )); then
            log_warn "Blokada menedżera pakietów trwa ponad ${timeout}s - kontynuuję mimo to." \
                     "Package manager lock held for over ${timeout}s - continuing anyway."
            break
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
}

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    local cols
    cols=$(tput cols 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

    local bar_width=50
    local reserved=12
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 1))}…"
    fi

    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar_filled=""
    local bar_empty=""
    if [ $filled -gt 0 ]; then printf -v bar_filled '%*s' "$filled" ''; bar_filled="${bar_filled// /#}"; fi
    if [ $empty -gt 0 ]; then printf -v bar_empty '%*s' "$empty" ''; bar_empty="${bar_empty// /-}"; fi

    printf "\r\033[K[\033[1;32m%s\033[0;90m%s\033[0m] %3d%% | \033[1;36m%s\033[0m" "$bar_filled" "$bar_empty" "$percent" "$msg" >&3
}

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    MSG_PREP="Przygotowywanie..."
    MSG_INSTALL="Instalacja..."
    MSG_OPTIMIZE="Optymalizacja..."
    MSG_FINALIZE="Finalizowanie..."
else
    MSG_PREP="Preparing..."
    MSG_INSTALL="Installation..."
    MSG_OPTIMIZE="Optimization..."
    MSG_FINALIZE="Finalizing..."
fi

TOTAL_STEPS=6

CURRENT_USER=$(whoami)
USER_PICTURES_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")"
wallpaper_PATH="$USER_PICTURES_DIR/wallpaper.jpg"
LOGIN_WALLPAPER_PATH="/usr/share/backgrounds/login-wallpaper.png"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WALIDACJA UŻYTKOWNIKA
if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}✘ Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3
    else
        echo -e "${ERR}✘ Do not run this script as root. Run as a normal user with sudo.${NC}" >&3
    fi
    exit 1
fi

# ==========================================
# 2. UPRAWNIENIA TYMCZASOWE (SUDO / POLKIT)
# ==========================================
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if ! command -v visudo >/dev/null 2>&1; then
    USE_RUN0=1
elif command -v run0 >/dev/null 2>&1 && sudo --version 2>/dev/null | grep -qi "run0"; then
    USE_RUN0=1
fi

(
    set +e
    trap - ERR
    while true; do
        sudo -n true 2>/dev/null
        sleep 60
        kill -0 "$$" 2>/dev/null || exit
    done
) &
SUDO_KEEPALIVE_PID=$!

if [[ "$USE_RUN0" -eq 1 ]]; then
    RUN0_RULE_TMP="$(mktemp)"
    cat > "$RUN0_RULE_TMP" <<POLKIT_RULE_EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
POLKIT_RULE_EOF
    sudo bash -c "install -m 0644 '$RUN0_RULE_TMP' '$RUN0_NOPASSWD_FILE' && { systemctl try-restart polkit 2>/dev/null || true; }"
    rm -f "$RUN0_RULE_TMP"
    sudo -n true 2>/dev/null || sudo systemctl try-restart polkit 2>/dev/null || true
else
    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    if sudo bash -c "visudo -cf '$SUDOERS_TMP' >/dev/null 2>&1 && install -m 0440 -o root -g root '$SUDOERS_TMP' /etc/sudoers.d/99-temp-installer"; then
        if ! sudo -n true 2>/dev/null; then
            log_warn "Reguła NOPASSWD zainstalowana, ale sudo nadal prosi o hasło - sprawdź 'sudo -l' (możliwa inna reguła w /etc/sudoers nadpisująca wpis z sudoers.d)." \
                     "NOPASSWD rule installed, but sudo still asks for a password - check 'sudo -l' (a rule in /etc/sudoers may be overriding the sudoers.d entry)."
        fi
    else
        rm -f "$SUDOERS_TMP"
        log_err "Nieprawidłowa składnia reguły sudoers - przerywam." "Invalid sudoers rule syntax - aborting."
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
fi

show_progress 0 $TOTAL_STEPS "$MSG_PREP"

printf '\033[?7h' >&3

printf '\033[?7l' >&3

# ==========================================
# 3. WYKRYWANIE DYSTRYBUCJI I INSTALACJA PAKIETÓW
# ==========================================
disable_packagekit

XFCE_PKGS_COMMON=(xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-wavelan-plugin xfce4-screensaver)

detect_distro() {
    local id="" id_like=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
    fi
    case " $id $id_like " in
        *arch*|*manjaro*|*endeavouros*) echo "arch" ;;
        *debian*|*ubuntu*) echo "debian" ;;
        *opensuse*|*suse*) echo "opensuse" ;;
        *fedora*|*rhel*) echo "fedora" ;;
        *) echo "unknown" ;;
    esac
}
DISTRO_ID="$(detect_distro)"

case "$DISTRO_ID" in
    arch)
        PKG_INSTALL_CMD=(sudo pacman -S --noconfirm --needed)
        XFCE_PKGS=("${XFCE_PKGS_COMMON[@]}")
        ;;
    debian)
        wait_for_pkg_lock
        sudo apt-get update -y >/dev/null 2>&1 || true
        PKG_INSTALL_CMD=(sudo apt-get install -y)
        XFCE_PKGS=("${XFCE_PKGS_COMMON[@]}")
        ;;
    opensuse)
        PKG_INSTALL_CMD=(sudo zypper --non-interactive install)
        XFCE_PKGS=("${XFCE_PKGS_COMMON[@]}")
        ;;
    fedora)
        PKG_INSTALL_CMD=(sudo dnf install -y)
        XFCE_PKGS=("${XFCE_PKGS_COMMON[@]}")
        ;;
    *)
        PKG_INSTALL_CMD=()
        XFCE_PKGS=()
        log_warn "Nierozpoznana dystrybucja ($DISTRO_ID) - pomijam instalację dodatkowych pakietów XFCE." \
                 "Unrecognized distribution ($DISTRO_ID) - skipping additional XFCE package installation."
        ;;
esac

if [[ ${#XFCE_PKGS[@]} -gt 0 ]]; then
    wait_for_pkg_lock
    for pkg in "${XFCE_PKGS[@]}"; do
        "${PKG_INSTALL_CMD[@]}" "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
    if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
        log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}. Sprawdź log: $LOG_FILE" \
                 "Failed to install: ${FAILED_PACKAGES[*]}. Check the log: $LOG_FILE"
    fi
fi

# ==========================================
# 4. KOPIOWANIE PLIKÓW KONFIGURACYJNYCH
# ==========================================
safe_copy_dir() {
    local src="$1" dst="$2"
    if [[ -d "$src" ]] && [[ "$(realpath "$src" 2>/dev/null)" != "$(realpath "$dst" 2>/dev/null)" ]]; then
        mkdir -p "$dst" 2>/dev/null || return 0
        cp -af "$src/." "$dst/" 2>/dev/null || true
    fi
    return 0
}

XFCE_COMPONENTS=(xfce4-panel xfdesktop xfsettingsd xfconfd)

stop_xfce_components() {
    for proc in "${XFCE_COMPONENTS[@]}"; do
        pkill -TERM -u "$CURRENT_USER" -x "$proc" 2>/dev/null || true
    done
    sleep 0.5
}

stop_xfce_components

safe_copy_dir "$SCRIPT_DIR/.config" ~/.config
safe_copy_dir "$SCRIPT_DIR/.local" ~/.local
safe_copy_dir "$SCRIPT_DIR/.icons" ~/.icons
safe_copy_dir "$SCRIPT_DIR/.themes" ~/.themes

show_progress 1 $TOTAL_STEPS "$MSG_INSTALL"

if [[ -f "$SCRIPT_DIR/wallpaper.jpg" ]]; then
    mkdir -p "$(dirname "$wallpaper_PATH")" 2>/dev/null
    cp -af "$SCRIPT_DIR/wallpaper.jpg" "$wallpaper_PATH" 2>/dev/null || true
fi

show_progress 2 $TOTAL_STEPS "$MSG_INSTALL"
show_progress 3 $TOTAL_STEPS "$MSG_OPTIMIZE"

restore_packagekit

# ==========================================
# 5. USTAWIENIE TAPETY PULPITOWEJ
# ==========================================
chmod 644 "$wallpaper_PATH" 2>/dev/null || true

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    SESSION_PID=$(pgrep -u "$CURRENT_USER" xfce4-session | head -n 1 || true)
    if [[ -n "$SESSION_PID" ]]; then
        DBUS_ADDR_FROM_ENVIRON="$(grep -z DBUS_SESSION_BUS_ADDRESS "/proc/$SESSION_PID/environ" 2>/dev/null | tr '\0' '\n' | grep ^DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2- || true)"
        export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR_FROM_ENVIRON"
    fi
fi
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    RUNTIME_DIR="/run/user/$(id -u "$CURRENT_USER" 2>/dev/null || id -u)"
    if [[ -S "$RUNTIME_DIR/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"
    fi
fi

USE_XFCONF=0
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v xfconf-query >/dev/null 2>&1; then
    if timeout 3 xfconf-query -c xfce4-desktop -l &>/dev/null; then
        USE_XFCONF=1
    fi
fi

if [[ "$USE_XFCONF" -eq 1 ]]; then
    mapfile -t EXISTING_PROPS < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E "last-image$|image-path$|last-single-image$" || true)

    ALL_PROPS=("${EXISTING_PROPS[@]}")

    for mon in monitordefault monitor0 monitor1 monitor2 monitor3 monitor4 monitorHDMI-1 monitorHDMI-2 monitorHDMI-A-1 monitorHDMI-A-2 monitoreDP-1 monitoreDP-2 monitorDP-1 monitorDP-2 monitorDP-3 monitorVGA-1 monitorVirtual-1 monitorXWAYLAND0; do
        for ws in workspace0 workspace1 workspace2 workspace3; do
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/last-image")
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/image-path")
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/last-single-image")
        done
        ALL_PROPS+=("/backdrop/screen0/$mon/last-image")
        ALL_PROPS+=("/backdrop/screen0/$mon/image-path")
        ALL_PROPS+=("/backdrop/screen0/$mon/last-single-image")
    done

    if command -v xrandr >/dev/null 2>&1; then
        while IFS= read -r out; do
            if [[ -n "$out" ]]; then
                for ws in workspace0 workspace1 workspace2 workspace3; do
                    ALL_PROPS+=("/backdrop/screen0/monitor$out/$ws/last-image")
                    ALL_PROPS+=("/backdrop/screen0/monitor$out/$ws/image-path")
                    ALL_PROPS+=("/backdrop/screen0/monitor$out/$ws/last-single-image")
                    ALL_PROPS+=("/backdrop/screen0/$out/$ws/last-image")
                    ALL_PROPS+=("/backdrop/screen0/$out/$ws/image-path")
                    ALL_PROPS+=("/backdrop/screen0/$out/$ws/last-single-image")
                done
                ALL_PROPS+=("/backdrop/screen0/monitor$out/last-image")
                ALL_PROPS+=("/backdrop/screen0/monitor$out/image-path")
                ALL_PROPS+=("/backdrop/screen0/monitor$out/last-single-image")
                ALL_PROPS+=("/backdrop/screen0/$out/last-image")
                ALL_PROPS+=("/backdrop/screen0/$out/image-path")
                ALL_PROPS+=("/backdrop/screen0/$out/last-single-image")
            fi
        done < <(xrandr --query 2>/dev/null | awk '/ connected/{print $1}')
    fi

    mapfile -t ALL_PROPS < <(printf '%s\n' "${ALL_PROPS[@]}" | sort -u)

    rm -rf ~/.cache/xfce4/desktop 2>/dev/null || true

    for prop in "${ALL_PROPS[@]}"; do
        [[ -z "$prop" ]] && continue
        style_prop=""
        if [[ "$prop" == *last-image ]]; then
            style_prop="${prop%last-image}image-style"
        elif [[ "$prop" == *image-path ]]; then
            style_prop="${prop%image-path}image-style"
        elif [[ "$prop" == *last-single-image ]]; then
            style_prop="${prop%last-single-image}image-style"
        fi

        timeout 3 xfconf-query -c xfce4-desktop -p "$prop" --create -t string -s "$wallpaper_PATH" 2>/dev/null \
            || timeout 3 xfconf-query -c xfce4-desktop -p "$prop" -s "$wallpaper_PATH" 2>/dev/null || true

        if [[ -n "$style_prop" ]]; then
            timeout 3 xfconf-query -c xfce4-desktop -p "$style_prop" --create -t int -s 5 2>/dev/null \
                || timeout 3 xfconf-query -c xfce4-desktop -p "$style_prop" -s 5 2>/dev/null || true
        fi
    done

    if command -v xfdesktop >/dev/null 2>&1; then
        timeout 3 xfdesktop --reload 2>/dev/null || {
            pkill -u "$CURRENT_USER" -x xfdesktop 2>/dev/null || true
            sleep 0.5
            nohup xfdesktop >/dev/null 2>&1 &
            disown
        }
    fi
fi

XFCE_DESKTOP_XML="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
mkdir -p "$(dirname "$XFCE_DESKTOP_XML")"
if [[ ! -f "$XFCE_DESKTOP_XML" ]] || ! grep -q "last-image" "$XFCE_DESKTOP_XML" 2>/dev/null; then
    cat > "$XFCE_DESKTOP_XML" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper_PATH"/>
          <property name="image-path" type="string" value="$wallpaper_PATH"/>
          <property name="last-single-image" type="string" value="$wallpaper_PATH"/>
        </property>
      </property>
      <property name="monitordefault" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="$wallpaper_PATH"/>
          <property name="image-path" type="string" value="$wallpaper_PATH"/>
          <property name="last-single-image" type="string" value="$wallpaper_PATH"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF
else
    sed -i -E 's|name="last-image" type="string" value="[^"]+"|name="last-image" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
    sed -i -E 's|name="image-path" type="string" value="[^"]+"|name="image-path" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
    sed -i -E 's|name="last-single-image" type="string" value="[^"]+"|name="last-single-image" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
fi

show_progress 4 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 6. USTAWIENIE AWATARA UŻYTKOWNIKA
# ==========================================
if [[ -f "$SCRIPT_DIR/piwo.png" ]]; then
    cp -af "$SCRIPT_DIR/piwo.png" "$HOME/.face" 2>/dev/null || true
    chmod 644 "$HOME/.face" 2>/dev/null || true

    AVATAR_DEST="/var/lib/AccountsService/icons/$CURRENT_USER"

    sudo cp -af "$SCRIPT_DIR/piwo.png" "$AVATAR_DEST" 2>/dev/null \
        && sudo chmod 644 "$AVATAR_DEST" 2>/dev/null || true

    if sudo test -f "$AVATAR_DEST"; then
        ACCOUNTS_FILE="/var/lib/AccountsService/users/$CURRENT_USER"
        if [[ -f "$ACCOUNTS_FILE" ]]; then
            if sudo grep -q "^Icon=" "$ACCOUNTS_FILE" 2>/dev/null; then
                sudo sed -i "s|^Icon=.*|Icon=$AVATAR_DEST|" "$ACCOUNTS_FILE" 2>/dev/null || true
            else
                if sudo grep -q "^\[User\]" "$ACCOUNTS_FILE" 2>/dev/null; then
                    sudo sed -i "/^\[User\]/a Icon=$AVATAR_DEST" "$ACCOUNTS_FILE" 2>/dev/null || true
                else
                    { echo "Icon=$AVATAR_DEST" | sudo tee -a "$ACCOUNTS_FILE" > /dev/null; } 2>/dev/null || true
                fi
            fi
        else
            { echo -e "[User]\nIcon=$AVATAR_DEST" | sudo tee "$ACCOUNTS_FILE" > /dev/null; } 2>/dev/null || true
        fi

        sudo systemctl restart accounts-daemon 2>/dev/null || true
        sleep 0.5
        if command -v busctl >/dev/null 2>&1; then
            busctl call org.freedesktop.Accounts \
                "/org/freedesktop/Accounts/User$(id -u "$CURRENT_USER" 2>/dev/null)" \
                org.freedesktop.Accounts.User SetIconFile s "$AVATAR_DEST" 2>/dev/null || true
        fi
    fi
fi

show_progress 5 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 7. KONFIGURACJA EKRANU LOGOWANIA (LIGHTDM)
# ==========================================
detect_display_manager() {
    local dm=""
    if [[ -f /etc/X11/default-display-manager ]]; then
        dm="$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null)")"
    fi
    if [[ -z "$dm" ]] && command -v systemctl >/dev/null 2>&1; then
        dm="$(systemctl show -p Id display-manager.service 2>/dev/null | cut -d= -f2)"
        dm="${dm%.service}"
    fi
    if [[ -z "$dm" ]] && command -v pgrep >/dev/null 2>&1; then
        pgrep -x lightdm >/dev/null 2>&1 && dm="lightdm"
    fi
    echo "$dm"
}
ACTIVE_DM="$(detect_display_manager)"
IS_LIGHTDM=0
[[ "$ACTIVE_DM" == *lightdm* ]] && IS_LIGHTDM=1

if [[ "$IS_LIGHTDM" -eq 1 ]] && [[ -f "$SCRIPT_DIR/login-wallpaper.png" ]]; then
    LOGIN_WALLPAPER_OK=1

    sudo mkdir -p /usr/share/backgrounds 2>/dev/null || LOGIN_WALLPAPER_OK=0

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        sudo cp -af "$SCRIPT_DIR/login-wallpaper.png" "$LOGIN_WALLPAPER_PATH" 2>/dev/null || LOGIN_WALLPAPER_OK=0
    fi

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        sudo chmod 644 "$LOGIN_WALLPAPER_PATH" 2>/dev/null || true
    fi

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        GREETER_SESSION="$(sudo lightdm --show-config 2>/dev/null | grep -A2 "^\[Seat:\*\]" | grep "greeter-session" | tail -n1 | sed -E 's/.*=\s*//' || true)"
        if [[ -z "$GREETER_SESSION" ]]; then
            GREETER_SESSION="$(sudo grep -rh "^greeter-session=" /etc/lightdm/ /usr/share/lightdm/lightdm.conf.d/ 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
        fi
        if command -v dpkg >/dev/null 2>&1 && [[ -z "$GREETER_SESSION" ]]; then
            dpkg -l 2>/dev/null | grep -q "^ii.*slick-greeter" && GREETER_SESSION="slick-greeter"
        fi

        HAS_SLICK=0
        HAS_GTK=0
        HAS_WEBKIT=0
        [[ "$GREETER_SESSION" == *slick* ]] && HAS_SLICK=1
        [[ "$GREETER_SESSION" == *webkit2* ]] && HAS_WEBKIT=1
        [[ "$GREETER_SESSION" == *gtk-greeter* ]] && HAS_GTK=1

        if [[ "$HAS_SLICK" -eq 0 && "$HAS_GTK" -eq 0 && "$HAS_WEBKIT" -eq 0 ]]; then
            [[ -f /etc/lightdm/slick-greeter.conf ]] && HAS_SLICK=1
            [[ -f /etc/lightdm/lightdm-webkit2-greeter.conf ]] && HAS_WEBKIT=1
            [[ -f /etc/lightdm/lightdm-gtk-greeter.conf ]] && HAS_GTK=1
        fi
        if [[ "$HAS_SLICK" -eq 0 && "$HAS_GTK" -eq 0 && "$HAS_WEBKIT" -eq 0 ]]; then
            HAS_GTK=1
        fi

        if [[ "$HAS_SLICK" -eq 1 ]]; then
            SLICK_CONF="/etc/lightdm/slick-greeter.conf"
            sudo mkdir -p "$(dirname "$SLICK_CONF")" 2>/dev/null || true
            sudo touch "$SLICK_CONF" 2>/dev/null || true
            if ! sudo grep -q "^\[Greeter\]" "$SLICK_CONF" 2>/dev/null; then
                { echo "[Greeter]" | sudo tee -a "$SLICK_CONF" > /dev/null; } 2>/dev/null || true
            fi
            if sudo grep -q "^background=" "$SLICK_CONF" 2>/dev/null; then
                sudo sed -i "s|^background=.*|background=$LOGIN_WALLPAPER_PATH|" "$SLICK_CONF" 2>/dev/null || true
            else
                sudo sed -i "/^\[Greeter\]/a background=$LOGIN_WALLPAPER_PATH" "$SLICK_CONF" 2>/dev/null || true
            fi
            if sudo grep -q "^draw-user-backgrounds=" "$SLICK_CONF" 2>/dev/null; then
                sudo sed -i "s|^draw-user-backgrounds=.*|draw-user-backgrounds=false|" "$SLICK_CONF" 2>/dev/null || true
            else
                sudo sed -i "/^\[Greeter\]/a draw-user-backgrounds=false" "$SLICK_CONF" 2>/dev/null || true
            fi
        fi

        if [[ "$HAS_GTK" -eq 1 ]]; then
            GTK_CONF="/etc/lightdm/lightdm-gtk-greeter.conf"
            sudo mkdir -p "$(dirname "$GTK_CONF")" 2>/dev/null || true
            sudo touch "$GTK_CONF" 2>/dev/null || true
            if ! sudo grep -q "^\[greeter\]" "$GTK_CONF" 2>/dev/null; then
                { echo "[greeter]" | sudo tee -a "$GTK_CONF" > /dev/null; } 2>/dev/null || true
            fi
            if sudo grep -q "^background=" "$GTK_CONF" 2>/dev/null; then
                sudo sed -i "s|^background=.*|background=$LOGIN_WALLPAPER_PATH|" "$GTK_CONF" 2>/dev/null || true
            else
                sudo sed -i "/^\[greeter\]/a background=$LOGIN_WALLPAPER_PATH" "$GTK_CONF" 2>/dev/null || true
            fi
            if sudo grep -q "^user-background=" "$GTK_CONF" 2>/dev/null; then
                sudo sed -i "s|^user-background=.*|user-background=false|" "$GTK_CONF" 2>/dev/null || true
            else
                sudo sed -i "/^\[greeter\]/a user-background=false" "$GTK_CONF" 2>/dev/null || true
            fi
        fi

        if [[ "$HAS_WEBKIT" -eq 1 ]]; then
            WEBKIT_CONF="/etc/lightdm/lightdm-webkit2-greeter.conf"
            sudo mkdir -p "$(dirname "$WEBKIT_CONF")" 2>/dev/null || true
            sudo touch "$WEBKIT_CONF" 2>/dev/null || true
            if ! sudo grep -q "^\[greeter\]" "$WEBKIT_CONF" 2>/dev/null; then
                { echo "[greeter]" | sudo tee -a "$WEBKIT_CONF" > /dev/null; } 2>/dev/null || true
            fi
            if sudo grep -q "^background=" "$WEBKIT_CONF" 2>/dev/null; then
                sudo sed -i "s|^background=.*|background=$LOGIN_WALLPAPER_PATH|" "$WEBKIT_CONF" 2>/dev/null || true
            else
                sudo sed -i "/^\[greeter\]/a background=$LOGIN_WALLPAPER_PATH" "$WEBKIT_CONF" 2>/dev/null || true
            fi
        fi
    fi
fi

# ==========================================
# 8. ZAKOŃCZENIE I SPRZĄTANIE
# ==========================================

clear_xfce_cache() {
    pkill -TERM -u "$CURRENT_USER" -x xfconfd 2>/dev/null || true
    rm -rf "$HOME/.cache/xfce4/desktop" 2>/dev/null || true
    rm -rf "$HOME/.cache/xfce4/xfce4-panel" 2>/dev/null || true
    rm -rf "$HOME/.cache/sessions" 2>/dev/null || true
    rm -rf "$HOME/.cache/thumbnails" 2>/dev/null || true
    rm -rf "$HOME/.cache/icon-cache.kcache" 2>/dev/null || true
    if command -v gtk-update-icon-cache >/dev/null 2>&1 && [[ -d "$HOME/.icons" ]]; then
        for theme_dir in "$HOME/.icons/"*/; do
            [[ -f "${theme_dir}index.theme" ]] && gtk-update-icon-cache -f -t "$theme_dir" >/dev/null 2>&1 || true
        done
    fi
}
clear_xfce_cache

show_progress 6 $TOTAL_STEPS "$MSG_FINALIZE"
echo -e "\n" >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}✔ CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

systemctl reboot
