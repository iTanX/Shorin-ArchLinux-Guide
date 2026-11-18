#!/usr/bin/env python3
"""安装器的无写盘测试：所有磁盘命令均替换为记录器。"""
import copy
import os
import re
from pathlib import Path
import subprocess
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'install-arch.sh'


def load_block(marker):
    source = SCRIPT.read_text()
    block = re.search(r"<<'" + marker + r"'\n(.*?)\n" + marker + r'\n', source, re.S)[1]
    module = types.ModuleType(marker)
    exec(compile(block, str(SCRIPT) + ':' + marker, 'exec'), module.__dict__)
    return module


storage = load_block('PY_STORAGE')


def disk(path='/dev/nvme0n1', sector=512):
    part = dict(node=path + 'p1', start=2048 * 512 // sector, size=1024 ** 3 // sector,
                type=storage.ESP_TYPE, uuid='11111111-1111-1111-1111-111111111111')
    table = dict(label='gpt', id='disk-id', device=path, unit='sectors',
                 firstlba=34, lastlba=20 * 1024 ** 3 // sector - 34,
                 sectorsize=sector, partitions=[part])
    return dict(path=path, size=20 * 1024 ** 3, sector=sector,
                first=table['firstlba'], last=table['lastlba'], table=table,
                partitions=table['partitions'], children={part['node']: {'fstype': 'vfat'}},
                identity=('serial', 'wwn', '42'))


def device_recorder(parts, commands):
    def fake(args, **kwargs):
        commands.append(args)
        part = next(p for p in parts if p['path'] == args[-1])
        if args[0] == 'lsblk':
            output = part['uuid']
        elif args[0] == 'blockdev':
            output = str(part['size'] * part['sector'])
        else:
            output = ''
        return types.SimpleNamespace(stdout=output)
    return fake


class StorageTests(unittest.TestCase):
    def test_terminal_prompt_works_on_non_seekable_device(self):
        master, slave = os.openpty()
        try:
            name = os.ttyname(slave)
            os.write(master, b'INSTALL\n')
            with patch.object(storage, 'open', side_effect=lambda path, mode: open(name, mode), create=True):
                self.assertEqual(storage.prompt('confirm: '), 'INSTALL')
        finally:
            os.close(master)
            os.close(slave)

    def test_reuse_esp_never_formats_it(self):
        d = disk()
        esp = storage.existing_partition(d, d['partitions'][0])
        root = dict(esp, path='/dev/sdb2', new=False)
        commands = []
        with patch.object(storage, 'run', side_effect=device_recorder([esp, root], commands)), patch.object(storage, 'tell'):
            storage.format_partitions(esp, root)
        self.assertEqual([c for c in commands if c[0].startswith('mkfs')], [['mkfs.btrfs', '-f', '/dev/sdb2']])

    def test_only_new_esp_is_formatted(self):
        esp = dict(path='/dev/sdb1', new=True, uuid='new-esp', size=1048576, sector=512)
        root = dict(path='/dev/sdc1', new=True, uuid='new-root', size=2097152, sector=512)
        commands = []
        with patch.object(storage, 'run', side_effect=device_recorder([esp, root], commands)), patch.object(storage, 'tell'):
            storage.format_partitions(esp, root)
        self.assertEqual([c for c in commands if c[0].startswith('mkfs')], [['mkfs.fat', '-F', '32', '/dev/sdb1'], ['mkfs.btrfs', '-f', '/dev/sdc1']])

    def test_stale_kernel_partition_identity_prevents_all_formatting(self):
        esp = dict(path='/dev/sdb1', new=True, uuid='expected', size=1048576, sector=512)
        actual = dict(esp, uuid='stale-partition')
        commands = []
        with patch.object(storage, 'run', side_effect=device_recorder([actual], commands)):
            with self.assertRaisesRegex(RuntimeError, '拒绝格式化'):
                storage.format_partitions(esp, esp)
        self.assertFalse(any(c[0].startswith('mkfs') for c in commands))

    def test_new_root_does_not_overlap_reserved_esp_or_existing_partition(self):
        for sector in (512, 4096):
            with self.subTest(sector=sector):
                d = disk(sector=sector)
                before = copy.deepcopy(d)
                region = storage.free_regions(d)[0]
                esp = storage.make_partition(region, esp=True)
                after = storage.free_regions(d, [esp])
                self.assertTrue(after)
                root = storage.make_partition(after[-1])
                self.assertGreaterEqual(root['start'], esp['start'] + esp['size'])
                self.assertEqual(esp['size'] * sector, 512 * 1024 ** 2)
                self.assertEqual(root['start'] * sector % storage.MIB, 0)
                self.assertEqual(d, before)
                self.assertLessEqual(root['start'] + root['size'] - 1, d['last'])

    def test_cross_disk_esp_selection(self):
        first, second = disk(), disk('/dev/nvme1n1')
        # 复用第一块磁盘的 ESP；从所有候选中选第二块磁盘的空闲空间。
        def choose(title, choices):
            if '已存在 ESP' in title:
                return 'reuse'
            if title == '选择已有 ESP':
                return choices[0][1]
            return next(value for label, value in choices if value['disk'] == second['path'])
        with patch.object(storage, 'choose', side_effect=choose):
            esp, root = storage.select_plan([first, second])
        self.assertEqual(esp['disk'], first['path'])
        self.assertEqual(root['disk'], second['path'])
        self.assertFalse(esp['new'])

    def test_any_existing_root_requires_exact_path_even_without_signature(self):
        d = disk()
        esp = storage.existing_partition(d, d['partitions'][0])
        root = dict(path='/dev/sdb2', disk='/dev/sdb', start=2048, size=100000,
                    sector=512, new=False)
        for answer in ('', 'yes', '/dev/sdb1'):
            with self.subTest(answer=answer), patch.object(storage, 'prompt', return_value=answer), patch.object(storage, 'run') as run, patch.object(storage, 'tell'):
                with self.assertRaisesRegex(RuntimeError, '未确认格式化'):
                    storage.confirm_plan([d], esp, root)
                run.assert_not_called()

    def test_cancel_final_confirmation_does_not_write(self):
        d = disk()
        esp = storage.existing_partition(d, d['partitions'][0])
        root = storage.make_partition(storage.free_regions(d)[0])
        with patch.object(storage, 'prompt', return_value=''), patch.object(storage, 'run') as run, patch.object(storage, 'tell'):
            with self.assertRaisesRegex(RuntimeError, '尚未修改磁盘'):
                storage.confirm_plan([d], esp, root)
            run.assert_not_called()

    def test_mounted_disk_and_live_medium_are_excluded(self):
        for point in ('/run/archiso/bootmnt', '/mnt', '[SWAP]'):
            node = dict(type='disk', children=[dict(type='part', mountpoints=[point])])
            self.assertFalse(storage.available_disk(node))
        self.assertFalse(storage.available_disk(dict(type='disk', children=[dict(type='crypt')])))
        self.assertTrue(storage.available_disk(dict(type='disk', children=[dict(type='part', mountpoints=[None])])))

    def test_changed_layout_stops_before_sfdisk(self):
        before = disk()
        after = copy.deepcopy(before)
        after['table']['partitions'][0]['size'] += 2048
        esp = storage.existing_partition(before, before['partitions'][0])
        root = storage.make_partition(storage.free_regions(before)[0])
        with patch.object(storage, 'scan_disks', return_value=[after]), patch.object(storage, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, '布局已变化'):
                storage.write_partitions([before], esp, root)
            run.assert_not_called()

    def test_hotplugged_replacement_disk_is_rejected(self):
        before = disk('/dev/sdb')
        before['table'] = None
        before['partitions'] = []
        after = copy.deepcopy(before)
        after['identity'] = ('serial', 'wwn', '43')
        with self.assertRaisesRegex(RuntimeError, '设备身份已变化'):
            storage.verify_unchanged(before, after)

    def test_existing_arch_boot_files_require_separate_confirmation(self):
        d = disk()
        esp = storage.existing_partition(d, d['partitions'][0])
        esp['has_arch'] = True
        root = storage.make_partition(storage.free_regions(d)[0])
        with patch.object(storage, 'prompt', return_value='INSTALL'), patch.object(storage, 'run') as run, patch.object(storage, 'tell'):
            with self.assertRaisesRegex(RuntimeError, '未确认覆盖'):
                storage.confirm_plan([d], esp, root)
            run.assert_not_called()

    def test_simulated_partition_creation_preserves_old_esp(self):
        for blank in (False, True):
            for sector in (512, 4096):
                with self.subTest(blank=blank, sector=sector):
                    d = disk(sector=sector)
                    if blank:
                        d['table'] = None
                        d['partitions'] = []
                    old_parts = copy.deepcopy(d['partitions'])
                    esp = storage.make_partition(storage.free_regions(d)[0], esp=True) if blank else storage.existing_partition(d, d['partitions'][0])
                    root = storage.make_partition(storage.free_regions(d, [esp] if blank else [])[0])
                    created = [p for p in (esp, root) if p['new']]
                    after = copy.deepcopy(d['table']) if d['table'] else {'label': 'gpt', 'partitions': []}
                    for i, part in enumerate(created, 2):
                        after['partitions'].append(dict(node=f'/dev/mock{i}', start=part['start'], size=part['size'], type=part['type'], uuid=part['uuid']))
                    commands = []
                    def fake(args, **kwargs):
                        commands.append((args, kwargs))
                        output = ''
                        if args[:2] == ['sfdisk', '--json']:
                            import json
                            output = json.dumps({'partitiontable': after})
                        elif args[0] in ('lsblk', 'blockdev'):
                            actual = next(p for p in after['partitions'] if p['node'] == args[-1])
                            output = actual['uuid'] if args[0] == 'lsblk' else str(actual['size'] * sector)
                        return types.SimpleNamespace(stdout=output)
                    with patch.object(storage, 'scan_disks', return_value=[copy.deepcopy(d)]), patch.object(storage, 'run', side_effect=fake), patch.object(storage, 'tell'):
                        storage.write_partitions([d], esp, root)
                        storage.format_partitions(esp, root)
                    self.assertEqual(d['partitions'], old_parts)
                    mkfs = [a for a, k in commands if a[0].startswith('mkfs')]
                    self.assertEqual(len(mkfs), 2 if blank else 1)
                    if not blank:
                        self.assertTrue(all(esp['path'] not in a for a in mkfs))
                    writes = [(a, k) for a, k in commands if a[0] == 'sfdisk' and '--json' not in a]
                    self.assertEqual(len(writes), 2)
                    self.assertIn('--no-act', writes[0][0])
                    self.assertNotIn('--no-act', writes[1][0])
                    self.assertEqual('--append' in writes[1][0], not blank)
                    self.assertIn(f"uuid={root['uuid']}", writes[1][1]['data'])

    def test_preflight_failure_prevents_real_partition_write(self):
        d = disk()
        esp = storage.existing_partition(d, d['partitions'][0])
        root = storage.make_partition(storage.free_regions(d)[0])
        with patch.object(storage, 'scan_disks', return_value=[d]), patch.object(storage, 'run', side_effect=subprocess.CalledProcessError(1, 'sfdisk')) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                storage.write_partitions([d], esp, root)
        self.assertEqual(run.call_count, 1)
        self.assertIn('--no-act', run.call_args.args[0])
        self.assertIn('--append', run.call_args.args[0])


class ConfigTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.directory = tempfile.TemporaryDirectory(prefix='arch-config-regression-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'etc/default').mkdir(parents=True)
        self.network = self.root / 'etc/NetworkManager/conf.d/iwd.conf'
        self.network.parent.mkdir(parents=True)
        (self.root / 'etc/locale.gen').write_text('#en_US.UTF-8 UTF-8\n#zh_CN.UTF-8 UTF-8\n#ja_JP.UTF-8 UTF-8\n')
        (self.root / 'etc/default/grub').write_text('#GRUB_DISABLE_OS_PROBER=false\n')

    def run_config(self, *functions):
        code = '''
source "$1"
TARGET="$2"
# 记录目标服务设置，避免执行真实 chroot 或操作宿主服务。
arch-chroot() { printf '%s\\0' "$@" >> "$TARGET/chroot.calls"; printf '\\n' >> "$TARGET/chroot.calls"; }
# 为 macOS 的 BSD sed 补充空备份后缀；只编辑临时目标目录。
sed() {
    if [[ $(uname -s) == Darwin && $1 == -i ]]; then
        shift
        command sed -i '' "$@"
    else
        command sed "$@"
    fi
}
for function in "${@:3}"; do "$function"; done
'''
        subprocess.run(['bash', '-c', code, 'config-check', str(SCRIPT), str(self.root), *functions],
                       check=True, capture_output=True, text=True)

    def test_commented_examples_are_enabled_without_new_entries(self):
        (self.root / 'etc/locale.conf').write_text('#LANG=old\n')
        self.run_config('configure_locale', 'configure_grub')
        self.assertEqual((self.root / 'etc/locale.gen').read_text(), 'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\n#ja_JP.UTF-8 UTF-8\n')
        self.assertEqual((self.root / 'etc/locale.conf').read_text(), 'LANG=en_US.UTF-8\n')
        self.assertEqual((self.root / 'etc/default/grub').read_text(), 'GRUB_DISABLE_OS_PROBER=false\n')

    def test_missing_keys_are_added_without_changing_other_settings(self):
        (self.root / 'etc/default/grub').write_text('GRUB_DEFAULT=0\n')
        self.run_config('configure_locale', 'configure_grub', 'configure_network_backend')
        self.assertEqual((self.root / 'etc/locale.conf').read_text(), 'LANG=en_US.UTF-8\n')
        self.assertEqual((self.root / 'etc/default/grub').read_text(), 'GRUB_DEFAULT=0\n\nGRUB_DISABLE_OS_PROBER=false\n')
        self.assertEqual(self.network.read_text(), '[device]\nwifi.backend=iwd\n')

    def test_ssh_configures_password_login_and_enables_only_target_service(self):
        config = self.root / 'etc/ssh/sshd_config'
        config.parent.mkdir()
        samples = (
            '#PermitRootLogin prohibit-password\n#PasswordAuthentication yes\n',
            'PermitRootLogin no\nPasswordAuthentication no\n',
            '# 其他配置\n',
        )
        for before in samples:
            with self.subTest(before=before):
                config.write_text(before)
                calls = self.root / 'chroot.calls'
                calls.unlink(missing_ok=True)
                # 重复执行不应新增重复配置，且不能启动 Live 中的 sshd。
                self.run_config('configure_ssh', 'configure_ssh')
                content = config.read_text()
                self.assertEqual(content.count('PermitRootLogin yes\n'), 1)
                self.assertEqual(content.count('PasswordAuthentication yes\n'), 1)
                if before.startswith('# 其他配置'):
                    self.assertTrue(content.startswith('# 其他配置\n'))
                rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
                self.assertEqual(rows, [[str(self.root), 'systemctl', 'enable', 'sshd']] * 2)

    def test_iwd_uses_existing_commented_section_and_only_changes_dedicated_file(self):
        self.network.write_text('# comment\n#[device]\n#wifi.backend=wpa_supplicant\n[logging]\nlevel=INFO\n')
        other = self.root / 'etc/NetworkManager/NetworkManager.conf'
        other.write_text('#wifi.backend=wpa_supplicant\n')
        self.run_config('configure_network_backend')
        self.assertEqual(self.network.read_text(), '# comment\n[device]\nwifi.backend=iwd\n[logging]\nlevel=INFO\n')
        self.assertEqual(other.read_text(), '#wifi.backend=wpa_supplicant\n')

    def test_missing_iwd_backend_is_inserted_inside_device_section(self):
        self.network.write_text('[device]\n# comment\n[logging]\nlevel=INFO\n')
        self.run_config('configure_network_backend')
        self.assertEqual(self.network.read_text(), '[device]\nwifi.backend=iwd\n# comment\n[logging]\nlevel=INFO\n')


class ShellTests(unittest.TestCase):
    def test_network_only_probes_baidu_before_entering_wifi(self):
        import tempfile
        # 命令替身禁止真实联网；进入 Wi-Fi 列表后退出，避免后续交互。
        code = r'''
source "$1"
CALLS="$2"
# 此测试覆盖无配置分支，不读取用户实际的 Wi-Fi 凭据。
WIFI_CONFIG="$CALLS.wifi.conf"
PROBE_STATUS="$3"
record() { printf '%s\0' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"; }
ip() { record ip "$@"; return 99; }
curl() { record curl "$@"; return "$PROBE_STATUS"; }
systemctl() { record systemctl "$@"; }
iwctl() { record iwctl "$@"; return 23; }
connect_network
printf 'AFTER_NETWORK\n'
'''
        with tempfile.TemporaryDirectory() as directory:
            for probe_status in (0, 22):
                with self.subTest(probe_status=probe_status):
                    calls = Path(directory, str(probe_status) + '.calls')
                    result = subprocess.run(['bash', '-c', code, 'network-check', str(SCRIPT),
                                             str(calls), str(probe_status)], capture_output=True, text=True)
                    rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
                    self.assertEqual(rows[0][0], 'curl')
                    self.assertEqual(rows[0][-1], 'https://www.baidu.com/')
                    if probe_status == 0:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(len(rows), 1)
                        self.assertIn('AFTER_NETWORK', result.stdout)
                    else:
                        self.assertEqual(result.returncode, 23, result.stderr)
                        self.assertEqual(rows[1:], [['systemctl', 'start', 'iwd'], ['iwctl', 'device', 'list']])
                        self.assertNotIn('AFTER_NETWORK', result.stdout)

    def test_syntax(self):
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True)

    def test_cleanup_failure_returns_nonzero_without_real_unmount(self):
        code = '''
source "$1"
MOUNTS=(/test-only)
umount() { return 1; }
cleanup
'''
        result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('未能卸载', result.stderr)

    def test_user_is_created_in_target_system_with_terminal_for_password(self):
        # 伪终端保留 passwd 的交互条件，命令替身避免创建真实账户。
        import errno
        import pty
        import tempfile
        code = '''
source "$1"
TARGET="$2"
CALLS="$3"
names=('' root 'bad name' desktopuser)
answer_index=0
ask() {
    printf -v "$2" '%s' "${names[answer_index]}"
    answer_index=$((answer_index + 1))
}
arch-chroot() {
    printf '%s\\0' "$@" >> "$CALLS"
    printf '\\n' >> "$CALLS"
    if [[ $2 == useradd && "${@: -1}" != desktopuser ]]; then return 3; fi
    if [[ $2 == passwd ]]; then [[ -t 0 ]]; fi
}
create_user
'''
        with tempfile.TemporaryDirectory() as directory:
            calls = Path(directory, 'calls')
            child, terminal = pty.fork()
            if child == 0:
                os.execvp('bash', ['bash', '-c', code, 'user-check', str(SCRIPT), directory, str(calls)])
            output = b''
            try:
                while True:
                    try:
                        chunk = os.read(terminal, 8192)
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output += chunk
            finally:
                os.close(terminal)
                _, status = os.waitpid(child, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, output.decode())
            rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
            expected = [[directory, 'useradd', '-mG', 'wheel', '--', name]
                        for name in ('', 'root', 'bad name', 'desktopuser')]
            expected.append([directory, 'passwd', '--', 'desktopuser'])
            self.assertEqual(rows, expected)

    def test_swap_zero_skips_creation_and_activation(self):
        # 只调用安装包阶段，外部命令全部为 Shell 函数，不运行真实安装工具。
        code = '''
source "$1"
TARGET="$2"
SWAP_GIB=0
say() { :; }
python3() { printf '%s\\n' GenuineIntel; }
# 基础软件包必须包含目标系统的 OpenSSH。
pacstrap() { [[ " $* " == *' openssh '* ]]; }
btrfs() { printf 'unexpected btrfs\\n'; return 99; }
swapon() { printf 'unexpected swapon\\n'; return 99; }
genfstab() { printf 'fake fstab\\n'; }
install_base
[[ $SWAP_ACTIVE == 0 ]]
'''
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'etc').mkdir()
            result = subprocess.run(['bash', '-c', code, 'test', str(SCRIPT), directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertNotIn('unexpected', result.stdout)


if __name__ == '__main__':
    unittest.main()
