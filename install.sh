#!/usr/bin/env bash
# ===================================
# SKRYPT KONFIGURACJI WIZUALNEJ XFCE
# ===================================

set -Eeuo pipefail

FAILED_PACKAGES=()
PLUGIN_ISSUES=()
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/sbin:/sbin:$PATH"

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
    set +e
    trap - ERR
    declare -F restore_packagekit >/dev/null && restore_packagekit || true
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ] || [ "${#FAILED_PACKAGES[@]}" -gt 0 ] || [ "${#PLUGIN_ISSUES[@]}" -gt 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [ "$exit_code" -ne 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${ERR}[X] Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${ERR}[X] An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
            fi
        elif [ "${#FAILED_PACKAGES[@]}" -gt 0 ] && [ "${#PLUGIN_ISSUES[@]}" -gt 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${WARN}[!] Niektóre pakiety i wtyczki panelu sprawiły problemy. Log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${WARN}[!] Some packages and panel plugins had issues. Log saved to: $LOG_FILE${NC}" >&3
            fi
        elif [ "${#FAILED_PACKAGES[@]}" -gt 0 ]; then
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${WARN}[!] Niektóre pakiety nie zostały zainstalowane. Log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${WARN}[!] Some packages failed to install. Log saved to: $LOG_FILE${NC}" >&3
            fi
        else
            if [[ "$SCRIPT_LANG" == "pl" ]]; then
                echo -e "${WARN}[!] Brakuje niektórych wtyczek panelu XFCE. Log zapisano w: $LOG_FILE${NC}" >&3
            else
                echo -e "${WARN}[!] Some XFCE panel plugins are missing. Log saved to: $LOG_FILE${NC}" >&3
            fi
        fi
    fi
    rm -f "$TMP_LOG"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null || true; if [ "$3" = 1 ]; then systemctl reboot 2>/dev/null || reboot; fi' _ \
            "${RUN0_NOPASSWD_FILE:-/etc/polkit-1/rules.d/51-run0-nopasswd.rules}" \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot" || true
    fi
}
trap cleanup_on_exit EXIT

_pick_msg() { [[ "$SCRIPT_LANG" == "pl" ]] && echo "$1" || echo "$2"; }
_log_write() {
    echo -e "$1"
    printf '\r\033[K%b\n' "$1" >&3
    cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
}
log_info()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${INFO}==> $m${NC}"; }
log_ok()    { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${SUCCESS}[OK] $m${NC}"; }
log_err()   { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${ERR}[X] ERROR: $m${NC}"; }
log_warn()  { local m; m="$(_pick_msg "$1" "$2")"; _log_write "${WARN}[!] WARN: $m${NC}"; }

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
    pgrep -x 'apt|apt-get|dpkg|zypper|pacman|dnf|dnf5|xbps-install|packagekitd' >/dev/null 2>&1 && return 0
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
    cols=$(stty size </dev/tty 2>/dev/null || true)
    cols="${cols##* }"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=80

    local bar_width=50
    local reserved=14
    if (( cols - reserved < bar_width )); then
        bar_width=$(( cols - reserved ))
        (( bar_width < 10 )) && bar_width=10
    fi

    local overhead=$(( bar_width + reserved ))
    local avail=$(( cols - overhead ))
    if (( avail < 5 )); then avail=5; fi
    if (( ${#msg} > avail )); then
        msg="${msg:0:$((avail - 3))}..."
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
    MSG_PREP="[1/4] Przygotowywanie..."
    MSG_INSTALL="[2/4] Instalacja..."
    MSG_OPTIMIZE="[3/4] Optymalizacja..."
    MSG_FINALIZE="[4/4] Finalizowanie..."
else
    MSG_PREP="[1/4] Preparing..."
    MSG_INSTALL="[2/4] Installation..."
    MSG_OPTIMIZE="[3/4] Optimization..."
    MSG_FINALIZE="[4/4] Finalizing..."
fi

TOTAL_STEPS=7

CURRENT_USER=$(whoami)
USER_PICTURES_DIR="$(xdg-user-dir PICTURES 2>/dev/null || echo "$HOME/Pictures")"
if [[ -z "$USER_PICTURES_DIR" || "${USER_PICTURES_DIR%/}" == "${HOME%/}" ]]; then
    USER_PICTURES_DIR="$HOME/Pictures"
fi
wallpaper_PATH="$USER_PICTURES_DIR/wallpaper.jpg"
LOGIN_WALLPAPER_PATH="/usr/share/backgrounds/login-wallpaper.png"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WALIDACJA UŻYTKOWNIKA
if [[ "$EUID" -eq 0 ]]; then
    if [[ "$SCRIPT_LANG" == "pl" ]]; then
        echo -e "${ERR}[X] Nie uruchamiaj skryptu jako root. Uruchom jako zwykły użytkownik z sudo.${NC}" >&3
    else
        echo -e "${ERR}[X] Do not run this script as root. Run as a normal user with sudo.${NC}" >&3
    fi
    exit 1
fi

# ==========================================
# 1. UPRAWNIENIA TYMCZASOWE (SUDO / POLKIT)
# ==========================================
RUN0_NOPASSWD_FILE="/etc/polkit-1/rules.d/51-run0-nopasswd.rules"
USE_RUN0=0
if command -v run0 >/dev/null 2>&1; then
    if ! command -v visudo >/dev/null 2>&1 || sudo --version 2>/dev/null | grep -qi "run0"; then
        USE_RUN0=1
    fi
fi

printf '\033[?7h' >&3
SUDO_READY=0
if [[ "$USE_RUN0" -eq 1 ]]; then
    RUN0_RULE_TMP="$(mktemp)"
    cat > "$RUN0_RULE_TMP" <<POLKIT_RULE_EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
POLKIT_RULE_EOF
    sudo mkdir -p "$(dirname "$RUN0_NOPASSWD_FILE")"
    sudo install -m 0644 -o root -g root "$RUN0_RULE_TMP" "$RUN0_NOPASSWD_FILE"
    sudo systemctl try-restart polkit 2>/dev/null || true
    rm -f "$RUN0_RULE_TMP"
    SUDO_READY=1
else
    sudo -v

    (
        set +e
        trap - ERR
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" 2>/dev/null || exit
        done
    ) &
    SUDO_KEEPALIVE_PID=$!

    if command -v visudo >/dev/null 2>&1; then
        SUDOERS_TMP="$(mktemp)"
        echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
        if sudo visudo -cf "$SUDOERS_TMP" &>/dev/null; then
            sudo mkdir -p /etc/sudoers.d
            sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
        else
            rm -f "$SUDOERS_TMP"
            log_err "Nieprawidłowa składnia reguły sudoers - przerywam." "Invalid sudoers rule syntax - aborting."
            exit 1
        fi
        rm -f "$SUDOERS_TMP"
    fi
    SUDO_READY=1
fi

printf '\033[?7l' >&3

show_progress 0 $TOTAL_STEPS "$MSG_PREP"

# ==========================================
# 2. WYKRYWANIE DYSTRYBUCJI I INSTALACJA PAKIETÓW
# ==========================================
disable_packagekit

detect_distro() {
    local id_like=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        id_like="${ID:-} ${ID_LIKE:-}"
        id_like="${id_like,,}"
    fi
    case " $id_like " in
        *arch*) echo "arch" ;;
        *void*) echo "void" ;;
        *debian*|*ubuntu*) echo "debian" ;;
        *opensuse*|*suse*) echo "opensuse" ;;
        *fedora*|*rhel*) echo "fedora" ;;
        *) echo "unknown" ;;
    esac
}
DISTRO_ID="$(detect_distro)"

pkg_installed() {
    case "$DISTRO_ID" in
        arch)            pacman -Qq "$1" &>/dev/null ;;
        void)            xbps-query "$1" &>/dev/null ;;
        fedora|opensuse) rpm -q --quiet "$1" &>/dev/null ;;
        debian)          [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" == ii* ]] ;;
        *)               return 1 ;;
    esac
}

case "$DISTRO_ID" in
    arch)
        PKG_INSTALL_CMD=(sudo pacman -S --noconfirm --needed)
        XFCE_PKGS=(mousepad ristretto evince xfce4-whiskermenu-plugin libpulse rtkit xfce4-pulseaudio-plugin xfce4-power-manager xfce4-notifyd xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-weather-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-screensaver)
        ;;
    void)
        wait_for_pkg_lock
        sudo xbps-install -Suy xbps || true
        PKG_INSTALL_CMD=(sudo xbps-install -y)
        XFCE_PKGS=(dbus elogind polkit accountsservice NetworkManager network-manager-applet btop xorg-minimal xrandr xf86-input-libinput mesa-dri xorg-server-xwayland xfce4-terminal fontconfig font-adobe-source-sans-pro font-util liberation-fonts-ttf ttf-ubuntu-font-family font-awesome dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji xdg-user-dirs adwaita-icon-theme lightdm lightdm-gtk3-greeter xfce4 xfce4-plugins ffmpegthumbnailer tumbler poppler-glib thunar-archive-plugin thunar-media-tags-plugin thunar-volman engrampa gvfs gvfs-afc gvfs-smb udisks2 polkit-gnome mousepad ristretto evince xfce4-whiskermenu-plugin pulseaudio-utils rtkit xfce4-pulseaudio-plugin xfce4-power-manager xfce4-notifyd xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-weather-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-screensaver)
        ;;
    debian)
        wait_for_pkg_lock
        sudo apt-get update -yq >/dev/null 2>&1 || true
        PKG_INSTALL_CMD=(sudo apt-get install -yq)
        XFCE_PKGS=(mousepad ristretto evince xfce4-whiskermenu-plugin pulseaudio-utils rtkit xfce4-pulseaudio-plugin xfce4-power-manager xfce4-notifyd xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-weather-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-screensaver)
        ;;
    opensuse)
        PKG_INSTALL_CMD=(sudo zypper -nq install -y)
        XFCE_PKGS=(mousepad ristretto evince pulseaudio-utils rtkit xfce4-power-manager xfce4-notifyd xfce4-screensaver xfce4-panel-plugin-whiskermenu xfce4-panel-plugin-pulseaudio xfce4-panel-plugin-cpugraph xfce4-panel-plugin-clipman xfce4-panel-plugin-netload xfce4-panel-plugin-weather xfce4-panel-plugin-mount xfce4-panel-plugin-diskperf xfce4-panel-plugin-notes xfce4-panel-plugin-genmon)
        ;;
    fedora)
        PKG_INSTALL_CMD=(sudo dnf install -yq)
        XFCE_PKGS=(mousepad ristretto evince xfce4-whiskermenu-plugin pulseaudio-utils rtkit xfce4-pulseaudio-plugin xfce4-power-manager xfce4-notifyd xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-weather-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-screensaver)
        ;;
    *)
        PKG_INSTALL_CMD=()
        XFCE_PKGS=()
        log_warn "Nierozpoznana dystrybucja ($DISTRO_ID) - pomijam instalację dodatkowych pakietów XFCE." \
                 "Unrecognized distribution ($DISTRO_ID) - skipping additional XFCE package installation."
        FAILED_PACKAGES+=(mousepad ristretto evince xfce4-whiskermenu-plugin pulseaudio-utils rtkit xfce4-pulseaudio-plugin xfce4-power-manager xfce4-notifyd xfce4-cpugraph-plugin xfce4-clipman-plugin xfce4-netload-plugin xfce4-weather-plugin xfce4-mount-plugin xfce4-diskperf-plugin xfce4-notes-plugin xfce4-genmon-plugin xfce4-screensaver)
        ;;
esac

if [[ ${#XFCE_PKGS[@]} -gt 0 ]]; then
    wait_for_pkg_lock
    for pkg in "${XFCE_PKGS[@]}"; do
        pkg_installed "$pkg" && continue
        "${PKG_INSTALL_CMD[@]}" "$pkg" || FAILED_PACKAGES+=("$pkg")
    done
fi

show_progress 1 $TOTAL_STEPS "$MSG_INSTALL"

# ==========================================
# 3. KOPIOWANIE PLIKÓW KONFIGURACYJNYCH
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

safe_copy_dir "$SCRIPT_DIR/.config" "$HOME/.config"
safe_copy_dir "$SCRIPT_DIR/.local" "$HOME/.local"
safe_copy_dir "$SCRIPT_DIR/.icons" "$HOME/.icons"
safe_copy_dir "$SCRIPT_DIR/.themes" "$HOME/.themes"

PANEL_XML="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
if [[ -f "$PANEL_XML" ]]; then
    while IFS= read -r plugin_name; do
        [[ "$plugin_name" =~ ^[A-Za-z0-9_-]+$ ]] || continue
        if [[ ! -f "/usr/share/xfce4/panel/plugins/$plugin_name.desktop" && ! -f "/usr/share/xfce4/panel-plugins/$plugin_name.desktop" ]]; then
            sed -i -E "s|(name=\"plugin-[0-9]+\" type=\"string\" value=\")$plugin_name(\")|\1separator\2|" "$PANEL_XML" || true
            PLUGIN_ISSUES+=("$plugin_name")
            _pick_msg "Brak pluginu panelu: $plugin_name (dystrybucja: $DISTRO_ID)" \
                      "Missing panel plugin: $plugin_name (distribution: $DISTRO_ID)"
        fi
    done < <(sed -nE 's|.*name="plugin-[0-9]+" type="string" value="([^"]+)".*|\1|p' "$PANEL_XML" | sort -u)
fi

if [[ -f "$SCRIPT_DIR/wallpaper.jpg" ]]; then
    mkdir -p "$(dirname "$wallpaper_PATH")" 2>/dev/null || true
    cp -af "$SCRIPT_DIR/wallpaper.jpg" "$wallpaper_PATH" 2>/dev/null || true
fi

show_progress 2 $TOTAL_STEPS "$MSG_OPTIMIZE"

command -v fc-cache >/dev/null 2>&1 && sudo fc-cache -f >/dev/null 2>&1 || true
restore_packagekit

show_progress 3 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 4. USTAWIENIE TAPETY PULPITOWEJ
# ==========================================
chmod 644 "$wallpaper_PATH" 2>/dev/null || true

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    SESSION_PID=$(pgrep -u "$CURRENT_USER" xfce4-session | head -n 1 || true)
    if [[ -n "$SESSION_PID" ]]; then
        DBUS_ADDR_FROM_ENVIRON="$(grep -z DBUS_SESSION_BUS_ADDRESS "/proc/$SESSION_PID/environ" 2>/dev/null | tr '\0' '\n' | grep ^DBUS_SESSION_BUS_ADDRESS= | cut -d= -f2- || true)"
        [[ -n "$DBUS_ADDR_FROM_ENVIRON" ]] && export DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR_FROM_ENVIRON"
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

    TARGET_MONITORS=(monitordefault monitor0)
    if command -v xrandr >/dev/null 2>&1; then
        while IFS= read -r out; do
            if [[ -n "$out" ]]; then
                TARGET_MONITORS+=("monitor$out" "$out")
            fi
        done < <(xrandr --query 2>/dev/null | awk '/ connected/{print $1}' || true)
    fi

    for mon in "${TARGET_MONITORS[@]}"; do
        for ws in workspace0 workspace1 workspace2 workspace3; do
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/last-image")
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/image-path")
            ALL_PROPS+=("/backdrop/screen0/$mon/$ws/last-single-image")
        done
        ALL_PROPS+=("/backdrop/screen0/$mon/last-image")
        ALL_PROPS+=("/backdrop/screen0/$mon/image-path")
        ALL_PROPS+=("/backdrop/screen0/$mon/last-single-image")
    done

    mapfile -t ALL_PROPS < <(printf '%s\n' "${ALL_PROPS[@]}" | sort -u)

    rm -rf "$HOME/.cache/xfce4/desktop" 2>/dev/null || true

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
fi

pkill -TERM -u "$CURRENT_USER" -x xfconfd 2>/dev/null || true
sleep 0.5

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
    sed -i -E 's|name="last-image" type="string" value="[^"]*"|name="last-image" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
    sed -i -E 's|name="image-path" type="string" value="[^"]*"|name="image-path" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
    sed -i -E 's|name="last-single-image" type="string" value="[^"]*"|name="last-single-image" type="string" value="'"$wallpaper_PATH"'"|g' "$XFCE_DESKTOP_XML" || true
fi

show_progress 4 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 5. USTAWIENIE AWATARA UŻYTKOWNIKA
# ==========================================
if [[ -f "$SCRIPT_DIR/piwo.png" ]]; then
    install -m 644 "$SCRIPT_DIR/piwo.png" "$HOME/.face" 2>/dev/null || true

    AVATAR_DEST="/var/lib/AccountsService/icons/$CURRENT_USER"
    ACCOUNTS_FILE="/var/lib/AccountsService/users/$CURRENT_USER"

    sudo mkdir -p /var/lib/AccountsService/icons /var/lib/AccountsService/users || true
    sudo install -m 644 -o root -g root "$SCRIPT_DIR/piwo.png" "$AVATAR_DEST" || true
    command -v restorecon >/dev/null 2>&1 && sudo restorecon "$AVATAR_DEST" 2>/dev/null || true

    if sudo test -f "$AVATAR_DEST"; then
        if ! sudo test -f "$ACCOUNTS_FILE"; then
            printf '[User]\nIcon=%s\n' "$AVATAR_DEST" | sudo tee "$ACCOUNTS_FILE" > /dev/null || true
        elif sudo grep -q "^Icon=" "$ACCOUNTS_FILE" 2>/dev/null; then
            sudo sed -i "s|^Icon=.*|Icon=$AVATAR_DEST|" "$ACCOUNTS_FILE" 2>/dev/null || true
        elif sudo grep -q "^\[User\]" "$ACCOUNTS_FILE" 2>/dev/null; then
            sudo sed -i "/^\[User\]/a Icon=$AVATAR_DEST" "$ACCOUNTS_FILE" 2>/dev/null || true
        else
            printf '\n[User]\nIcon=%s\n' "$AVATAR_DEST" | sudo tee -a "$ACCOUNTS_FILE" > /dev/null || true
        fi

        sudo systemctl restart accounts-daemon 2>/dev/null || true
        sleep 0.5
        if command -v busctl >/dev/null 2>&1; then
            busctl call org.freedesktop.Accounts \
                "/org/freedesktop/Accounts/User$(id -u "$CURRENT_USER" 2>/dev/null || id -u)" \
                org.freedesktop.Accounts.User SetIconFile s "$AVATAR_DEST" 2>/dev/null || true
        fi
    fi
fi

show_progress 5 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 6. KONFIGURACJA EKRANU LOGOWANIA (LIGHTDM)
# ==========================================
detect_display_manager() {
    local dm=""
    if [[ -f /etc/X11/default-display-manager ]]; then
        dm="$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null || true)" 2>/dev/null || true)"
    fi
    if [[ -z "$dm" ]] && command -v systemctl >/dev/null 2>&1; then
        dm="$(systemctl show -p Id display-manager.service 2>/dev/null | cut -d= -f2 || true)"
        dm="${dm%.service}"
    fi
    if [[ -z "$dm" ]] && command -v pgrep >/dev/null 2>&1; then
        pgrep -x lightdm >/dev/null 2>&1 && dm="lightdm" || true
    fi
    if [[ -z "$dm" || "$dm" == display-manager* ]] && [[ -e /etc/systemd/system/display-manager.service ]]; then
        dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)" .service 2>/dev/null || true)"
    fi
    if [[ -z "$dm" || "$dm" == display-manager* ]] && [[ -r /etc/sysconfig/displaymanager ]]; then
        dm="$(sed -nE 's/^DISPLAYMANAGER="?([^"# ]*)"?.*/\1/p' /etc/sysconfig/displaymanager 2>/dev/null | tail -n1 || true)"
    fi
    if [[ -z "$dm" || "$dm" == display-manager* ]] && [[ -e /etc/alternatives/default-displaymanager ]]; then
        dm="$(basename "$(readlink -f /etc/alternatives/default-displaymanager 2>/dev/null || true)" 2>/dev/null || true)"
    fi
    if [[ -z "$dm" && "$DISTRO_ID" == "void" ]] && command -v lightdm >/dev/null 2>&1; then
        dm="lightdm"
    fi
    echo "$dm"
}

set_ini_key() {
    local file="$1" section="$2" key="$3" value="$4"
    local tmp_ini
    tmp_ini="$(mktemp)"
    sudo mkdir -p "$(dirname "$file")"
    sudo touch "$file"

    sudo awk -v sec="$section" -v k="$key" -v v="$value" '
        BEGIN { in_sec = 0; found_sec = 0; updated = 0 }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            if (in_sec && !updated) {
                print k "=" v
                updated = 1
            }
            line_sec = $0
            sub(/^[[:space:]]*\[/, "", line_sec)
            sub(/\][[:space:]]*$/, "", line_sec)
            if (line_sec == sec) {
                in_sec = 1
                found_sec = 1
            } else {
                in_sec = 0
            }
            print
            next
        }
        {
            if (in_sec && $0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
                if (!updated) {
                    print k "=" v
                    updated = 1
                }
                next
            }
            print
        }
        END {
            if (!found_sec) {
                if (NR > 0) print ""
                print "[" sec "]"
                print k "=" v
            } else if (in_sec && !updated) {
                print k "=" v
            }
        }
    ' "$file" > "$tmp_ini"

    sudo install -m 644 -o root -g root "$tmp_ini" "$file"
    rm -f "$tmp_ini"
}

ACTIVE_DM="$(detect_display_manager)"
IS_LIGHTDM=0
[[ "$ACTIVE_DM" == *lightdm* ]] && IS_LIGHTDM=1

if [[ "$IS_LIGHTDM" -eq 1 ]] && [[ -f "$SCRIPT_DIR/login-wallpaper.png" ]]; then
    LOGIN_WALLPAPER_OK=1

    sudo mkdir -p "$(dirname "$LOGIN_WALLPAPER_PATH")" 2>/dev/null || LOGIN_WALLPAPER_OK=0

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        sudo install -m 644 -o root -g root "$SCRIPT_DIR/login-wallpaper.png" "$LOGIN_WALLPAPER_PATH" 2>/dev/null || LOGIN_WALLPAPER_OK=0
    fi

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        command -v restorecon >/dev/null 2>&1 && sudo restorecon "$LOGIN_WALLPAPER_PATH" 2>/dev/null || true
    fi

    if [[ "$LOGIN_WALLPAPER_OK" -eq 1 ]]; then
        CONF_FILES=()
        if [[ -d /usr/share/lightdm/lightdm.conf.d ]]; then
            while IFS= read -r -d '' f; do
                CONF_FILES+=("$f")
            done < <(find /usr/share/lightdm/lightdm.conf.d -maxdepth 1 -name '*.conf' -print0 2>/dev/null | LC_ALL=C sort -z)
        fi
        [[ -f /etc/lightdm/lightdm.conf ]] && CONF_FILES+=("/etc/lightdm/lightdm.conf")
        if [[ -d /etc/lightdm/lightdm.conf.d ]]; then
            while IFS= read -r -d '' f; do
                CONF_FILES+=("$f")
            done < <(find /etc/lightdm/lightdm.conf.d -maxdepth 1 -name '*.conf' -print0 2>/dev/null | LC_ALL=C sort -z)
        fi

        GREETER_SESSION=""
        for f in "${CONF_FILES[@]}"; do
            [[ -f "$f" ]] || continue
            line="$(sudo grep -E '^[[:space:]]*greeter-session[[:space:]]*=' "$f" 2>/dev/null | tail -n1 || true)"
            if [[ -n "$line" ]]; then
                GREETER_SESSION="${line#*=}"
            fi
        done
        GREETER_SESSION="$(echo "$GREETER_SESSION" | xargs 2>/dev/null || true)"

        if [[ -z "$GREETER_SESSION" ]] && command -v lightdm >/dev/null 2>&1; then
            GREETER_SESSION="$(sudo lightdm --show-config 2>/dev/null | grep -E 'greeter-session[[:space:]]*=' | tail -n1 | sed -E 's/.*=[[:space:]]*//' || true)"
        fi

        HAS_SLICK=0
        HAS_GTK=0
        HAS_WEBKIT=0
        [[ "$GREETER_SESSION" == *slick* ]] && HAS_SLICK=1
        [[ "$GREETER_SESSION" == *webkit2* ]] && HAS_WEBKIT=1
        [[ "$GREETER_SESSION" == *gtk* ]] && HAS_GTK=1

        if [[ "$HAS_SLICK" -eq 0 && "$HAS_GTK" -eq 0 && "$HAS_WEBKIT" -eq 0 ]]; then
            { command -v slick-greeter &>/dev/null || [[ -x /usr/lib/lightdm/lightdm-slick-greeter ]] || [[ -f /etc/lightdm/slick-greeter.conf ]]; } && HAS_SLICK=1 || true
            { command -v lightdm-webkit2-greeter &>/dev/null || [[ -f /etc/lightdm/lightdm-webkit2-greeter.conf ]]; } && HAS_WEBKIT=1 || true
            { command -v lightdm-gtk-greeter &>/dev/null || [[ -x /usr/lib/lightdm/lightdm-gtk-greeter ]] || [[ -f /etc/lightdm/lightdm-gtk-greeter.conf ]]; } && HAS_GTK=1 || true
        fi
        if [[ "$HAS_SLICK" -eq 0 && "$HAS_GTK" -eq 0 && "$HAS_WEBKIT" -eq 0 ]]; then
            HAS_GTK=1
        fi

        if [[ "$HAS_SLICK" -eq 1 ]]; then
            set_ini_key "/etc/lightdm/slick-greeter.conf" "Greeter" "background" "$LOGIN_WALLPAPER_PATH"
            set_ini_key "/etc/lightdm/slick-greeter.conf" "Greeter" "draw-user-backgrounds" "false"
            if [[ -d /etc/lightdm/slick-greeter.conf.d ]]; then
                set_ini_key "/etc/lightdm/slick-greeter.conf.d/99-custom-wallpaper.conf" "Greeter" "background" "$LOGIN_WALLPAPER_PATH"
                set_ini_key "/etc/lightdm/slick-greeter.conf.d/99-custom-wallpaper.conf" "Greeter" "draw-user-backgrounds" "false"
            fi
        fi

        if [[ "$HAS_GTK" -eq 1 ]]; then
            set_ini_key "/etc/lightdm/lightdm-gtk-greeter.conf" "greeter" "background" "$LOGIN_WALLPAPER_PATH"
            set_ini_key "/etc/lightdm/lightdm-gtk-greeter.conf" "greeter" "user-background" "false"
            set_ini_key "/etc/lightdm/lightdm-gtk-greeter.conf" "greeter" "hide-user-image" "false"
        fi

        if [[ "$HAS_WEBKIT" -eq 1 ]]; then
            set_ini_key "/etc/lightdm/lightdm-webkit2-greeter.conf" "greeter" "background" "$LOGIN_WALLPAPER_PATH"
        fi
    fi
fi

show_progress 6 $TOTAL_STEPS "$MSG_OPTIMIZE"

# ==========================================
# 7. ZAKOŃCZENIE I SPRZĄTANIE
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

show_progress 7 $TOTAL_STEPS "$MSG_FINALIZE"
printf '\n\n' >&3

if [[ ${#FAILED_PACKAGES[@]} -gt 0 ]]; then
    log_warn "Nie udało się zainstalować: ${FAILED_PACKAGES[*]}. Sprawdź log: $LOG_FILE" \
             "Failed to install: ${FAILED_PACKAGES[*]}. Check the log: $LOG_FILE"
fi

if [[ ${#PLUGIN_ISSUES[@]} -gt 0 ]]; then
    log_warn "Brakujące wtyczki panelu XFCE (zastąpiono separatorem): ${PLUGIN_ISSUES[*]}. Sprawdź log: $LOG_FILE" \
             "Missing XFCE panel plugins (replaced with separator): ${PLUGIN_ISSUES[*]}. Check the log: $LOG_FILE"
fi

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}[OK] KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}[OK] CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

if [[ "$DISTRO_ID" == "void" ]]; then
    for svc in dhcpcd wpa_supplicant; do
        if [[ -L "/var/service/$svc" ]]; then
            sudo rm -f "/var/service/$svc" || true
        fi
    done
    for svc in dbus elogind NetworkManager lightdm; do
        if [[ -d "/etc/sv/$svc" && ! -e "/var/service/$svc" ]]; then
            sudo ln -s "/etc/sv/$svc" "/var/service/$svc" || true
        fi
    done
fi

DO_REBOOT=1
exit 0
