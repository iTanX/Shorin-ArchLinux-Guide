# 手动安装

参考链接：

> [Arch Linux 简明指南](https://arch.icekylin.online/) |[安装指南 - Arch Linux 中文维基](https://wiki.archlinuxcn.org/wiki/%E5%AE%89%E8%A3%85%E6%8C%87%E5%8D%97)

## 方案简述

Win 加 Linux 双系统；分区时创建独立于 Windows 的启动分区（ESP）并挂载到 `/efi`，剩下的所有空间创建为一个大分区；文件系统使用 Btrfs，创建 `@` 、`@home`、`@swap` 子卷；Bootloader 使用最常用的 GRUB；Swap（交换空间）使用 Swapfile；联网工具使用最常用的 NetworkManager。

## 准备工作

### 从 Live CD 启动

- 下载镜像
- 制作启动盘
- 从启动盘启动

### 确认固件类型

```bash
cat /sys/firmware/efi/fw_platform_size
```

如果输出 `64`，说明主板是 64 位 x64 UEFI 固件；如果输出 `32`，说明是 32 位 UEFI；如果提示 `No such file or directory` 没有文件或目录，说明是 BIOS。本文只涉及 x64 UEFI 情况下安装，如果你不是，安装引导的步骤会不一样，可以查阅[ArchWiki GRUB](https://wiki.archlinux.org/title/GRUB#GUID_Partition_Table_(GPT)_specific_instructions)。

如果你是虚拟机，并且是 BIOS 固件，推荐在虚拟机设置里调整为 UEFI。

### 连接网络

有线网自动连接，还可以用数据线分享手机的网络。

使用 `iwctl` 工具连接无线网：

1. 启动

   ```bash
   iwctl
   ```

   此时会进入 iwctl，提示符会产生变化。

2. 连接

   ```text
   device list #列出设备
   
   station wlan0 scan #扫描网络
   
   station wlan0 get-networks #列出所有扫描的wifi
   
   station wlan0 connect 【此处是你的wifi名字（不能是中文）】
   ```

3. 退出 iwctl

   ```bash
   exit
   ```

确认网络连接可用

```bash
ip a #查看网络连接信息，如果出现了紫色的 ip 地址说明成功连接
ping bilibili.com #确认网络正常
```

### 激活 NTP

运行 `timedatectl`，应该在输出看到 NTP 已经开启，否则在安装时可能会出现验证相关的报错：

```bash
NTP service: active
```

手动开启使用：

```shell
timedatectl set-ntp true
```

### 设置镜像源

用 `reflector` 配置最快最新的镜像源，大幅提高软件下载速度。

```bash
reflector -p https -a 12 -c cn --v --sort rate --save /etc/pacman.d/mirrorlist

# -p（protocol） https 指定 https 协议的链接
# -a（age） 12 指定最近 12 小时更新过的源
# -c（country） cn 指定国家为中国（可以增加邻国）
# --v（verbose） 过程可视化
# --sort rate 按照下载速度排序（经过前面几道筛选，镜像源通常已经足够稳定，所以这里直接按照速度排序即可）
# --save /etc/pacman.d/mirrorlist 将结果保存到 /etc/pacman.d/mirrorlist
```

然后同步软件列表数据。

```bash
pacman -Sy
```

## 硬盘分区

### 创建分区

```shell
lsblk -pf  #查看当前分区情况
fdisk -l /dev/想要查询详细情况的硬盘  #小写字母l，查看详细分区信息
```

```shell
cfdisk /dev/nvme0n1 #选择自己要使用的硬盘进行分区
```

1. 如果是新硬盘的话会弹出选项，选 GPT。

2. EFI 分区

   上下方向键选中空闲空间，左右方向键选择 NEW 创建 512MB 的分区，类型（type）选择 EFI System。

   >如果你的类型里没有 EFI System 说明你的硬盘不是 GPT 分区表，可以使用 `cfdisk -z 设备名` 以空分区表打开硬盘，然后选择 GPT。⚠️警告⚠️ 这个操作会清空硬盘上的分区。

   >也可以直接使用 Windows 的 EFI 分区，但是不推荐。如果你一定要共享的话跳过后面格式化 EFI 分区和安装回退引导这两个步骤。

3. 根分区

   其余空间全部分到一个分区里，类型 `linux filesystem` 不需要更改。

4. 保存

   选择 `write`，输入 `yes` 保存。`quit` 退出。

>后续如果需要扩容 Btrfs 的话可以看：[附录：Btrfs 扩容和缩小](./附录.md#btrfs-扩容和缩小)

### 格式化分区

通过格式化创建需要的文件系统。

1. 再次查看分区情况

   ```shell
   lsblk -pf #查看分区情况
   fdisk -l /dev/想要查询详细情况的硬盘  #小写字母l，查看详细分区信息
   ```

2. 格式化 EFI 分区

   ```shell
   mkfs.fat -F 32 /dev/nvme0n1p1（EFI 分区名）
   ```

3. 格式化 Btrfs 根分区

   ```shell
   mkfs.btrfs /dev/nvme0n1p2（根分区名）
   
   #加上 -f 参数可以强制格式化
   ```

### 创建子卷

子卷是 Btrfs 的一个特性，跟快照（存档和回档）有关。通常至少要创建 root 子卷（存放系统文件）和 home 子卷（存放用户文件），根据命名规范取名为 `@` 和 `@home`。由于这两者是平级关系，所以创建 `@` 快照时不会包含 `@home` 中的内容。这样就可以只恢复系统文件，不影响用户数据。

- 挂载

  ```shell
  mount -t btrfs /dev/nvme0n1p2（根分区名） /mnt
  ```

   `mount` 挂载命令；

   `-t` 指定文件系统；

   这条命令把 `/dev/nvme0n1p2` 分区挂载到了 `/mnt` 目录，而 `/dev/nvme0n1p2` 是我们将要安装的系统的 `根分区`，这意味着 `/mnt` 成为了我们将要安装的系统的 `根`。
- 创建子卷

  ```shell
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@swap
  ```

- 可选：确认

  ```shell
  btrfs subvolume list /mnt
  ```

- 取消挂载

  ```shell
  umount /mnt
  ```

### 挂载子卷

1. 挂载 root 子卷

   ```bash
   mount -t btrfs -o subvol=/@,compress=zstd /dev/nvme0n1p2 /mnt

   # -o 指定额外的挂载参数
   # compress=zstd 指定透明压缩，zstd 是压缩算法
   ```

   和刚刚的挂载是一样的操作，不过这次是把 `/dev/nvme0n1p2` 上的 `@` 子卷挂载到了 `/mnt`，而不是把 `/dev/nvme0n1p2` 挂载到 `/mnt`。

   `compress` 是 Btrfs 的另一个特性，透明压缩。在数据写入磁盘前先进行压缩，提升读写性能，节省空间，延长寿命。可以像这样 `zstd:3` 指定压缩等级，最高 15。默认为 3，在意 CPU 性能可以设置成 1。

2. 挂载 home 子卷

   ```bash
   mount --mkdir -t btrfs -o subvol=/@home,compress=zstd /dev/nvme0n1p2 /mnt/home
   ```

   由于 `/mnt` 下没有 `/mnt/home` 这个目录，所以要加上 `--mkdir` 命令创建 `/mnt/home` 用来挂载。把 `@home` 子卷挂载到了 `/mnt/home`。

3. 挂载 swap 子卷

   ```bash
   mount --mkdir -t btrfs -o subvol=/@swap,compress=zstd /dev/nvme0n1p2 /mnt/swap
   ```

4. 挂载 EFI 分区（ESP）

   ```bash
   mount --mkdir /dev/nvme0n1p1 /mnt/efi
   ```

   记得把 `/dev/nvme0n1p1` 替换为自己对应的 EFI 分区设备名。

5. 可选：复查挂载情况

   ```bash
   df -h
   ```

## 安装系统

### 基础安装

```bash
# pacstrap -K /mnt base linux linux-firmware btrfs-progs networkmanager vim sudo amd-ucode
pacstrap -K /mnt base linux linux-firmware btrfs-progs vim sudo amd-ucode

# -K 初始化密钥
# base 基本包
# linux是内核，可以更换
# linux-firmware是固件
# btrfs-progs是 Btrfs 文件系统的管理工具
# networkmanager 是联网用的，是各个桌面环境标配的联网工具
# vim 是文本编辑器，也可以换成别的，比如 nano、neovim
# sudo 和权限管理有关
# amd-ucode 是微码，用来修复和优化 CPU，Intel 用户安装 intel-ucode
```

>`pacstrap` 命令是把软件安装到指定的根目录下。

>如果你使用的是 marvell 的无线网卡，这里要额外安装 `linux-firmware-marvell`，否则进系统找不到网卡。

### 配置 Swap


参考链接：

> [电源管理/挂起与睡眠 - Arch Linux 中文维基](https://wiki.archlinuxcn.org/wiki/%E7%94%B5%E6%BA%90%E7%AE%A1%E7%90%86/%E6%8C%82%E8%B5%B7%E4%B8%8E%E4%BC%91%E7%9C%A0#%E7%A6%81%E7%94%A8_zswap_%E5%86%99%E5%9B%9E%E4%BB%A5%E4%BB%85%E5%B0%86%E4%BA%A4%E6%8D%A2%E7%A9%BA%E9%97%B4%E7%94%A8%E4%BA%8E%E4%BC%91%E7%9C%A0) | [Swap - ArchWiki](https://wiki.archlinux.org/title/Swap) | [Swap - Manjaro](https://wiki.manjaro.org/index.php?title=Swap)

Swap 用来存放内存中的冷数据，提高电脑的运行速度。还能把硬盘当作虚拟内存使用。设置了硬盘 Swap 还可以使用休眠功能。休眠指的是把系统当前状态写入硬盘，然后电脑完全断电，下一次开机恢复到休眠前的状态。硬盘 Swap 有 Swap 分区或者 Swap 文件两种方式，前者配置更简单，后者配置稍复杂，但是更加灵活。这里采用交换文件的方式。

swap 大小参考：

| 内存(GB) | 不需要休眠(GB) | 需要休眠（GB） | 不建议超过（GB） |
| -------- | -------------- | -------------- | ---------------- |
| 1        | 1              | 2              | 2                |
| 2        | 2              | 3              | 4                |
| 3        | 3              | 5              | 6                |
| 4        | 4              | 6              | 8                |
| 5        | 2              | 7              | 10               |
| 6        | 2              | 8              | 12               |
| 8        | 3              | 11             | 16               |
| 12       | 3              | 15             | 24               |
| 16       | 4              | 20             | 32               |
| 24       | 5              | 29             | 48               |
| 32       | 6              | 38             | 64               |
| 64       | 8              | 72             | 128              |
| 128      | 11             | 139            | 256              |
| 256      | 16             | 272            | 512              |

1. 创建 Swap 文件

   此处的 `8g` 应该是你实际需求的 swap 大小

   ```bash
   btrfs filesystem mkswapfile --size 8g --uuid clear /mnt/swap/swapfile
   ```

2. 启用 Swap

   ```bash
   swapon /mnt/swap/swapfile
   ```

### 生成 fstab 文件

系统会根据 fstab 中的内容自动进行挂载。

```shell
genfstab -U /mnt > /mnt/etc/fstab


# genfstab（生成文件系统表）
# -U 用 UUID 指定分区
# > 大于号代表输出结果覆盖写入到右边的文件里
# 如果是 >> 两个大于号则代表追加写入
```

## 基础设置

### 更换根目录（change root）

进入刚刚安装的系统。

```shell
arch-chroot /mnt
```

此时根目录从 Live 环境变成了 `/mnt`，可以注意到提示符的变化。

### 设置时区和时间

设置时区：

```shell
timedatectl set-timezone Asia/Shanghai
```

同步硬件时间：

```bash
hwclock --systohc
```

除了 `timedatectl` 命令，还可以手动创建链接。

```bash
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# ln 是 link 的缩写
# -s 代表跨文件系统的软链接
# -f 代表强制执行
```

### 本地化设置

1. 编辑配置文件

   ```bash
   vim /etc/locale.gen
   ```

   左斜杠键进行搜索；`x` 键剪贴掉 `en_US.UTF-8 UTF-8` 和 `zh_CN.UTF-8 UTF-8` 的前面代表注释的井号；`:wq` 保存并退出。

2. 生成本地化配置

   ```bash
   locale-gen
   ```

3. 设置系统语言

   ```bash
   vim /etc/locale.conf
   ```

   `i` 键进入编辑模式；写入 `LANG=en_US.UTF-8` 设置系统语言为英文；

   ```bash
   LANG=en_US.UTF-8
   ```

   `esc` 退出编辑模式；`:wq` 保存并退出。

   >`/etc/locale.conf` 这个文件是系统级的语言设置，写入 `zh_CN.UTF-8` 可以设置系统语言为中文，但是会导致 TTY 的中文字符全部变成豆腐块，所以不建议这么做。我们后面安装完桌面环境后在用户空间修改系统语言。

### 设置主机名

```bash
vim /etc/hostname
```

`i` 键进入编辑模式；取一个自己喜欢的主机名，比如 `archlinux`；`esc` 退出编辑模式；`:wq` 保存并退出。

>此时你应该已经相当熟悉 Vim 编辑器最基本的操作了，所以后面我会省略 Vim 的操作讲解。

### 设置 root 密码

```bash
passwd
```

输入过程不显示，直接输入回车即可。

### 安装引导程序

这是 UEFI 引导的安装方式，如果你是 BIOS 设备请看 ArchWiki 的 GRUB 页面。

根据 ESP 挂载点和个人需求的不同，Bootloader 的选择也会不同。这里安装最常用的 `grub`，采用的是"ESP 挂载点为 `/efi` 且 `grub` 装进 ESP"的方案。

1. 安装必要的软件包

   ```shell
   pacman -S grub efibootmgr os-prober fuse3
   ```

   `efibootmgr` 管理 UEFI 启动项；

   `os-prober` 和 `fuse3` 用于双系统配置。

2. 安装引导

   ```bash
   grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ARCH
   ```

   >`grub-install` 安装 GRUB；

   >`--target` 指定架构；

   >`--efi-directory` 指定 ESP 位置；

   >`--boot-directory` 可以指定 GRUB 的安装目录，如果不写的话就是 /boot/grub

   >`--bootloader-id` 取一个启动项名字；

   上面这段命令在 `/efi/EFI/ARCH` 目录生成 `grubx64.efi` 文件，同时在主板的存储芯片（NVRAM）中生成对应的启动项。

3. 可选：安装回退引导

   当主板找不到 NVRAM 中记录的启动文件时，会尝试从`回退启动文件`启动系统，该启动文件所在路径被称为`可移动媒体启动路径`，通常是 `ESP/EFI/BOOT/BOOTx64.EFI`。

   >`ESP`指代 ESP 的挂载点，在本文中是 `/efi`

   如果你符合以下情况中的任意一个，推荐安装回退引导，避免找不到启动项：

   - 你安装系统使用的是移动硬盘或U盘之类的可移动存储设备，想要在任何电脑上即插即用；

      >因为我们不可能在所有电脑的主板上都存储一个启动项。

   - 你是微星主板；

      >因为部分主板仅支持回退启动文件路径。

   - 你日后可能会重置主板或者更新固件；

      >因为这类操作可能会清除主板的 NVRAM 上储存的启动项导致引导丢失。

   安装前还要注意，如果你和包括 Windows 在内的其他系统共享了启动分区，先检查`ESP/EFI/BOOT/BOOTx64.EFI`是否已经存在，避免出现不同系统的回退启动文件相互覆盖的情况，~~如果和Windows共享启动分区的话大概率会被覆盖~~。

   具体安装命令：

   ```
   grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram
   ```

   >`--removable` 将引导安装至回退路径

   >`--no-nvram` 不记录进主板的存储芯片中

   >如果你日后出现了启动项丢失问题，可以参考：[issues:主板能识别系统盘但无法进入 GRUB](./issues.md#主板能识别系统盘但无法进入-grub)
   
4. 编辑 GRUB 的源文件

   ```bash
   vim /etc/default/grub
   ```

   这是生成 GRUB 的配置文件时需要用到的东西。

   - 启动项记忆功能

     `GRUB_DEFAULT=0` 改成 `=saved`，再取消 `GRUB_SAVEDEFAULT=true` 的注释。

   - 显示开机日志

     `GRUB_CMDLINE_LINUX_DEFAULT` 里面去掉 `quiet` 以显示开机日志。再把 `loglevel` 日志等级设置为 5。`loglevel` 共 8 级，5 级是一个信息量的平衡点。

   - 禁用 watchdog

     `GRUB_CMDLINE_LINUX_DEFAULT` 里添加 `nowatchdog` 以及 `modprobe.blacklist=sp5100_tco`。Intel CPU 用户把 `sp5100_tco` 换成 `iTCO_wdt`。

     watchdog 的目的简单来说是在系统死机的时候自动重启系统。对个人用户来说没有意义，禁用以节省系统资源、提高开机和关机速度。

    - 允许使用 os-prober 搜索其他系统

      取消最后一行 `GRUB_DISABLE_OS_PROBER=false` 的注释。

5. 生成启动流程 grub.cfg


   ```bash
   grub-mkconfig -o /boot/grub/grub.cfg
   ```

   `grub-mkconfig`命令会生成启动流程，加上 `-o` 选项将输出保存到文件，文件路径是`/boot/grub/grub.cfg`

6. 初始化 Btrfs 环境块

   通常环境变量会存储在 `/boot/grub/grubenv` 中，这与`启动项记忆`等实用功能相关，但 Btrfs 文件系统的特殊性导致了写入异常。从 GRUB 2.14 版本开始，可以初始化 Btrfs Header 中的部分区域用于 `grubenv` 相关功能。
   
   ```
   grub-editenv - set ok=1
   
   # grub-editenv 编辑 grubenv
   # 短横杠代表 /boot/grub/grubenv 
   # set ok=1 这里随意写了点东西初始化环境快
   ```

   可以使用如下命令验证

   ```
   grub-editenv - list
   ```
   应该会看到类似下面这样的输出
   ```
   env_block=512+1
   ok=1
   ```

   > 注意，如果你使用 LVM、RAID 或 encryption 则不适用这个方法

### 设置无线网络

1. 安装  `NetworkManager`

   ```bash
   pacman -S networkmanager
   ```

2. 可选：替换网络后端为 `iwd`

   NetworkManager 的无线网默认后端是 wpa_supplicant，可以更换为更现代的 iwd。

     >注意：部分设备更换 `iwd` 后端可能无法正常联网。

     1. 安装 `iwd`

        ```bash
        pacman -S iwd
        ```

        >`impala` 是 `iwd` 的 TUI。

     2. 编辑配置文件

        ```bash
        # 创建配置文件目录，-p 代表如果已经存在就跳过
        mkdir -p /etc/NetworkManager/conf.d
        
        # 新建文件并用 vim 进行编辑
        vim /etc/NetworkManager/conf.d/iwd.conf
        ```

        写入：

        ```ini
        [device]
        wifi.backend=iwd
        ```

3. 启用  `NetworkManager` 服务

   ```bash
   systemctl enable NetworkManager
   ```

   - `systemctl` 调用 systemd 进行操作。

   - `enable` 代表从下一次开机开始自动启动。

4. 连接无线网络

   ```bash
   nmtui
   ```

   `nmtui` 是 NetworkManager 提供的 TUI（终端用户交互程序）。

   - 选择 activate a connection
   - 选择自己的 wifi 进行连接
   - esc 退出

### 退出 chroot

```bash
exit
```

此时就回到了 Live 环境，可以注意到提示符的变化。

### 重启电脑

```bash
reboot
```

此时会自动取消所有的挂载。如果 U 盘没拔掉的话记得拔掉。

# AI 助手安装

使用 OpenCode 提供的免费开源大模型快速进行系统安装。

1. 安装 AI 助手

   ```bash
   pacman -Sy opencode
   ```

   `opencode` 命令打开 AI 助手，输入 `/models` 回车可以切换模型。默认的`BigPickle`模型就能完成 Arch Linux 的安装，如果你有自己也可以按照提示配置。

2. 给 AI 指令进行系统安装

   >因为 Live 环境没有中文输入法，只能用英文和 AI 交流，输入一些简单的短语就行，实在不懂的话让豆包帮忙翻译。

   以下是一个最小化的提示词示例，注意把 root 密码改成你自己的：

   ```text
   We are in the archiso live. First, increase the cowspace size. Then auto install archlinux. Root passwd: shorin.

   # 我们现在在 archiso 的 live 环境里。首先扩大 cowspace 的大小，然后自动安装 archlinux。Root 密码设置为 shorin。
   ```
   > 无论你怎么写提示词，都必须先告诉 AI 现在在 Arch Linux 的 Live 环境中，然后第一件事情必须是增加 cowspace 大小，否则运行空间会不够用。

   你也可以带上更具体的需求，不过更推荐的用法是让 AI 按照这篇文档进行安装。OpenCode 自带了网络搜索和网页爬取工具：

   ```text
   We are in the archiso live. First, increase the cowspace size. Then install archlinux following the guide from github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide.
   ```
   此时 AI 会根据文档的步骤向你确认一系列事情。

3. 重启

   安装完成后发送 `reboot` 给 AI，AI 会帮你重启电脑。
