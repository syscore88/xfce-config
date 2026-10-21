#!/usr/bin/env bash
# ==========================================
# SKRYPT KONFIGURACJI WIZUALNEJ XFCE (NixOS)
# ==========================================

set -Eeuo pipefail

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
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    printf '\033[?7h' >&3
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n" >&3
        cp -f "$TMP_LOG" "$LOG_FILE" 2>/dev/null || true
        if [[ "$SCRIPT_LANG" == "pl" ]]; then
            echo -e "${ERR}✘ Wystąpił błąd (kod: $exit_code). Szczegółowy log zapisano w: $LOG_FILE${NC}" >&3
        else
            echo -e "${ERR}✘ An error occurred (code: $exit_code). Detailed log saved to: $LOG_FILE${NC}" >&3
        fi
    fi
    rm -f "$TMP_LOG"
    local do_reboot=0
    [ "$exit_code" -eq 0 ] && [ "${DO_REBOOT:-0}" = "1" ] && do_reboot=1
    if [ "${SUDO_READY:-0}" = "1" ]; then
        sudo sh -c 'rm -f "$1" "$2"; systemctl try-restart polkit 2>/dev/null; [ "$3" = 1 ] && systemctl reboot' _ \
            "${RUN0_NOPASSWD_FILE:-/etc/polkit-1/rules.d/51-run0-nopasswd.rules}" \
            "/etc/sudoers.d/99-temp-installer" \
            "$do_reboot"
    fi
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

show_progress() {
    local step=$1
    local total=$2
    local msg=$3
    local percent=$(( step * 100 / total ))

    # Szerokość terminala czytana bezpośrednio z /dev/tty
    # (stdout/stderr skryptu są przekierowane do pliku logu, więc tput by tu zawiódł)
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

printf '\033[?7h' >&3
SUDO_READY=0
if [[ "$USE_RUN0" -eq 1 ]]; then
    sudo tee "$RUN0_NOPASSWD_FILE" > /dev/null <<POLKIT_RULE_EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$CURRENT_USER") {
        return polkit.Result.YES;
    }
});
POLKIT_RULE_EOF
    sudo systemctl try-restart polkit 2>/dev/null || true
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

    SUDOERS_TMP="$(mktemp)"
    echo "$CURRENT_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
    if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
        sudo mkdir -p /etc/sudoers.d
        sudo install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/99-temp-installer
    else
        rm -f "$SUDOERS_TMP"
        log_err "Nieprawidłowa składnia reguły sudoers - przerywam." "Invalid sudoers rule syntax - aborting."
        exit 1
    fi
    rm -f "$SUDOERS_TMP"
    SUDO_READY=1
fi

printf '\033[?7l' >&3

show_progress 0 $TOTAL_STEPS "$MSG_PREP"

# ==========================================
# 3. KONFIGURACJA SYSTEMOWA (NIXOS)
# ==========================================
NIXOS_DIR="/etc/nixos"
NIXOS_CONF="$NIXOS_DIR/configuration.nix"
XFCE_MODULE="$NIXOS_DIR/xfce-visual.nix"

if [[ ! -f "$NIXOS_CONF" ]]; then
    log_err "Nie znaleziono $NIXOS_CONF." "$NIXOS_CONF not found."
    exit 1
fi

if [[ -f "$SCRIPT_DIR/piwo.png" ]]; then
    cp -af "$SCRIPT_DIR/piwo.png" "$HOME/.face" 2>/dev/null || true
    chmod 644 "$HOME/.face" 2>/dev/null || true

    AVATAR_DEST="/var/lib/AccountsService/icons/$CURRENT_USER"
    ACCOUNTS_FILE="/var/lib/AccountsService/users/$CURRENT_USER"

    sudo mkdir -p /var/lib/AccountsService/icons/ /var/lib/AccountsService/users/ || true
    sudo cp -f "$SCRIPT_DIR/piwo.png" "$AVATAR_DEST" || true
    sudo chmod 644 "$AVATAR_DEST" || true

    if [[ ! -f "$ACCOUNTS_FILE" ]]; then
        echo -e "[User]\nIcon=$AVATAR_DEST" | sudo tee "$ACCOUNTS_FILE" > /dev/null
    elif sudo grep -q "^Icon=" "$ACCOUNTS_FILE"; then
        sudo sed -i "s|^Icon=.*|Icon=$AVATAR_DEST|" "$ACCOUNTS_FILE" || true
    else
        echo "Icon=$AVATAR_DEST" | sudo tee -a "$ACCOUNTS_FILE" > /dev/null
    fi

    sudo systemctl restart accounts-daemon 2>/dev/null || true
fi

LOGIN_WALLPAPER_NIX="# brak"
if [[ -f "$SCRIPT_DIR/login-wallpaper.png" ]]; then
    sudo install -m 644 -o root -g root "$SCRIPT_DIR/login-wallpaper.png" "$NIXOS_DIR/login-wallpaper.png"
    LOGIN_WALLPAPER_NIX="services.xserver.displayManager.lightdm.background = lib.mkForce ./login-wallpaper.png;"
fi

XFCE_MODULE_TMP="$(mktemp)"
cat > "$XFCE_MODULE_TMP" <<NIX_EOF
{ config, pkgs, lib, ... }:

let
  xfcePluginNames = [
    "xfce4-whiskermenu-plugin"
    "xfce4-cpugraph-plugin"
    "xfce4-clipman-plugin"
    "xfce4-netload-plugin"
    "xfce4-weather-plugin"
    "xfce4-mount-plugin"
    "xfce4-diskperf-plugin"
    "xfce4-notes-plugin"
    "xfce4-genmon-plugin"
    "xfce4-screensaver"
  ];
  try = v: let r = builtins.tryEval v; in if r.success then r.value else null;
  lookup = n:
    let
      top = try (pkgs.\${n} or null);
      sub = try (pkgs.xfce.\${n} or null);
    in
      if lib.isDerivation top then top
      else if lib.isDerivation sub then sub
      else null;
  usable = p: p != null && !(p.meta.broken or false);
in
{
  environment.systemPackages = lib.filter usable (map lookup xfcePluginNames);

  $LOGIN_WALLPAPER_NIX
}
NIX_EOF

sudo install -m 644 -o root -g root "$XFCE_MODULE_TMP" "$XFCE_MODULE"
rm -f "$XFCE_MODULE_TMP"

sudo cp -f "$NIXOS_CONF" "$NIXOS_CONF.bak"
if ! sudo grep -q "xfce-visual.nix" "$NIXOS_CONF"; then
    if sudo grep -q "\./hardware-configuration\.nix" "$NIXOS_CONF"; then
        sudo sed -i 's|\./hardware-configuration\.nix|& ./xfce-visual.nix|' "$NIXOS_CONF"
    else
        log_err "Nie można dodać ./xfce-visual.nix do imports w $NIXOS_CONF - dodaj ręcznie." \
                "Cannot add ./xfce-visual.nix to imports in $NIXOS_CONF - add it manually."
        exit 1
    fi
fi

show_progress 1 $TOTAL_STEPS "$MSG_INSTALL"

if ! sudo nixos-rebuild switch; then
    sudo cp -f "$NIXOS_CONF.bak" "$NIXOS_CONF"
    log_err "nixos-rebuild nie powiódł się - przywrócono configuration.nix." "nixos-rebuild failed - configuration.nix restored."
    exit 1
fi

show_progress 2 $TOTAL_STEPS "$MSG_INSTALL"

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

if [[ -f "$SCRIPT_DIR/wallpaper.jpg" ]]; then
    mkdir -p "$(dirname "$wallpaper_PATH")" 2>/dev/null
    cp -af "$SCRIPT_DIR/wallpaper.jpg" "$wallpaper_PATH" 2>/dev/null || true
fi

show_progress 3 $TOTAL_STEPS "$MSG_OPTIMIZE"

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
# 6. ZAKOŃCZENIE I SPRZĄTANIE
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

show_progress 5 $TOTAL_STEPS "$MSG_OPTIMIZE"
show_progress 6 $TOTAL_STEPS "$MSG_FINALIZE"
printf '\n\n' >&3

if [[ "$SCRIPT_LANG" == "pl" ]]; then
    echo -e "${SUCCESS}✔ KONFIGURACJA ZAKOŃCZONA SUKCESEM!${NC}" >&3
else
    echo -e "${SUCCESS}✔ CONFIGURATION COMPLETED SUCCESSFULLY!${NC}" >&3
fi

DO_REBOOT=1
exit 0
