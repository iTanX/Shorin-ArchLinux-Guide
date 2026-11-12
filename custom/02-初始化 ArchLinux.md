# 基础设置

## 开启 SSH

1. 安装 OpenSSH

   ```
   sudo pacman -S openssh
   ```

2. 启动 SSH 服务并设置开机自启

   ```
   sudo systemctl enable --now sshd
   ```

   检查运行状态：

   ```
   sudo systemctl status sshd
   ```

   看到 `active (running)` 就说明启动成功。

3. 开启密码登录

   编辑 SSH 服务端配置：

   ```
   sudo nano /etc/ssh/sshd_config
   ```

   找到或添加以下配置：

   ```
   PermitRootLogin yes
   PasswordAuthentication yes
   ```

   如果原来的配置被 `#` 注释，需要去掉注释。

4. 重启 SSH 服务

   ```
   sudo systemctl restart sshd
   ```

5. 其他设备连接

   ```
   ssh root@xxx.xxx.xxx.xx
   ```

## 全局文本编辑器

通过 `EDITOR` 环境变量设置默认编辑器。如果不设置的话有些程序会默认调用 `vi` 编辑器。Arch 默认是没有安装 `vi` 的，会报错。

```
sudo vim /etc/environment
EDITOR=vim

# 如果你使用neovim的话填入nvim，nano填入nano
```

由于是全局变量，需要 `exit` 注销后重新登录才能生效。

```
exit
```

## 创建普通用户

很多软件会拒绝在 root 权限下运行，所以普通用户是必须的。

1. 新建用户

   ```
   useradd -mG wheel 你的用户名
   ```

   > `-m` 代表创建用户的时候创建 `home` 目录。

   > `-G` 代表设置组。

2. 设置密码

   ```
   passwd 你的用户名
   ```

   - 可选：取消多次输错密码后的锁定时间

     > 这步牺牲安全性以提高日用体验和软件兼容

     ```
     vim /etc/security/faillock.conf
     ```

     把 `deny = 3` 改成 `deny = 0`

3. 编辑权限

   ```
   visudo
   ```

   > 此时编辑的文件本体是 `/etc/sudoers`，`visudo`是在有安全机制的情况下进行编辑。

   搜索 `wheel`，取消注释。

   ```
   %wheel ALL=(ALL:ALL) ALL
   ```

   - 可选：配置 `pacman` 免密

     > 这步牺牲安全性获得更流畅的安装软件体验

     ```
     visudo -f /etc/sudoers.d/10-pacman-nopasswd
     ```

     ```
     %wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/pacman
     ```

     > 如果你要给其他命令配置免密可以以逗号隔开 `/usr/bin/pacman, /usr/bin/systemctl`

     保存后修改权限

     ```
     chmod 440 /etc/sudoers.d/10-pacman-nopasswd
     ```

4. 退出 root 使用普通用户登录

   ```
   exit
   ```

   接下来需要管理员权限运行的命令要加上 `sudo`。

## 字体

通常安装以下字体包：

```
sudo pacman -S noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
```

> `noto-fonts` 包含大部分外文字体。

> `noto-fonts-cjk` 最常用的中日韩字体，但是因为同时包含中日韩，所以不正确设置系统字体的话会出现中文以日文的字体显示之类问题。有关 `fontconfig 字体设置` 的内容可以看[附录-字体设置](https://github.com/iTanX/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/附录.md#字体设置)。

> `noto-fonts-emoji` emoji 表情。

> `ttf-jetbrains-mono-nerd` 最常用的等宽字体，用于终端字体显示。`nerd` 代表包含了字符字体。

# 软件源配置

## 32 位源

运行 Windows 软件通常需要各种 32 位的依赖，想玩游戏的话 Steam 客户端也在 32 位源里，所以建议开启 32 位源。

1. 编辑 pacman 配置文件

   ```
   sudo vim /etc/pacman.conf
   ```

   去掉 `[multilib]` 两行的注释。

   ```
   [multilib]
   Include = /etc/pacman.d/mirrorlist
   ```

2. 同步数据库

   ```
   sudo pacman -Syu
   ```

## archlinuxcn 源

archlinuxcn 源是由 archlinuxcn 维护的软件仓库，可以丰富我们安装软件的手段。

1. 编辑 pacman 配置文件添加 archlinuxcn 源

   ```
   sudo vim /etc/pacman.conf
   ```

2. 文件底部写入

   ```
   [archlinuxcn]
   Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
   Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
   ```

   上面这两个是国内镜像，ustc（中科大）和 tuna（清华），如果你在海外的话可以直接使用官方：

   ```
   Server = https://repo.archlinuxcn.org/$arch
   ```

3. 同步数据库并安装 archlinuxcn 密钥

   ```
   sudo pacman -Sy archlinuxcn-keyring
   sudo pacman -Syu 
   ```

## AUR

> [ArchWiki AUR Helpers](https://wiki.archlinux.org/title/AUR_helpers)

AUR 是 Arch 最强大的软件仓库。这个仓库里通常只存放软件的`PKGBUILD`，可以将其理解为一个自动化安装脚本。通常的流程是从 AUR 上拉取`PKGBUILD`，然后`makepkg -si`打包软件，再用`pacman -U`安装，但这太过繁琐。通过社区做好的 AUR 助手可以更方便地从 AUR 安装软件。archlinuxcn 上有编译好的版本，可以直接从 archlinuxcn 安装。

```
sudo pacman -S --needed base-devel yay paru
```

> `base-devel` 是编译软件时必须的；`yay` 和 `paru` 都是常用的助手，任选其一，也可以都装。

## Flatpak

Flatpak 是全发行版通用的打包方式。依赖和插件比较多的软件 Flatpak 版本通常更好用，比如 OBS 和 Easyeffects。如果 AUR 和仓库的软件都不太正常，也可以尝试 Flatpak 版本。

1. 安装 `flatpak`

   ```
   sudo pacman -S flatpak
   ```

2. 可选：更换国内源

   - 上交大

     ```
     sudo flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub
     ```

   - 中科大

     ```
     sudo flatpak remote-modify flathub --url=https://mirrors.ustc.edu.cn/flathub
     ```

# 硬件驱动

## 显卡

### 自动安装驱动

利用 chwd 自动安装驱动。

```
yay -S chwd-arch-git
chwd -a
```

- 其他命令

  `chwd --list` 可以列出可用的配置，每一个配置代表了一系列驱动包和后续修改。

  `chwd -r 配置名称` 删除已经安装的配置。

  更多选项可以用 `chwd -h` 查看。

### 手动安装驱动

#### 安装显卡驱动

- NVIDIA

  在 [CodeNames · freedesktop.org](https://nouveau.freedesktop.org/CodeNames.html) 这个页面搜索自己的显卡，看看对应的 family 和架构是什么。然后在 [NVIDIA - ArchWiki](https://wiki.archlinux.org/title/NVIDIA) 这个页面查找对应的包名。如果找不到你的显卡名字，可以看和你的显卡相同架构的显卡对应的 family 是什么。例如 MX250，表上没有，但通过它是 Pascal 架构这个信息可以知道它属于 `NV130 family`。

  不同的内核对应的包的后缀不同，像 `linux-zen` 这样的自定义内核要装 `-dkms` 后缀。不过，考虑到日后更新的稳定和便利，推荐统一使用 `-dkms` 版本的驱动包，它会自动在更换和更新内核时重新编译驱动。除了驱动包，还需要 `nvidia-utils` 工具集，580xx 版本驱动对应的工具集包是 AUR 上的`nvidia-580xx-utils`，其他显卡按照 ArchWiki 的表格以此类推。

  > `nvidia-open` 是内核模块开源的驱动，不是完全的开源驱动。`nvidia-utils` 通常作为驱动包的依赖自动被安装，但是某些自行打包的发行版可能没有正确处理依赖关系导致需要自己安装。

  - 检查头文件

    DKMS 编译内核模块需要内核的头文件。

    ```
    sudo pacman -S --needed linux-headers
    ```

    > `linux` 替换为自己的内核，比如 zen 内核的头文件包名是 `linux-zen-headers`。

  - 安装驱动

    ```
    sudo pacman -S nvidia-open-dkms nvidia-utils lib32-nvidia-utils
    ```

- AMD

  [AMDGPU - ArchWiki](https://wiki.archlinux.org/title/AMDGPU)

  A 卡通常不需要自己安装驱动，已经由 `linux-firmware` 和 `mesa` 提供。可以安装一下 Vulkan 驱动。

  ```
  sudo pacman -S --needed mesa lib32-mesa xf86-video-amdgpu vulkan-radeon lib32-vulkan-radeon
  ```

- Intel

  [Intel graphics - ArchWiki](https://wiki.archlinux.org/title/Intel_graphics)

  ```
  sudo pacman -S --needed mesa lib32-mesa vulkan-intel lib32-vulkan-intel
  ```

#### 硬件编解码

> [archwiki_硬件视频加速](https://wiki.archlinux.org/title/Hardware_video_acceleration)

- NVIDIA

  由 `nvidia-utils` 和 `libva-nvidia-driver` 提供。

  ```
  sudo pacman -S libva-nvidia-driver
  ```

- AMD

  自带。

- Intel

  Broadwell 往后的 Intel 显卡装 `intel-media-driver`，旧的装 `libva-intel-driver`。

#### 可选：OpenCL 驱动

<details style="box-sizing: border-box; display: block; margin-top: 0px; margin-bottom: 16px; color: rgb(31, 35, 40); font-family: &quot;Mona Sans VF&quot;, -apple-system, &quot;system-ui&quot;, &quot;Segoe UI&quot;, &quot;Noto Sans Backtick Fix&quot;, &quot;Noto Sans&quot;, Helvetica, Arial, sans-serif, &quot;Apple Color Emoji&quot;, &quot;Segoe UI Emoji&quot;; font-size: 16px; font-style: normal; font-variant-ligatures: normal; font-variant-caps: normal; font-weight: 400; letter-spacing: normal; orphans: 2; text-align: start; text-indent: 0px; text-transform: none; widows: 2; word-spacing: 0px; -webkit-text-stroke-width: 0px; white-space: normal; background-color: rgb(255, 255, 255); text-decoration-thickness: initial; text-decoration-style: initial; text-decoration-color: initial;"><summary style="box-sizing: border-box; display: list-item; cursor: pointer;">如果你不知道自己需不需要 OpenCL 驱动的话你大概率不需要</summary><blockquote style="box-sizing: border-box; margin: 0px 0px 16px; color: rgb(89, 99, 110); border-left: 4px solid rgb(209, 217, 224); padding: 0px 1em;"><p dir="auto" style="box-sizing: border-box; margin-top: 0px; margin-bottom: 0px;">参考：<a href="https://wiki.archlinux.org/title/General-purpose_computing_on_graphics_processing_units#Runtime" rel="nofollow" style="box-sizing: border-box; background-color: rgba(0, 0, 0, 0); color: rgb(9, 105, 218); text-decoration: underline; text-underline-offset: 0.2rem;">archwiki General-purpose computing on graphics processing units</a></p></blockquote><p dir="auto" style="box-sizing: border-box; margin-top: 0px; margin-bottom: 16px;">先安装统一调用</p><div class="snippet-clipboard-content notranslate position-relative overflow-auto" style="box-sizing: border-box; overflow: auto !important; position: relative !important; margin-bottom: 16px; background-color: rgb(246, 248, 250); justify-content: space-between; display: flex;"><pre class="notranslate" style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; margin-top: 0px; margin-bottom: 0px; overflow-wrap: normal; padding: 16px; color: rgb(31, 35, 40); background-color: rgb(246, 248, 250); border-radius: 6px; line-height: 1.45; overflow: auto;"><code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: pre; background: 0px 0px rgba(0, 0, 0, 0); border-radius: 6px; margin: 0px; padding: 0px; word-break: normal; border: 0px; line-height: inherit; overflow-wrap: normal; display: inline; overflow: visible;">sudo pacman -S ocl-icd
</code></pre><div style="box-sizing: border-box;"></div></div><p dir="auto" style="box-sizing: border-box; margin-top: 0px; margin-bottom: 16px;">然后安装运行时</p><ul dir="auto" style="box-sizing: border-box; margin-top: 0px; margin-bottom: 16px; padding-left: 2em;"><li style="box-sizing: border-box;"><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">NVIDIA</p><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">装<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">opencl-nvidia</code> <code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">lib32-opencl-nvidia</code> 这两个包。580xx 和 470xx 的用户安装对应的版本，例如：<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">opencl-nvidia-580xx</code> <code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">lib32-opencl-nvidia-580xx</code>。</p></li><li style="box-sizing: border-box; margin-top: 0.25em;"><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">AMD</p><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">新卡装<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">rocm-opencl-runtime</code>。早于 Vega 架构的卡需要额外配置 <code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">ROC_ENABLE_PRE_VEGA=1</code> 环境变量。</p><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">不兼容的话可以使用 mesa</p><div class="highlight highlight-source-shell notranslate position-relative overflow-auto" dir="auto" style="box-sizing: border-box; overflow: auto !important; position: relative !important; margin-bottom: 16px; background-color: rgb(246, 248, 250); justify-content: space-between; display: flex;"><pre style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; margin-top: 0px; margin-bottom: 0px; overflow-wrap: normal; padding: 16px; color: rgb(31, 35, 40); background-color: rgb(246, 248, 250); border-radius: 6px; line-height: 1.45; overflow: auto; word-break: normal;">sudo pacman -S opencl-mesa lib32-opencl-mesa</pre><div style="box-sizing: border-box;"></div></div><blockquote style="box-sizing: border-box; margin: 0px 0px 16px; color: rgb(89, 99, 110); border-left: 4px solid rgb(209, 217, 224); padding: 0px 1em;"><p dir="auto" style="box-sizing: border-box; margin-top: 0px; margin-bottom: 0px;">安装后需要配置环境变量<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">RUSTICL_ENABLE=radeonsi</code></p></blockquote></li><li style="box-sizing: border-box; margin-top: 0.25em;"><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">Intel</p><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">Gen12 以后的安装<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">intel-compute-runtime</code>，旧的安装<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">intel-compute-runtime-legacy</code></p></li><li style="box-sizing: border-box; margin-top: 0.25em;"><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">CPU</p><p dir="auto" style="box-sizing: border-box; margin-top: 16px; margin-bottom: 16px;">装<code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">intel-opencl-runtime</code>；不兼容的话装基于 LLVM 的 <code style="box-sizing: border-box; font-family: ui-monospace, SFMono-Regular, &quot;SF Mono&quot;, Menlo, Consolas, &quot;Liberation Mono&quot;, monospace; font-size: 13.6px; white-space: break-spaces; background-color: rgba(129, 139, 152, 0.12); border-radius: 6px; margin: 0px; padding: 0.2em 0.4em;">pocl</code>。</p></li></ul></details>

#### 重启激活显卡驱动

```
reboot
```

- 可选：验证硬件编解码

  ```
  sudo pacman -S libva-utils
  ```

  使用 libva-utils 提供的 vainfo 进行验证。

  ```
  vainfo
  ```

  多显卡用户可以使用 LIBVA_DRIVER_NAME 环境变量指定要使用的显卡：

  ```
  LIBVA_DRIVER_NAME=nvidia vainfo
  ```

## 音视频固件和服务

让音频设备和屏幕分享正常工作。

1. 可选：安装音视频固件

   ```
   sudo pacman -S --needed sof-firmware alsa-ucm-conf alsa-firmware
   ```

   > `sof-firmware` 为现代音视频设备提供固件，通常装这个就可以了。

   > `alsa-ucm-conf` 提供必要的配置文件。

   > `alsa-firmware` 为不常见或者较旧的设备提供固件。

2. 安装音视频服务

   ```
   sudo pacman -S --needed pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack rtkit
   ```

   > `pipewire` 是由 Red Hat 主导开发的现代音视频服务。

   > `wireplumber` 会智能管理 pipewire。

   > `pipewire-pulse`、`pipewire-alsa`、`pipewire-jack` 分别为 PulseAudio、ALSA、JACK 提供兼容。

   > `rtkit` 实时调度，提高 CPU 优先级，解决 CPU 高负载时音频卡顿问题

3. 启用服务

   ```
   systemctl --user enable --now pipewire pipewire-pulse wireplumber
   ```

## 蓝牙

1. 安装

   ```
   sudo pacman -S --needed bluez
   ```

2. 启动服务

   ```
   sudo systemctl enable --now bluetooth
   ```

## 电源（性能模式切换）

`power-profiles-daemon` 是各个桌面环境通用的性能模式切换服务，有三个档位，`performance` 性能、`balance` 平衡、`powersave` 省电。

1. 安装

   ```
   sudo pacman -S power-profiles-daemon
   ```

2. 启动服务

   ```
   sudo systemctl enable --now power-profiles-daemon
   ```

> 这个已经足够了，不建议折腾 `tlp` 或者 `auto-cpufreq`，功耗上不会有明显区别。