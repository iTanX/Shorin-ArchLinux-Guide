#!/usr/bin/env bash
# 1 使用交互式安装脚本
# 在 Arch ISO Live 的交互终端中以 root 执行：bash install-arch.sh。
# 步骤编号对应手动安装文档的标题层级：二级标题为 1、2、3，子步骤为 1.1、1.1.1。
# 2 方案简述
# x64 UEFI/GPT、Btrfs 子卷、GRUB、Swap 文件、NetworkManager + iwd。
set -euo pipefail
set +x

TARGET=/mnt
STAGE=环境检查
WORK=
SWAP_ACTIVE=0
declare -a MOUNTS=()
# 加载脚本时保存同目录配置路径，供联网步骤使用。
WIFI_CONFIG=${BASH_SOURCE[0]}
WIFI_CONFIG="$(dirname -- "$WIFI_CONFIG")/wifi.conf"

# 交互与资源清理：统一输出步骤名称，并在退出时释放本次安装使用的资源。
say() { printf '\n%s\n' "$*" >&2; }
step() { STAGE="$1 $2"; say "==> [$1] $2"; }
fail() { say "错误：$*"; exit 1; }
ask() { read -r -p "$1" "$2" </dev/tty; }
confirm() {
    local answer
    ask "$1 [y/N]：" answer
    [[ $answer == y || $answer == Y ]]
}
cleanup() {
    local status=$? i
    trap - EXIT
    if (( status != 0 )); then
        say "安装在「${STAGE}」阶段停止（退出码 ${status}）。已写入的分区和数据不会自动回滚。"
    fi
    local cleanup_failed=0
    if (( SWAP_ACTIVE )) && ! swapoff "$TARGET/swap/swapfile"; then
        say '未能停用本次 Swap，请手动检查。'
        cleanup_failed=1
    fi
    for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
        if ! umount "${MOUNTS[i]}"; then
            say "未能卸载 ${MOUNTS[i]}，请手动检查。"
            cleanup_failed=1
        fi
    done
    if (( status == 0 && cleanup_failed )); then
        status=1
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$status"
}

# 3 准备工作
# 3.1 从 Live CD 启动：检查 Live 环境、权限和安装工具。
check_environment() {
    step 3.1 '从 Live CD 启动：检查安装环境'
    [[ $EUID == 0 ]] || fail '请在 Arch Live 中以 root 运行。'
    [[ -e /run/archiso ]] || fail '未检测到 Arch ISO Live 环境。'
    [[ $(uname -m) == x86_64 ]] || fail '仅支持 x86_64。'
    # 3.2 确认固件类型：安装介质必须以 64 位 UEFI 模式启动。
    step 3.2 '确认固件类型：64 位 UEFI'
    [[ -r /sys/firmware/efi/fw_platform_size ]] || fail '请使用 UEFI 启动安装介质。'
    [[ $(</sys/firmware/efi/fw_platform_size) == 64 ]] || fail '仅支持 64 位 UEFI。'
    [[ -t 0 && -t 1 ]] || fail '请在交互终端中运行，不要通过管道执行脚本。'
    local cmd
    for cmd in python3 lsblk sfdisk wipefs blkid blockdev udevadm curl iwctl \
        timedatectl reflector install pacstrap genfstab arch-chroot mkfs.fat \
        mkfs.btrfs btrfs mount umount findmnt swapon swapoff cmp; do
        command -v "$cmd" >/dev/null || fail "缺少工具：$cmd，请使用最新的官方 Arch ISO。"
    done
    # 不接管其他安装流程留下的挂载点或 Swap 文件。
    if findmnt -rn -o TARGET | python3 -c 'import sys; sys.exit(not any(x.strip() == "/mnt" or x.strip().startswith("/mnt/") for x in sys.stdin))'; then
        fail '/mnt 或其子目录已挂载，请先处理原有安装环境。'
    fi
    WORK=$(mktemp -d /tmp/install-arch.XXXXXXXX)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

online() {
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 20 \
        --output /dev/null https://www.baidu.com/ >/dev/null 2>&1
}

# 3.3 连接网络
connect_network() {
    step 3.3 '连接网络'
    local iface= ssid= password= config line device
    # 3.3.1 直接访问百度，失败时进入 Wi-Fi 连接流程。
    step 3.3.1 '检测网络连接：访问百度'
    if ! online; then
        # 3.3.2 优先读取同目录配置自动连接，未填写配置时保留手工连接。
        step 3.3.2 '连接 Wi-Fi'
        systemctl start iwd
        config=$WIFI_CONFIG
        if [[ -f $config ]]; then
            # 按字面值读取，不执行配置内容；等号后可包含空格、$、# 等字符。
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%$'\r'}
                case "$line" in
                    WIFI_SSID=*) ssid=${line#*=} ;;
                    WIFI_PASSWORD=*) password=${line#*=} ;;
                    WIFI_INTERFACE=*) iface=${line#*=} ;;
                esac
            done < "$config"
        fi
        if [[ -n $ssid || -n $password ]]; then
            [[ -n $ssid && -n $password ]] || fail '请在 wifi.conf 中填写 WIFI_SSID 和 WIFI_PASSWORD。'
            # 未指定网卡时使用第一个无线设备，无需手工输入设备名称。
            if [[ -z $iface ]]; then
                for device in /sys/class/net/*/phy80211; do
                    [[ -e $device ]] || continue
                    iface=${device%/phy80211}
                    iface=${iface##*/}
                    break
                done
            fi
            [[ -n $iface && $iface != */* && -e /sys/class/net/$iface/phy80211 ]] || fail '未找到配置所需的无线设备。'
            say '无法访问百度，正在使用 wifi.conf 连接 Wi-Fi。'
            if iwctl --passphrase "$password" station "$iface" connect "$ssid" && online; then
                step 3.3.3 '确认网络连接：Wi-Fi 可用'
                return
            fi
            fail '配置中的 Wi-Fi 连接失败或无法访问百度，请检查 wifi.conf 后重试。'
        fi
        say '无法访问百度。请连接 Wi-Fi（凭据仅用于当前 Live 环境）。'
        iwctl device list
        ask '无线设备名称（例如 wlan0）：' iface
        [[ -n $iface && $iface != */* && -e /sys/class/net/$iface/phy80211 ]] || fail '无线设备无效。'
        while true; do
            iwctl station "$iface" scan
            iwctl station "$iface" get-networks
            ask 'Wi-Fi 名称（SSID）：' ssid
            [[ -n $ssid ]] || continue
            say '接下来由 iwctl 提示输入 Wi-Fi 密码，输入时不会显示。'
            if iwctl station "$iface" connect "$ssid" </dev/tty && online; then
                break
            fi
            confirm '连接失败或无法访问网络，是否重试？' || fail '网络连接未完成。'
        done
    fi
    # 3.3.3 确认网络连接：前面的连接分支均已通过实际网络请求验证。
    step 3.3.3 '确认网络连接：网络可用'
}

# 3.4 激活 NTP；3.5 设置镜像源。
prepare_live() {
    step 3.4 '激活 NTP：等待系统时间同步'
    timedatectl set-ntp true
    local n synced=0
    for ((n=0; n<20; n++)); do
        if [[ $(timedatectl show -p NTPSynchronized --value) == yes ]]; then
            synced=1
            break
        fi
        sleep 2
    done
    (( synced )) || fail 'NTP 未同步，请检查网络和时间同步服务后重试。'
    # 3.5 设置镜像源：筛选最近 12 小时更新的中国 HTTPS 镜像。
    step 3.5 '设置镜像源：中国 HTTPS 镜像，按下载速度排序'
    reflector --protocol https --age 12 --country China --verbose --sort rate \
        --save "$WORK/mirrorlist"
    [[ -s $WORK/mirrorlist ]] || fail '没有生成镜像列表。'
    install -m 644 "$WORK/mirrorlist" /etc/pacman.d/mirrorlist
}

# 安装参数预采集：供 5.2 配置 Swap、6.4 设置主机名使用，写盘前完成输入校验。
collect_settings() {
    STAGE='安装参数预采集'
    say '安装参数：输入主机名（用于步骤 6.4）和 Swap 容量（用于步骤 5.2）。'
    while true; do
        ask '主机名（1–63 位英文字母、数字、连字符，首尾不能为连字符）：' HOSTNAME_VALUE
        [[ ${#HOSTNAME_VALUE} -le 63 && $HOSTNAME_VALUE =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] && break
        say '主机名格式不正确，请重新输入。'
    done
    while true; do
        ask 'Swap 大小（整数 GiB，输入 0 禁用，不配置休眠）：' SWAP_GIB
        [[ $SWAP_GIB =~ ^(0|[1-9][0-9]{0,4})$ ]] && break
        say '请输入不含前导零的非负整数。'
    done
}

# 4 硬盘分区
# 4.1 创建分区；4.2 格式化分区。
# 使用结构化磁盘信息计算分区边界，确认目标后再执行写盘和格式化。
prepare_storage() {
    python3 - "$WORK/devices" <<'PY_STORAGE'
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ESP_TYPE = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
LINUX_TYPE = '0fc63daf-8483-4772-8e79-3d69d8477de4'
MIB = 1024 ** 2
ESP_BYTES = 512 * MIB


def run(args, *, data=None, check=True):
    return subprocess.run(args, input=data, text=True, capture_output=True, check=check,
                          env={**os.environ, 'LC_ALL': 'C'})


def tell(text):
    print(text, file=sys.stderr, flush=True)


def step(number, title):
    tell(f'\n==> [{number}] {title}')


def prompt(text):
    # 终端不可 seek，不能用默认缓冲的 r+ 模式。
    with open('/dev/tty', 'w') as tty:
        tty.write(text)
        tty.flush()
    with open('/dev/tty', 'r') as tty:
        value = tty.readline()
    if not value:
        raise RuntimeError('输入结束，取消操作。')
    return value.strip()


def choose(title, choices):
    if not choices:
        raise RuntimeError(f'{title}：没有符合条件的选项。')
    tell('\n' + title)
    for i, (label, _) in enumerate(choices, 1):
        tell(f'  {i}. {label}')
    while True:
        answer = prompt('输入编号（q 退出）：')
        if answer.lower() == 'q':
            raise RuntimeError('用户取消。')
        if answer.isascii() and answer.isdigit() and 1 <= int(answer) <= len(choices):
            return choices[int(answer) - 1][1]
        tell('编号无效，请重试。')


def size_text(size):
    return f'{size / 1024 ** 3:.2f} GiB'


def walk(node):
    yield node
    for child in node.get('children', []):
        yield from walk(child)


def available_disk(node):
    # 整盘被占用时不追加分区；也保护 Live 启动盘及各类活动映射。
    return not any(n.get('ro') or any(n.get('mountpoints') or []) or
                   n.get('type') not in ('disk', 'part') for n in walk(node))


def scan_disks():
    fields = 'NAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINTS,PARTTYPE,PARTUUID,RO,MODEL,SERIAL,WWN,LOG-SEC'
    nodes = json.loads(run(['lsblk', '--json', '--bytes', '--paths', '--output', fields]).stdout)['blockdevices']
    disks = []
    for node in nodes:
        if node['type'] != 'disk' or not available_disk(node):
            continue
        path = node['path']
        result = run(['sfdisk', '--json', path], check=False)
        table = None
        if result.returncode == 0:
            table = json.loads(result.stdout)['partitiontable']
            if table['label'] != 'gpt':
                continue
        else:
            signatures = json.loads(run(['wipefs', '--json', path]).stdout)['signatures']
            if signatures:
                continue
        sector = int(node['log-sec'])
        total = int(node['size']) // sector
        entries = math.ceil(128 * 128 / sector)
        first = int(table['firstlba']) if table else 2 + entries
        last = int(table['lastlba']) if table else total - entries - 2
        children = {n['path']: n for n in walk(node) if n['type'] == 'part'}
        partitions = table.get('partitions', []) if table else []
        # diskseq 区分先后占用同一路径的设备，补充无序列号 USB 磁盘的身份检查。
        diskseq = (Path('/sys/class/block') / Path(path).name / 'diskseq').read_text().strip()
        identity = (node.get('serial'), node.get('wwn'), diskseq)
        disks.append(dict(path=path, size=int(node['size']), sector=sector,
                          first=first, last=last, table=table, children=children,
                          partitions=partitions, identity=identity))
    return disks


def free_regions(disk, reserved=()):
    alignment = max(1, MIB // disk['sector'])
    used = [(p['start'], p['start'] + p['size'] - 1) for p in disk['partitions']]
    used += [(p['start'], p['start'] + p['size'] - 1) for p in reserved if p['disk'] == disk['path']]
    cursor = disk['first']
    regions = []
    for start, end in sorted(used) + [(disk['last'] + 1, disk['last'] + 1)]:
        aligned = ((cursor + alignment - 1) // alignment) * alignment
        stop = (start // alignment) * alignment
        if stop > aligned:
            regions.append(dict(disk=disk['path'], start=aligned, size=stop - aligned,
                                sector=disk['sector']))
        cursor = max(cursor, end + 1)
    return regions


def region_label(region):
    return (f"{region['disk']} 未分配空间 {size_text(region['size'] * region['sector'])} "
            f"（起始扇区 {region['start']}）")


def make_partition(region, esp=False):
    part = dict(region)
    if esp:
        part['size'] = ESP_BYTES // part['sector']
    part.update(new=True, uuid=str(uuid.uuid4()), type=ESP_TYPE if esp else LINUX_TYPE)
    return part


def existing_partition(disk, part):
    return dict(disk=disk['path'], path=part['node'], start=part['start'], size=part['size'],
                sector=disk['sector'], uuid=part['uuid'], type=part['type'], new=False)


def select_plan(disks):
    esps = []
    roots = []
    for disk in disks:
        for part in disk['partitions']:
            node = disk['children'].get(part['node'], {})
            info = existing_partition(disk, part)
            label = f"{part['node']} {size_text(part['size'] * disk['sector'])} {node.get('fstype') or '无文件系统签名'}"
            if part['type'].lower() == ESP_TYPE:
                if node.get('fstype') == 'vfat':
                    esps.append((label, info))
            else:
                roots.append((label, info))
    # 4.1.1 选择 EFI 分区：复用已有 ESP，或选择未分配空间新建独立 ESP。
    step('4.1.1', '选择 EFI 分区（ESP）')
    if esps:
        mode = choose('已存在 ESP：请选择复用或新建（复用时不格式化）',
                      [('复用已有 ESP', 'reuse'), ('新建独立 512 MiB ESP', 'new')])
    else:
        tell('没有可复用的空闲 FAT ESP，需要新建独立 ESP。')
        mode = 'new'
    if mode == 'reuse':
        esp = choose('选择已有 ESP', esps)
    else:
        choices = [(region_label(r), r) for d in disks for r in free_regions(d)
                   if r['size'] * r['sector'] >= ESP_BYTES]
        esp = make_partition(choose('选择新 ESP 所在的未分配空间', choices), esp=True)
    # 4.1.2 选择根分区：允许格式化已有分区，或使用未分配空间创建分区。
    step('4.1.2', '选择根分区或创建根分区的未分配空间')
    regions = [r for d in disks for r in free_regions(d, [esp] if esp['new'] else [])]
    root_choices = [('格式化已有分区：' + label, info) for label, info in roots]
    root_choices += [('在此创建根分区：' + region_label(r), make_partition(r)) for r in regions]
    root = choose('选择根分区（新建时使用所选区间的全部剩余空间）', root_choices)
    return esp, root


def inspect_esp(esp):
    if esp['new']:
        return False
    directory = tempfile.mkdtemp(prefix='install-arch-esp-')
    mounted = False
    try:
        run(['mount', '-t', 'vfat', '-o', 'ro,nosuid,nodev,noexec', esp['path'], directory])
        mounted = True
        return (Path(directory) / 'EFI/ARCH').exists()
    finally:
        # 卸载失败时保留目录，绝不递归删除仍挂载的 ESP 内容。
        if mounted:
            run(['umount', directory])
        os.rmdir(directory)


# 4.1.3 确认分区计划：确认 GPT 初始化、引导文件覆盖和根分区格式化。
def confirm_plan(disks, esp, root):
    step('4.1.3', '确认分区计划和数据删除范围')
    tell('即将执行的磁盘操作：')
    for title, part in [('ESP', esp), ('根分区', root)]:
        action = '新建并格式化' if part['new'] else ('复用，不格式化；GRUB 将写入 EFI/ARCH' if title == 'ESP' else '格式化并删除原有数据')
        tell(f"  {title}：{part.get('path', part['disk'])}；{action}；"
             f"起始扇区 {part['start']}，{size_text(part['size'] * part['sector'])}")
    if esp.get('has_arch'):
        expected = 'OVERWRITE ARCH ' + esp['path']
        tell('ESP 已有 EFI/ARCH；继续会替换其中的 GRUB 引导文件，可能改变另一套 Arch 的启动行为。')
        if prompt(f'确认覆盖请输入 {expected}（取消可重新选择其他 ESP）：') != expected:
            raise RuntimeError('未确认覆盖已有 ARCH 引导文件。')
    selected = {esp['disk'], root['disk']}
    for disk in disks:
        if disk['path'] in selected and disk['table'] is None:
            expected = 'GPT ' + disk['path']
            if prompt(f'磁盘无可识别的分区表或签名，仍可能有数据；将创建 GPT，请输入 {expected} 确认：') != expected:
                raise RuntimeError('未确认创建 GPT。')
    if not root['new']:
        tell('所选已有根分区视为非空。即使未检测到签名，也可能包含数据；格式化会删除数据。')
        if prompt(f"请输入准确设备路径 {root['path']} 确认格式化：") != root['path']:
            raise RuntimeError('未确认格式化根分区。')
    if prompt('输入 INSTALL 确认上述全部操作（其他输入取消）：') != 'INSTALL':
        raise RuntimeError('用户取消；尚未修改磁盘。')


def verify_unchanged(before, after):
    if before['identity'] != after['identity']:
        raise RuntimeError(f"{before['path']} 设备身份已变化，拒绝写入。")
    if before['size'] != after['size'] or before['sector'] != after['sector'] or before['table'] != after['table']:
        raise RuntimeError(f"{before['path']} 布局已变化，请重新运行并选择。")


# 4.1.4 保存分区：复核设备与布局，预演后写入新分区。
def write_partitions(disks, esp, root):
    step('4.1.4', '复核磁盘布局并保存新分区')
    selected = {esp['disk'], root['disk']}
    current = {d['path']: d for d in scan_disks()}
    for disk in disks:
        if disk['path'] in selected:
            if disk['path'] not in current:
                raise RuntimeError('所选磁盘已被占用或不可用。')
            verify_unchanged(disk, current[disk['path']])
    for disk in disks:
        parts = sorted([p for p in (esp, root) if p['new'] and p['disk'] == disk['path']], key=lambda p: p['start'])
        if not parts:
            continue
        script = '' if disk['table'] else 'label: gpt\nunit: sectors\n\n'
        script += ''.join(f"start={p['start']}, size={p['size']}, type={p['type']}, uuid={p['uuid']}\n" for p in parts)
        args = ['sfdisk', '--lock=yes', '--wipe', 'never', '--wipe-partitions', 'never']
        if disk['table']:
            args.append('--append')
        # 预演与实际写入使用相同边界；不让工具自行挑选空闲区域。
        run(args + ['--no-act', disk['path']], data=script)
        tell(run(args + [disk['path']], data=script).stdout)
        run(['udevadm', 'settle'])
        actual = json.loads(run(['sfdisk', '--json', disk['path']]).stdout)['partitiontable']
        actual_parts = {p['uuid'].lower(): p for p in actual.get('partitions', [])}
        for old in disk['partitions']:
            if actual_parts.get(old['uuid'].lower()) != old:
                raise RuntimeError('已有分区信息与写入前不一致，停止后续操作。')
        for part in parts:
            created = actual_parts.get(part['uuid'].lower())
            if not created or (created['start'], created['size'], created['type'].lower()) != (part['start'], part['size'], part['type']):
                raise RuntimeError('新分区与计划不一致。')
            part['path'] = created['node']
            # 同时检查内核识别的大小，避免在旧分区映射上格式化。
            if int(run(['blockdev', '--getsize64', part['path']]).stdout) != part['size'] * part['sector']:
                raise RuntimeError('内核未正确识别新分区，请重启 Live 后检查。')


# 4.2 格式化分区
def format_partitions(esp, root):
    step('4.2', '格式化分区')
    # 4.2.1 再次查看分区情况：核对内核中的设备身份和容量。
    step('4.2.1', '核对格式化目标的设备身份和容量')
    for part in (esp, root):
        actual_uuid = run(['lsblk', '--nodeps', '--noheadings', '--output', 'PARTUUID', part['path']]).stdout.strip()
        actual_size = int(run(['blockdev', '--getsize64', part['path']]).stdout)
        if actual_uuid.lower() != part['uuid'].lower() or actual_size != part['size'] * part['sector']:
            raise RuntimeError('设备身份或大小与已确认计划不一致，拒绝格式化。')
    # 4.2.2 格式化 EFI 分区：仅对本次新建的 ESP 创建 FAT32 文件系统。
    if esp['new']:
        step('4.2.2', '格式化新建 ESP：FAT32')
        tell(run(['mkfs.fat', '-F', '32', esp['path']]).stdout)
    else:
        step('4.2.2', '复用已有 ESP：保留文件系统，跳过格式化')
    # 4.2.3 格式化 Btrfs 根分区。
    step('4.2.3', '格式化根分区：Btrfs')
    tell(run(['mkfs.btrfs', '-f', root['path']]).stdout)


def main():
    step('4.1', '创建分区：查看磁盘和未分配空间')
    subprocess.run(['lsblk', '-o', 'NAME,PATH,SIZE,MODEL,FSTYPE,MOUNTPOINTS'], check=True, stdout=sys.stderr)
    disks = scan_disks()
    if not disks:
        raise RuntimeError('没有可安装的 GPT 磁盘或无签名空盘；已挂载/被占用的磁盘和非 GPT 磁盘不会显示。')
    tell('仅提供未挂载且未被占用的 GPT 磁盘或无签名空盘；不自动缩容任何文件系统。')
    esp, root = select_plan(disks)
    esp['has_arch'] = inspect_esp(esp)
    confirm_plan(disks, esp, root)
    write_partitions(disks, esp, root)
    format_partitions(esp, root)
    Path(sys.argv[1]).write_text(root['path'] + '\n' + esp['path'] + '\n')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError, ValueError, KeyError) as exc:
        tell(f'磁盘准备失败：{exc}')
        if isinstance(exc, subprocess.CalledProcessError):
            tell(exc.stderr or '')
        sys.exit(1)
PY_STORAGE
}

# 4.3 创建子卷；4.4 挂载子卷。
mount_target() {
    step 4.3 '创建子卷'
    local -a devices
    mapfile -t devices < "$WORK/devices"
    ROOT_DEVICE=${devices[0]}
    ESP_DEVICE=${devices[1]}
    # 4.3.1 挂载 Btrfs 顶层，准备创建子卷。
    step 4.3.1 '挂载 Btrfs 根分区'
    mount "$ROOT_DEVICE" "$TARGET"
    MOUNTS+=("$TARGET")
    # 4.3.2 创建 root、home 和 Swap 子卷。
    step 4.3.2 '创建 @、@home、@swap 子卷'
    btrfs subvolume create "$TARGET/@"
    btrfs subvolume create "$TARGET/@home"
    btrfs subvolume create "$TARGET/@swap"
    # 4.3.3 取消顶层挂载，切换到子卷挂载方式。
    step 4.3.3 '取消 Btrfs 顶层挂载'
    umount "$TARGET"
    MOUNTS=()
    step 4.4 '挂载子卷和 EFI 分区'
    # 4.4.1 挂载 root 子卷。
    step 4.4.1 '挂载 @ 到 /mnt'
    mount -o subvol=/@,compress=zstd "$ROOT_DEVICE" "$TARGET"
    MOUNTS+=("$TARGET")
    # 4.4.2 挂载 home 子卷。
    step 4.4.2 '挂载 @home 到 /mnt/home'
    mount --mkdir -o subvol=/@home,compress=zstd "$ROOT_DEVICE" "$TARGET/home"
    MOUNTS+=("$TARGET/home")
    # 4.4.3 挂载 Swap 子卷。
    step 4.4.3 '挂载 @swap 到 /mnt/swap'
    mount --mkdir -o subvol=/@swap,compress=zstd "$ROOT_DEVICE" "$TARGET/swap"
    MOUNTS+=("$TARGET/swap")
    # 4.4.4 挂载 EFI 分区。
    step 4.4.4 '挂载 ESP 到 /mnt/efi'
    mount --mkdir "$ESP_DEVICE" "$TARGET/efi"
    MOUNTS+=("$TARGET/efi")
}

# 5 安装系统
install_base() {
    # 5.1 基础安装：识别 CPU 微码，安装系统、网络和引导软件包。
    step 5.1 '基础安装：识别 CPU 并安装软件包'
    local vendor
    local -a packages=(base linux linux-firmware btrfs-progs vim sudo networkmanager iwd openssh grub efibootmgr os-prober fuse3)
    vendor=$(python3 -c 'import re; from pathlib import Path; m=re.search(r"^vendor_id\s*:\s*(\S+)", Path("/proc/cpuinfo").read_text(), re.M); print(m[1] if m else "")')
    case "$vendor" in
        GenuineIntel) packages+=(intel-ucode) ;;
        AuthenticAMD) packages+=(amd-ucode) ;;
        *) say "未识别 CPU 厂商（$vendor），不安装专用微码。" ;;
    esac
    pacstrap -K "$TARGET" "${packages[@]}"
    # 5.2 配置 Swap：容量为 0 时跳过创建和启用。
    step 5.2 "配置 Swap：${SWAP_GIB} GiB"
    if (( SWAP_GIB > 0 )); then
        # 5.2.1 创建 Swap 文件。
        step 5.2.1 '在 @swap 子卷中创建 Swap 文件'
        btrfs filesystem mkswapfile --size "${SWAP_GIB}g" --uuid clear "$TARGET/swap/swapfile"
        # 5.2.2 启用 Swap。
        step 5.2.2 '启用 Swap 文件'
        swapon "$TARGET/swap/swapfile"
        SWAP_ACTIVE=1
    else
        say 'Swap 容量为 0，跳过创建和启用。'
    fi
    # 5.3 生成 fstab 文件：使用 UUID 保存分区与子卷挂载信息。
    step 5.3 '生成 fstab 文件'
    genfstab -U "$TARGET" > "$TARGET/etc/fstab"
}

# 6.3.1 本地化配置：解除中英文 locale 的注释，并设置英文系统语言。
configure_locale() {
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(en_US[.]UTF-8[[:space:]]+UTF-8|zh_CN[.]UTF-8[[:space:]]+UTF-8)[[:space:]]*$/\1/' "$TARGET/etc/locale.gen"
    local config="$TARGET/etc/locale.conf"
    if [[ -f $config ]] && grep -qE '^[[:space:]]*#?[[:space:]]*LANG[[:space:]]*=' "$config"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*LANG[[:space:]]*=.*/LANG=en_US.UTF-8/' "$config"
    else
        printf 'LANG=en_US.UTF-8\n' >> "$config"
    fi
}

# 6.6.2 编辑 GRUB 配置：启用已有示例，缺少对应项时才新增。
configure_grub() {
    local config="$TARGET/etc/default/grub" setting key
    # 记忆上次选择的启动项，同时保留其他系统检测。
    for setting in GRUB_DEFAULT=saved GRUB_SAVEDEFAULT=true GRUB_DISABLE_OS_PROBER=false; do
        key=${setting%%=*}
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$config"; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*/${setting}/" "$config"
        else
            printf '\n%s\n' "$setting" >> "$config"
        fi
    done
}

# 6.7.1 配置 iwd 后端：只修改专用的 iwd.conf。
configure_network_backend() {
    local config="$TARGET/etc/NetworkManager/conf.d/iwd.conf"
    mkdir -p "${config%/*}"
    if [[ -f $config ]]; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*\[device\][[:space:]]*$/[device]/; s/^[[:space:]]*#?[[:space:]]*wifi[.]backend[[:space:]]*=.*/wifi.backend=iwd/' "$config"
        if ! grep -qx '\[device\]' "$config"; then
            printf '\n[device]\nwifi.backend=iwd\n' >> "$config"
        elif ! grep -q '^wifi[.]backend=' "$config"; then
            sed -i '/^\[device\]$/a\
wifi.backend=iwd
' "$config"
        fi
    else
        printf '[device]\nwifi.backend=iwd\n' > "$config"
    fi
}

# 6.7.3 按需保存目标系统的无线连接，首次启动后由 NetworkManager 自动连接。
configure_target_wifi() {
    step 6.7.3 '配置目标系统的 Wi-Fi 自动连接'
    if ! confirm '是否需要在目标系统使用无线网络（读取 wifi.conf，首次启动时自动连接）？'; then
        return 0
    fi
    local ssid= password= iface= line
    [[ -f $WIFI_CONFIG ]] || fail '未找到 wifi.conf，请先填写无线网络配置。'
    # 与 Live 联网步骤使用相同格式，按字面值读取名称、密码和可选网卡。
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        case "$line" in
            WIFI_SSID=*) ssid=${line#*=} ;;
            WIFI_PASSWORD=*) password=${line#*=} ;;
            WIFI_INTERFACE=*) iface=${line#*=} ;;
        esac
    done < "$WIFI_CONFIG"
    [[ -n $ssid && -n $password ]] || fail '请在 wifi.conf 中填写 WIFI_SSID 和 WIFI_PASSWORD。'
    local profile="$TARGET/etc/NetworkManager/system-connections/install-wifi.nmconnection"
    local -a connection=(type wifi con-name install-wifi ssid "$ssid"
        connection.autoconnect yes wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password")
    [[ -z $iface ]] || connection+=(ifname "$iface")
    mkdir -p "${profile%/*}"
    # 密钥文件仅允许 root 读写；离线生成配置，不调用 Live 的 NetworkManager。
    install -m 600 /dev/null "$profile"
    arch-chroot "$TARGET" nmcli --offline connection add "${connection[@]}" > "$profile"
    say '目标系统 Wi-Fi 配置已保存，重启进入目标系统后将自动连接。'
}

# 6 基础设置
configure_target() {
    # 6.1 更换根目录：每条目标系统命令都通过 arch-chroot 执行。
    step 6.1 '更换根目录：通过 arch-chroot 配置目标系统'
    # 6.2 设置时区和时间。
    step 6.2 '设置时区和时间'
    # 6.2.1 设置时区。
    step 6.2.1 '设置时区：Asia/Shanghai'
    arch-chroot "$TARGET" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    [[ $(readlink "$TARGET/etc/localtime") == /usr/share/zoneinfo/Asia/Shanghai ]] || fail '目标时区链接不正确。'
    # 6.2.2 同步硬件时间。
    step 6.2.2 '将系统时间同步到硬件时钟'
    arch-chroot "$TARGET" hwclock --systohc
    # 6.3 本地化设置。
    step 6.3 '本地化设置'
    step 6.3.1 '编辑 locale.gen 和 locale.conf：启用中英文 locale，系统语言设为英文'
    configure_locale
    # 6.3.2 生成本地化配置。
    step 6.3.2 '生成本地化配置'
    arch-chroot "$TARGET" locale-gen
    # 6.4 设置主机名。
    step 6.4 "设置主机名：${HOSTNAME_VALUE}"
    printf '%s\n' "$HOSTNAME_VALUE" > "$TARGET/etc/hostname"
    # 6.5 设置 root 密码：passwd 隐藏读取并确认密码。
    step 6.5 '设置 root 密码'
    say '请按 passwd 提示输入两次 root 密码，输入时不显示。'
    arch-chroot "$TARGET" passwd root </dev/tty
    # 6.6 安装引导程序：软件包已在 5.1 基础安装中安装。
    step 6.6 '安装引导程序：GRUB'
    # 6.6.1 安装 GRUB EFI 文件并注册 UEFI 启动项。
    step 6.6.1 '安装 GRUB 到 ESP，注册 ARCH 启动项'
    arch-chroot "$TARGET" grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ARCH
    # 6.6.2 编辑 GRUB 配置。
    step 6.6.2 '编辑 GRUB 配置：启用启动项记忆和其他系统检测'
    configure_grub
    # 6.6.3 生成启动流程 grub.cfg。
    step 6.6.3 '生成 GRUB 启动配置'
    arch-chroot "$TARGET" grub-mkconfig -o /boot/grub/grub.cfg
    # 6.6.4 初始化 Btrfs 环境块，使 GRUB 能保存上次选择的启动项。
    step 6.6.4 '初始化 Btrfs 环境块并查看环境变量'
    arch-chroot "$TARGET" grub-editenv - set ok=1
    arch-chroot "$TARGET" grub-editenv - list
    # 6.7 设置无线网络：软件包已在 5.1 基础安装中安装。
    step 6.7 '设置无线网络：NetworkManager + iwd'
    step 6.7.1 '配置 NetworkManager 的 iwd 后端'
    configure_network_backend
    # 6.7.2 启用 NetworkManager 服务。
    step 6.7.2 '启用 NetworkManager 开机自启'
    arch-chroot "$TARGET" systemctl enable NetworkManager
    configure_target_wifi
}

# 6.8 桌面环境前置准备：在目标系统中完成需要 root 执行的用户初始化。
# 6.8.1 全局文本编辑器：设置 EDITOR=vim，优先修改已有配置或注释示例。
configure_editor() {
    step 6.8.1 '设置目标系统全局编辑器：vim'
    if grep -qE '^[[:space:]]*#?[[:space:]]*EDITOR[[:space:]]*=' "$TARGET/etc/environment"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*EDITOR[[:space:]]*=.*/EDITOR=vim/' "$TARGET/etc/environment"
    else
        printf '\nEDITOR=vim\n' >> "$TARGET/etc/environment"
    fi
}

# 6.8.2 创建普通用户：账户、home 目录和密码均位于目标系统。
create_user() {
    local username
    step 6.8.2 '创建普通用户'
    # 6.8.2.1 新建用户，同时创建 home 目录并加入 wheel 组。
    step 6.8.2.1 '新建普通用户并加入 wheel 组'
    # 创建失败时保留当前安装流程，允许更正用户名后重试。
    while true; do
        ask '用户名：' username
        if arch-chroot "$TARGET" useradd -mG wheel -- "$username"; then
            break
        fi
        say '用户创建失败，请根据以上错误重新输入用户名；按 Ctrl+C 可取消。'
    done
    # 6.8.2.2 设置用户密码，由 passwd 隐藏读取并确认。
    step 6.8.2.2 '设置普通用户密码'
    arch-chroot "$TARGET" passwd -- "$username" </dev/tty
}

# 6.8.3 配置 sudo 权限：启用 wheel 组权限，保留密码验证。
configure_sudo() {
    step 6.8.3 '启用目标系统 wheel 组 sudo 权限'
    if grep -qE '^[[:space:]]*#?[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$' "$TARGET/etc/sudoers"; then
        sed -i -E 's/^[[:space:]]*#?[[:space:]]*%wheel[[:space:]]+ALL=\(ALL:ALL\)[[:space:]]+ALL[[:space:]]*$/%wheel ALL=(ALL:ALL) ALL/' "$TARGET/etc/sudoers"
    else
        printf '\n%%wheel ALL=(ALL:ALL) ALL\n' >> "$TARGET/etc/sudoers"
    fi
    arch-chroot "$TARGET" visudo -c
}

# 6.8.4 开启 SSH：OpenSSH 已在 5.1 安装，按初始化文档允许 root 密码登录。
configure_ssh() {
    step 6.8.4 '配置 SSH 密码登录并启用开机自启'
    local config="$TARGET/etc/ssh/sshd_config" key
    # 优先修改已有配置或解除注释，缺少对应项时才追加。
    for key in PermitRootLogin PasswordAuthentication; do
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$config"; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*/${key} yes/" "$config"
        else
            printf '\n%s yes\n' "$key" >> "$config"
        fi
    done
    # chroot 中只设置开机自启，服务在目标系统启动后运行。
    arch-chroot "$TARGET" systemctl enable sshd
}

# 安装结果检查：校验启动文件、时区、locale、网络服务和 fstab。
verify_target() {
    STAGE='安装结果检查'
    say '检查安装结果：启动文件、时区、locale、网络服务、UEFI 启动项和 fstab。'
    local file
    for file in boot/vmlinuz-linux boot/initramfs-linux.img boot/grub/grub.cfg efi/EFI/ARCH/grubx64.efi etc/fstab; do
        [[ -s $TARGET/$file ]] || fail "目标系统缺少 $file。"
    done
    # 必须在目标根内解析绝对链接，不能由 Live 的根目录解析 /etc/localtime。
    arch-chroot "$TARGET" cmp -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || \
        fail '目标时区验证失败。'
    arch-chroot "$TARGET" systemctl is-enabled NetworkManager
    arch-chroot "$TARGET" locale -a | python3 -c \
        'import sys; a=sys.stdin.read().lower(); sys.exit(not ("en_us.utf8" in a and "zh_cn.utf8" in a))'
    # efibootmgr 输出包含启动项名称和对应 EFI 路径，不能仅凭 grub-install 返回成功。
    local esp_partuuid root_uuid esp_uuid
    esp_partuuid=$(blkid -s PARTUUID -o value "$ESP_DEVICE")
    root_uuid=$(blkid -s UUID -o value "$ROOT_DEVICE")
    esp_uuid=$(blkid -s UUID -o value "$ESP_DEVICE")
    arch-chroot "$TARGET" efibootmgr -v | python3 -c \
        'import re,sys; text=sys.stdin.read(); sys.exit(not any(re.search(r"\bARCH\b", s) and "\\EFI\\ARCH\\GRUBX64.EFI" in s.upper() and sys.argv[1].lower() in s.lower() for s in text.splitlines()))' "$esp_partuuid"
    python3 - "$TARGET/etc/fstab" "$SWAP_GIB" "$root_uuid" "$esp_uuid" <<'PY_FSTAB'
from pathlib import Path
import sys
rows = [s.split() for s in Path(sys.argv[1]).read_text().splitlines() if s.strip() and not s.lstrip().startswith('#')]
for point, subvol in (('/', '/@'), ('/home', '/@home'), ('/swap', '/@swap')):
    assert any(r[0] == 'UUID=' + sys.argv[3] and r[1] == point and r[2] == 'btrfs' and 'subvol=' + subvol in r[3].split(',') for r in rows), 'Btrfs fstab 条目不正确：' + point
assert any(r[0] == 'UUID=' + sys.argv[4] and r[1] == '/efi' and r[2] == 'vfat' for r in rows), 'ESP fstab 条目不正确'
assert any(r[0] == '/swap/swapfile' and r[2] == 'swap' for r in rows) == (int(sys.argv[2]) > 0), 'Swap 条目不正确'
PY_FSTAB
}

# 安装流程入口：按文档的二级标题组织主要阶段。
main() {
    step 1 '使用交互式安装脚本'
    say '安装流程：准备工作 → 硬盘分区 → 安装系统 → 基础设置 → 重启。'
    step 2 '方案简述'
    say '安装方案：x64 UEFI/GPT、Btrfs、GRUB、Swap 文件、NetworkManager + iwd。'
    step 3 '准备工作'
    check_environment
    connect_network
    prepare_live
    collect_settings
    step 4 '硬盘分区'
    prepare_storage
    mount_target
    step 5 '安装系统'
    install_base
    step 6 '基础设置'
    configure_target
    step 6.8 '桌面环境前置准备：编辑器、普通用户和 SSH'
    configure_editor
    create_user
    configure_sudo
    configure_ssh
    verify_target
    # 6.9 退出 chroot：目标系统命令执行完毕，后续操作均在 Live 环境中执行。
    step 6.9 '退出 chroot：目标系统配置完成，返回 Live 环境'
    say '安装完成。首次启动后以新建的普通用户登录，确认联网（需要时运行 nmtui），再执行 bash setup-desktop.sh 安装桌面。'
    # 6.10 重启电脑：用户确认后，先清理挂载再重启。
    step 6.10 '重启电脑'
    if confirm '现在卸载安装挂载并重启？'; then
        # 6.10.1 停用 Swap 并卸载分区；任一操作失败时停止重启流程。
        step 6.10.1 '停用 Swap 并卸载安装分区'
        local i
        if (( SWAP_ACTIVE )); then
            swapoff "$TARGET/swap/swapfile"
            SWAP_ACTIVE=0
        fi
        for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
            umount "${MOUNTS[i]}"
            unset 'MOUNTS[i]'
        done
        # 6.10.2 重启系统。
        step 6.10.2 '重启系统'
        reboot
    else
        say '已选择暂不重启。即将卸载本次安装挂载并返回 Live 环境，可稍后手动 reboot。'
    fi
}

# 允许测试只加载函数；直接执行脚本才开始安装。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
