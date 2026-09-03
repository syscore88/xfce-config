# 🚀 XFCE Environment Auto-Setup Script

A post-installation script (`install.sh`) that automates the process of personalizing a Linux system (with a focus on the **XFCE** desktop environment and **LightDM** display manager). It copies configuration files, applies themes, icons, wallpapers, and sets the user avatar.

---

## ✨ Features

### 🎨 Visual Configuration (User)
* **Dotfiles & config copy:** Transfers `.config`, `.local/share`, `.icons`, and `.themes` folders directly to your home directory (`~`).
* **Automatic wallpaper setup:** Copies `tapeta.jpg` to `~/Documents` and applies it as the XFCE desktop background via `xfconf-query`.
* **Path update (Username Fix):** Scans `.conf`, `.json`, and `.ini` files and automatically replaces any hardcoded paths referencing the old username (`bartek`) with your current system username.
* **User avatar:** Sets `piwo.png` as your official system avatar via `AccountsService` integration.

### ⚙️ System Configuration (Sudo)
* **Login screen (LightDM):** Copies `login-wallpaper.png` to a secure system location and sets it as the greeter background in `lightdm-gtk-greeter.conf`.
* **Sudo session keepalive:** The script requests the administrator password only once at the start, then automatically refreshes privileges in the background to prevent the process from stalling.

---

## 🔍 Prerequisites

* A Linux-based operating system (**XFCE** desktop environment recommended).
* **LightDM** display manager with `lightdm-gtk-greeter` installed.
* A user account with `sudo` privileges.

---

## 🚀 How to Run

### 1. Clone the repository or download the files
```bash
git clone https://github.com/syscore88/xfce-config.git
```

### 2. Enter the downloaded folder
```bash
cd xfce-config
```

### 3. Make the script executable
```bash
chmod +x install.sh
```

### 4. Run the script
> ⚠️ **IMPORTANT:** Run the script as a **regular user** (NOT as root/sudo). The script will ask for the administrator password at the start to configure temporary elevated privileges.

```bash
./install.sh
```

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png)](https://buymeacoffee.com/bartekszczecinski)

<img width="1280" height="800" alt="Screenshot_debian13_2026-09-03_14:04:57" src="https://github.com/user-attachments/assets/124b42f0-d6c2-4dfd-823f-cbedcc28e82d" />

If you find this project useful, leave a star! ⭐

---

## ⚠️ Important Notes

> 🚨 **AUTO-REBOOT:** Once all configurations have been successfully applied, the script will automatically reboot the machine (`systemctl reboot`) so that all changes (including LightDM and AccountsService) are properly loaded. **Save your work before running the script!**
