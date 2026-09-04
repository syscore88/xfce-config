# 🐭 XFCE Visual Configuration Script

An automated Bash shell script designed for complete visual and environment configuration of the **XFCE** desktop across popular Linux distributions. The script installs a set of useful XFCE panel plugins, copies user configurations and themes, sets the desktop wallpaper live via `xfconf-query` (with an XML fallback), sets the user avatar, and configures the LightDM login screen wallpaper for whichever greeter is detected.

The script auto-detects the system language (Polish/English) from the `LANG`/`LC_ALL` locale and prints all status messages accordingly.

---

## 🚀 Script Features

- **Automatic Linux Distribution Detection**: Support for Arch/Manjaro/EndeavourOS, Debian/Ubuntu, openSUSE/SUSE, and Fedora/RHEL, detected via `/etc/os-release`.
- **Temporary Passwordless Sudo**: Requests the admin password once at the start, then configures a temporary `NOPASSWD` rule (via `/etc/sudoers.d/`, or a `polkit`/`run0` rule on systems without `visudo`) so the rest of the script can run unattended. The rule is automatically removed at the end of the script.
- **XFCE Panel Plugins Installation**: Installs a common set of XFCE plugins: CPU Graph, Clipman, NetLoad, Mount, DiskPerf, Notes, Genmon, Wavelan, and `xfce4-screensaver`.
- **Configuration Files Sync**:
  - Copies `.config/`, `.local/`, `.icons/`, and `.themes/` folder contents into the corresponding folders in the user's home directory (skipped safely if source and destination are the same).
  - Rewrites any leftover hardcoded paths from the original author's home directory (`/home/bartek`) to the current user's home directory inside `~/.config`.
  - Temporarily pauses (`SIGSTOP`) and resumes (`SIGCONT`) the running XFCE panel/desktop/settings processes while files are copied.
- **Live Wallpaper Application**: Applies `wallpaper.jpg` to the running XFCE session via `xfconf-query` for every detected monitor/workspace property (with an `xfce4-desktop.xml` fallback when no live session is found), then restarts `xfdesktop` to show the change immediately.
- **User Avatar Setup**: Sets `~/.face`, the `AccountsService` icon, and (where available) notifies `accounts-daemon` over D-Bus so the new avatar is picked up without a restart.
- **Login Screen Wallpaper (LightDM, any greeter)**: Detects the active display manager and, if it is LightDM, auto-detects the configured greeter (Slick, GTK, or WebKit2) and writes the background wallpaper into the matching greeter's config file.
- **Cache Cleanup**: Clears XFCE desktop/panel cache, session cache, thumbnails, and icon cache, and rebuilds icon theme caches for any custom icon themes installed.
- **Progress Bar**: Displays a live progress bar across 3 phases / 6 steps.

---

## 🐧 Supported Distributions

The script identifies the OS using `/etc/os-release` (`ID` / `ID_LIKE`) and selects the corresponding package manager. The same plugin set is installed on every distribution:

| Distribution | Package Manager |
| :--- | :--- |
| **Arch Linux / Manjaro / EndeavourOS** | `pacman` |
| **Debian / Ubuntu** | `apt` (`apt-get update` runs first) |
| **openSUSE / SUSE** | `zypper` |
| **Fedora / RHEL** | `dnf` |

**Installed plugins:** `xfce4-cpugraph-plugin`, `xfce4-clipman-plugin`, `xfce4-netload-plugin`, `xfce4-mount-plugin`, `xfce4-diskperf-plugin`, `xfce4-notes-plugin`, `xfce4-genmon-plugin`, `xfce4-wavelan-plugin`, `xfce4-screensaver`.

---

## 🔍 Module Details

### 1. Permissions & Package Installation
Verifies the script is **not** run as root, requests the sudo password once, grants a temporary `NOPASSWD` rule, detects the distribution, and installs the XFCE plugin set (each package failure is ignored so the script continues).

### 2. Configuration Copy
XFCE's panel, desktop, settings daemon, and config daemon processes are paused, `.config`, `.local`, `.icons`, and `.themes` are copied from the script directory into the user's home directory, old-username paths are rewritten inside `~/.config`, and the XFCE processes are resumed.

### 3. Desktop Wallpaper
If a live XFCE session is detected, the script talks to it directly through `xfconf-query` (discovering the D-Bus session bus if needed) and sets the wallpaper property for every screen/monitor/workspace combination, including any connected monitors reported by `xrandr`, then restarts `xfdesktop`. If no live session is found, it instead writes the setting directly into `xfce4-desktop.xml`.

### 4. User Avatar (AccountsService)
`piwo.png` is copied to `~/.face` and to `/var/lib/AccountsService/icons/$USER`; `/var/lib/AccountsService/users/$USER` is created or updated with the matching `Icon=` entry, `accounts-daemon` is restarted, and the icon is additionally pushed via a `busctl` D-Bus call when available.

### 5. Login Screen Wallpaper (LightDM)
The active display manager is detected (via `/etc/X11/default-display-manager`, `systemctl`, or a running `lightdm` process). If it's LightDM, the script identifies which greeter is configured (Slick Greeter, GTK Greeter, or WebKit2 Greeter — defaulting to GTK if none can be determined) and updates that greeter's config file (`slick-greeter.conf`, `lightdm-gtk-greeter.conf`, or `lightdm-webkit2-greeter.conf`) with the background image path.

### 6. Finalization
The temporary sudo/polkit rule is removed, XFCE and thumbnail caches are cleared, and the system automatically **reboots** (`systemctl reboot`) to apply all changes.

---

 🚀 How to Run

1. Clone the repository or download the files
```bash
git clone https://github.com/syscore88/xfce-config.git
```

2. Enter the downloaded folder
```bash
cd xfce-config
```

3. Make the script executable
```bash
chmod +x install.sh
```

4. Run the script
> ⚠️ **IMPORTANT:** Run the script as a **regular user** (NOT as root/sudo). The script will ask for the administrator password at the start to configure temporary elevated privileges.

```bash
./install.sh
```
<img width="1280" height="800" alt="Screenshot_debian13_2026-09-03_14:04:57" src="https://github.com/user-attachments/assets/124b42f0-d6c2-4dfd-823f-cbedcc28e82d" />

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

If you find this project useful, leave a star! ⭐

---

## ⚠️ Important Notes

> 🚨 **AUTO-REBOOT:** Once all configurations have been successfully applied, the script will automatically reboot the machine (`systemctl reboot`) so that all changes (including LightDM and AccountsService) are properly loaded. **Save your work before running the script!**
