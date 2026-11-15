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
config = load_block('PY_CONFIG')


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
    def test_commented_examples_are_enabled_without_duplicate_keys(self):
        result = config.set_key('# keep\n#GRUB_DISABLE_OS_PROBER=false\n', 'GRUB_DISABLE_OS_PROBER', 'false')
        self.assertEqual(result, '# keep\nGRUB_DISABLE_OS_PROBER=false\n')
        result = config.enable_locales('#en_US.UTF-8 UTF-8\n#zh_CN.UTF-8 UTF-8\n#ja_JP.UTF-8 UTF-8\n')
        self.assertEqual(result, 'en_US.UTF-8 UTF-8\nzh_CN.UTF-8 UTF-8\n#ja_JP.UTF-8 UTF-8\n')

    def test_existing_active_key_takes_priority_over_comment(self):
        result = config.set_key('#LANG=old\nLANG=old\nLANG=duplicate\n', 'LANG', 'en_US.UTF-8')
        self.assertEqual(result, '#LANG=old\nLANG=en_US.UTF-8\n# LANG=duplicate\n')
        self.assertEqual(config.set_key(result, 'LANG', 'en_US.UTF-8'), result)

    def test_iwd_uses_existing_commented_section(self):
        before = '# comment\n#[device]\n#wifi.backend=wpa_supplicant\n[logging]\nlevel=INFO\n'
        after = config.set_iwd(before)
        self.assertEqual(after, '# comment\n[device]\nwifi.backend=iwd\n[logging]\nlevel=INFO\n')
        self.assertEqual(config.set_iwd(after), after)

    def test_active_device_section_takes_priority_over_commented_sample(self):
        before = '#[device]\n#wifi.backend=wpa_supplicant\n[device]\nwifi.backend=wpa_supplicant\n'
        after = config.set_iwd(before)
        self.assertEqual(after.count('\n[device]\n'), 1)
        self.assertIn('\n[device]\nwifi.backend=iwd\n', after)


class ShellTests(unittest.TestCase):
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

    def test_swap_zero_skips_creation_and_activation(self):
        # 只调用安装包阶段，外部命令全部为 Shell 函数，不运行真实安装工具。
        code = '''
source "$1"
TARGET="$2"
SWAP_GIB=0
say() { :; }
python3() { printf '%s\\n' GenuineIntel; }
pacstrap() { :; }
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
