#!/usr/bin/env bash
# 1 桌面环境前置准备：对应《02-初始化 ArchLinux》。
# 2 安装桌面环境：对应《04-桌面环境》中的 GNOME。
# 在已安装的系统中以普通用户执行：bash setup-desktop.sh；系统操作由脚本内部 sudo 提权。
# 每个函数对应独立功能步骤，系统配置使用 sudo，用户配置写入当前用户的 HOME。
set -Eeuo pipefail

STEP=启动脚本
step() { STEP="$1 $2"; printf '\n==> [%s] %s\n' "$1" "$2"; }
report_error() {
    local status=$?
    printf '\n步骤「%s」执行失败，退出码：%s。\n' "$STEP" "$status" >&2
    exit "$status"
}
trap report_error ERR

# 1 桌面环境前置准备

# 1.1 连接网络：直接访问百度，失败时交互连接 Wi-Fi。
online() {
    curl --fail --silent --show-error --location --connect-timeout 5 --max-time 10 \
        --output /dev/null https://www.baidu.com/ >/dev/null 2>&1
}

connect_network() {
    step 1.1 '连接网络'
    local iface ssid answer
    sudo systemctl start NetworkManager
    # 1.1.1 直接访问百度，成功后继续安装。
    step 1.1.1 '检测网络连接：访问百度'
    if online; then
        step 1.1.3 '确认网络连接：网络可用'
        return
    fi

    # 1.1.2 由 NetworkManager 管理无线连接，nmcli 交互读取 Wi-Fi 密码。
    step 1.1.2 '连接 Wi-Fi'
    printf '无法访问百度，请选择无线设备连接 Wi-Fi。\n'
    nmcli device status
    read -r -p '无线设备名称（例如 wlan0）：' iface
    if [[ -z $iface || $iface == */* || ! -e /sys/class/net/$iface/phy80211 ]]; then
        printf '无线设备无效。\n' >&2
        return 1
    fi
    while true; do
        # 扫描被暂时拒绝时仍可读取缓存；列表或连接失败后统一询问重试。
        if ! sudo nmcli device wifi rescan ifname "$iface"; then
            printf 'Wi-Fi 扫描请求未成功，尝试使用已有扫描结果。\n'
        fi
        if nmcli device wifi list ifname "$iface"; then
            read -r -p 'Wi-Fi 名称（SSID）：' ssid
            [[ -n $ssid ]] || continue
            printf '接下来由 nmcli 提示输入 Wi-Fi 密码，连接由 NetworkManager 保存。\n'
            if sudo nmcli --ask device wifi connect "$ssid" ifname "$iface" && online; then
                break
            fi
        fi
        read -r -p '扫描结果不可用、连接失败或无法访问网络，是否重试？[y/N]：' answer
        [[ $answer == y || $answer == Y ]] || return 1
    done
    # 1.1.3 确认联网成功后，继续执行软件包安装。
    step 1.1.3 '确认网络连接：Wi-Fi 可用'
}

# 1.2 字体：首次安装软件包前同步升级系统，再安装字体。
install_fonts() {
    step 1.2 '同步升级系统并安装字体'
    sudo pacman -Syu
    sudo pacman -S noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
}

# 1.3 32 位源：解除 multilib 节及 Include 的注释，然后同步数据库。
enable_multilib() {
    step 1.3 '启用 32 位源 multilib'
    if grep -qE '^[[:space:]]*#?[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
        sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*\[multilib\][[:space:]]*$/ {
            s/.*/[multilib]/
            n
            s|^[[:space:]]*#?[[:space:]]*Include[[:space:]]*=.*|Include = /etc/pacman.d/mirrorlist|
        }' /etc/pacman.conf
    else
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    sudo pacman -Syu
}

# 1.4 archlinuxcn 源：设置中科大与清华镜像，安装密钥并升级系统。
configure_archlinuxcn() {
    step 1.4 '配置 archlinuxcn 源'
    if grep -qE '^[[:space:]]*#?[[:space:]]*\[archlinuxcn\][[:space:]]*$' /etc/pacman.conf; then
        # 已有配置只解除本节的注释，保留原有镜像项。
        sudo sed -i -E '/^[[:space:]]*#?[[:space:]]*\[archlinuxcn\][[:space:]]*$/,/^[[:space:]]*#?[[:space:]]*\[/ {
            s/^[[:space:]]*#[[:space:]]*(\[archlinuxcn\]|Server[[:space:]]*=)/\1/
        }' /etc/pacman.conf
    else
        printf "\n[archlinuxcn]\nServer = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch\n" | sudo tee -a /etc/pacman.conf >/dev/null
    fi
    sudo pacman -Sy archlinuxcn-keyring
    sudo pacman -Syu
}

# 1.5 AUR：安装编译工具以及 yay、paru 两个助手。
install_aur_helpers() {
    step 1.5 '安装 AUR 助手：yay、paru'
    sudo pacman -S --needed base-devel yay paru
}

# 1.6 Flatpak：安装软件，将 Flathub 切换为上交大镜像。
install_flatpak() {
    step 1.6 '安装 Flatpak 并配置上交大镜像'
    sudo pacman -S flatpak
    sudo flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub
}

# 1.7 显卡：安装 AMD 图形与 Vulkan 软件包。
install_amd_graphics() {
    step 1.7 '安装 AMD 图形和 Vulkan 驱动'
    sudo pacman -S --needed mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
}

# 1.8 音视频固件和服务
install_audio_firmware() {
    # 1.8.1 安装现代音频设备固件。
    step 1.8.1 '安装音频固件：sof-firmware'
    sudo pacman -S --needed sof-firmware
}

install_audio_services() {
    # 1.8.2 安装 PipeWire、WirePlumber 及音频兼容服务。
    step 1.8.2 '安装音视频服务'
    sudo pacman -S --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack rtkit
}

enable_audio_services() {
    # 1.8.3 在当前普通用户的登录会话中启用音视频服务。
    step 1.8.3 '启用用户音视频服务'
    systemctl --user enable --now pipewire pipewire-pulse wireplumber
}

# 1.9 蓝牙
install_bluetooth() {
    step 1.9.1 '安装蓝牙软件包'
    sudo pacman -S --needed bluez
}

enable_bluetooth() {
    step 1.9.2 '启用蓝牙服务'
    sudo systemctl enable --now bluetooth
}

# 1.10 电源：安装并启用性能模式切换服务。
install_power_profiles() {
    step 1.10.1 '安装电源性能模式服务'
    sudo pacman -S power-profiles-daemon
}

enable_power_profiles() {
    step 1.10.2 '启用电源性能模式服务'
    sudo systemctl enable --now power-profiles-daemon
}

# 2 安装桌面环境

# 2.1 安装 GNOME
install_gnome_base() {
    # 2.1.1 基础安装：逐项安装文档列出的 GNOME 软件包。
    step 2.1.1 '安装 GNOME 基础组件'
    sudo pacman -S \
        baobab \
        gdm \
        gnome-backgrounds \
        gnome-calculator \
        gnome-calendar \
        gnome-characters \
        gnome-clocks \
        gnome-color-manager \
        gnome-connections \
        gnome-control-center \
        gnome-disk-utility \
        gnome-font-viewer \
        gnome-keyring \
        gnome-logs \
        gnome-menus \
        gnome-remote-desktop \
        gnome-session \
        gnome-settings-daemon \
        gnome-shell \
        gnome-system-monitor \
        gnome-text-editor \
        gnome-user-share \
        grilo-plugins \
        gst-thumbnailers \
        gvfs \
        gvfs-afc \
        gvfs-dnssd \
        gvfs-goa \
        gvfs-gphoto2 \
        gvfs-mtp \
        gvfs-nfs \
        gvfs-onedrive \
        gvfs-smb \
        gvfs-wsdd \
        loupe \
        nautilus \
        papers \
        rygel \
        sushi \
        xdg-desktop-portal-gnome \
        xdg-user-dirs-gtk
}

install_gnome_optional_apps() {
    # 2.1.2 可选安装：软件商店 Bazaar、终端 Ghostty。
    step 2.1.2 '安装 Bazaar 和 Ghostty'
    sudo pacman -S bazaar ghostty
}

install_gnome_extras() {
    # 2.1.3 补充安装：调整工具、密钥、归档和高级网络设置。
    step 2.1.3 '安装 GNOME 补充工具'
    sudo pacman -S gnome-tweaks seahorse file-roller nm-connection-editor
    # 2.1.3.1 覆盖当前用户的应用入口，使用清晰的 symbolic 图标。
    step 2.1.3.1 '设置高级网络配置的 symbolic 图标'
    local applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$applications"
    cp /usr/share/applications/nm-connection-editor.desktop "$applications/nm-connection-editor.desktop"
    sed -i 's/^Icon=.*/Icon=preferences-system-network-symbolic/' "$applications/nm-connection-editor.desktop"
}

hide_dependency_apps() {
    # 2.1.4 隐藏依赖带入的图形化应用，仅修改当前普通用户的桌面条目。
    step 2.1.4 '隐藏依赖带入的图形化应用'
    local app src dst applications
    applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$applications"
    for app in lstopo qv4l2 qvidcap vim; do
        src="/usr/share/applications/$app.desktop"
        dst="$applications/$app.desktop"
        if [[ -f $src ]]; then
            cp "$src" "$dst"
            sed -i '/^NoDisplay=/d; /^\[Desktop Entry\]$/a NoDisplay=true' "$dst"
        fi
    done
}

install_nautilus_enhancements() {
    # 2.1.5 文件管理器增强：视频与 EXE 缩略图、图片转换。
    step 2.1.5 '安装文件管理器增强组件'
    sudo pacman -S gst-libav icoextract python-pillow nautilus-image-converter
}

enable_gnome() {
    # 2.1.6 启用 GDM 开机自启，剩余终端交互完成后再进入图形界面。
    step 2.1.6 '启用 GNOME 桌面开机自启'
    sudo systemctl enable gdm
}

# 2.2 其他设置
configure_nautilus_terminal() {
    # 2.2.1 从此处打开终端：安装扩展，并将右键终端设置为 Ghostty。
    step 2.2.1 '配置文件管理器右键打开 Ghostty'
    yay -S nautilus-open-any-terminal
    gsettings set com.github.stunkymonkey.nautilus-open-any-terminal terminal custom
    gsettings set com.github.stunkymonkey.nautilus-open-any-terminal custom-local-command 'ghostty --working-directory=%s'
}

configure_gnome_terminal() {
    # 2.2.2 修改 GNOME 默认终端：通过 xdg-terminal-exec 优先选择 Ghostty。
    step 2.2.2 '设置 GNOME 默认终端：Ghostty'
    sudo pacman -S --needed xdg-terminal-exec
    local config temporary
    config="${XDG_CONFIG_HOME:-$HOME/.config}/gnome-xdg-terminals.list"
    mkdir -p "${config%/*}"
    temporary=$(mktemp "${config}.XXXXXX")
    # 将 Ghostty 置于首位，移除原有的同名条目或注释示例，保留其他候选。
    {
        printf 'com.mitchellh.ghostty.desktop\n'
        if [[ -f $config ]]; then
            sed '/^[[:space:]]*#\{0,1\}[[:space:]]*com\.mitchellh\.ghostty\.desktop[[:space:]]*$/d' "$config"
        fi
    } > "$temporary"
    mv -- "$temporary" "$config"
    # 输出 GNOME 环境下实际选中的终端标识，不启动终端窗口。
    XDG_CURRENT_DESKTOP=GNOME xdg-terminal-exec --print-id
}

# 所有安装与配置交互完成后询问重启；不重启时最后启动 GDM。
finish_installation() {
    local answer
    step 2.3 '完成安装'
    read -r -p '是否立即重启？[y/N]：' answer
    if [[ $answer == y || $answer == Y ]]; then
        sudo reboot
    else
        printf '安装完成，正在启动 GNOME 图形登录界面；可稍后手动重启。\n'
        sudo systemctl start gdm
    fi
}

main() {
    # 用户配置必须属于普通用户，系统命令在各步骤内部使用 sudo。
    if (( EUID == 0 )); then
        printf '请以普通用户执行 bash setup-desktop.sh；系统操作会自动通过 sudo 提权。\n' >&2
        return 1
    fi
    step 1 '桌面环境前置准备'
    connect_network
    install_fonts
    enable_multilib
    configure_archlinuxcn
    install_aur_helpers
    install_flatpak
    install_amd_graphics
    step 1.8 '音视频固件和服务'
    install_audio_firmware
    install_audio_services
    enable_audio_services
    step 1.9 '蓝牙'
    install_bluetooth
    enable_bluetooth
    step 1.10 '电源性能模式切换'
    install_power_profiles
    enable_power_profiles

    step 2 '安装桌面环境'
    step 2.1 '安装 GNOME'
    install_gnome_base
    install_gnome_optional_apps
    install_gnome_extras
    hide_dependency_apps
    install_nautilus_enhancements
    enable_gnome
    step 2.2 '其他设置'
    configure_nautilus_terminal
    configure_gnome_terminal
    finish_installation
}

# 直接执行时运行完整流程；加载脚本时可单独调用各功能函数。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
