#!/usr/bin/env python3
"""使用命令替身验证联网重试和 GDM 启动顺序，不修改实际网络或服务。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'setup-desktop.sh'

NETWORK_COMMANDS = r'''
source "$1"
CALLS="$2"
scan_count=0
wifi_connected=0
record() { printf '%s\0' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"; }
sudo() { record sudo "$@"; if [[ $1 == nmcli ]]; then shift; nmcli "$@"; fi; }
ip() { record ip "$@"; return 99; }
curl() {
    record curl "$@"
    case "$CASE" in
        online) return 0 ;;
        wifi-offline) return 22 ;;
        *) (( wifi_connected )) ;;
    esac
}
nmcli() {
    record nmcli "$@"
    if [[ $1 == --ask ]]; then wifi_connected=1; fi
    if [[ $1 == device && $2 == wifi && $3 == rescan ]]; then
        scan_count=$((scan_count + 1))
        if [[ $CASE == scan-busy || $CASE == scan-cancel || $CASE == scan-retry && $scan_count == 1 ]]; then
            return 1
        fi
    fi
    if [[ $1 == device && $2 == wifi && $3 == list ]]; then
        if [[ $CASE == scan-cancel || $CASE == scan-retry && $scan_count == 1 ]]; then
            return 1
        fi
    fi
    return 0
}
connect_network
printf 'AFTER_NETWORK\n'
'''


class DesktopTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='desktop-regression-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        net = self.root / 'sys/class/net'
        (net / 'wlan0').mkdir(parents=True)
        (net / 'wlan0/phy80211').touch()
        self.fixture = self.root / 'setup-desktop.sh'
        # 只替换测试夹具中的只读系统路径，产品脚本不增加测试专用分支。
        source = SCRIPT.read_text().replace('/sys/class/net/', str(net) + '/')
        self.fixture.write_text(source)

    def run_network(self, case, answers):
        calls = self.root / 'network.calls'
        result = subprocess.run(['bash', '-c', NETWORK_COMMANDS, 'network-check', str(self.fixture), str(calls)],
                                input=answers, text=True, capture_output=True, timeout=10,
                                env={**os.environ, 'CASE': case})
        rows = [line[:-1].decode().split('\0') for line in calls.read_bytes().splitlines()]
        return result, rows

    def assert_connected(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('AFTER_NETWORK', result.stdout)

    def test_baidu_success_continues_without_route_or_wifi_checks(self):
        result, rows = self.run_network('online', '')
        self.assert_connected(result)
        urls = [row[-1] for row in rows if row[0] == 'curl']
        self.assertEqual(urls, ['https://www.baidu.com/'])
        self.assertFalse(any(row[0] in ('ip', 'nmcli') for row in rows))

    def test_failed_baidu_probe_goes_directly_to_wifi(self):
        result, rows = self.run_network('offline', 'wlan0\n测试 Wi-Fi\n')
        self.assert_connected(result)
        self.assertIn('无法访问百度', result.stdout)
        self.assertIn(['nmcli', '--ask', 'device', 'wifi', 'connect', '测试 Wi-Fi', 'ifname', 'wlan0'], rows)

    def test_scan_failure_can_use_cached_results(self):
        result, rows = self.run_network('scan-busy', 'wlan0\n测试 Wi-Fi\n')
        self.assert_connected(result)
        self.assertIn('尝试使用已有扫描结果', result.stdout)
        self.assertIn(['nmcli', '--ask', 'device', 'wifi', 'connect', '测试 Wi-Fi', 'ifname', 'wlan0'], rows)

    def test_scan_and_list_failure_can_retry(self):
        result, rows = self.run_network('scan-retry', 'wlan0\ny\n测试 Wi-Fi\n')
        self.assert_connected(result)
        scans = [row for row in rows if row[:4] == ['nmcli', 'device', 'wifi', 'rescan']]
        self.assertEqual(len(scans), 2)

    def test_scan_and_list_failure_can_cancel_without_continuing(self):
        result, rows = self.run_network('scan-cancel', 'wlan0\nn\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('AFTER_NETWORK', result.stdout)
        self.assertFalse(any(row[:2] == ['nmcli', '--ask'] for row in rows))

    def test_wifi_probe_failure_does_not_continue_installation(self):
        result, _ = self.run_network('wifi-offline', 'wlan0\n测试 Wi-Fi\nn\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('AFTER_NETWORK', result.stdout)

    def test_fonts_refresh_database_before_installing_packages(self):
        calls = self.root / 'fonts.calls'
        code = '''
source "$1"
CALLS="$2"
sudo() { printf '%s\\0' "$@" >> "$CALLS"; printf '\\n' >> "$CALLS"; }
install_fonts
'''
        subprocess.run(['bash', '-c', code, 'fonts-check', str(self.fixture), str(calls)],
                       check=True, text=True, capture_output=True)
        rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
        self.assertEqual(rows[0], ['pacman', '-Syu'])
        self.assertEqual(rows[1], ['pacman', '-S', 'noto-fonts', 'noto-fonts-cjk',
                                   'noto-fonts-emoji', 'ttf-jetbrains-mono-nerd'])

    def test_archlinuxcn_only_adds_missing_section_or_uncomments_existing_section(self):
        config = self.root / 'pacman.conf'
        self.fixture.write_text(self.fixture.read_text().replace('/etc/pacman.conf', str(config)))
        code = '''
source "$1"
sed() {
    if [[ $(uname -s) == Darwin && $1 == -i ]]; then
        shift
        command sed -i '' "$@"
    else
        command sed "$@"
    fi
}
sudo() { if [[ $1 != pacman ]]; then "$@"; fi; }
configure_archlinuxcn
'''
        samples = (
            ('[core]\nInclude = core\n',
             '[core]\nInclude = core\n\n[archlinuxcn]\nServer = https://mirrors.ustc.edu.cn/archlinuxcn/$arch\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\n'),
            ('#[archlinuxcn]\n#Server = https://existing.example/$arch\n#[extra]\n#Server = https://extra.example/$arch\n',
             '[archlinuxcn]\nServer = https://existing.example/$arch\n#[extra]\n#Server = https://extra.example/$arch\n'),
            ('[archlinuxcn]\nServer = https://existing.example/$arch\n',
             '[archlinuxcn]\nServer = https://existing.example/$arch\n'),
        )
        for before, expected in samples:
            with self.subTest(before=before):
                config.write_text(before)
                for _ in range(2):
                    subprocess.run(['bash', '-c', code, 'repo-check', str(self.fixture)],
                                   check=True, text=True, capture_output=True)
                    self.assertEqual(config.read_text(), expected)

    def test_gnome_base_installs_malcontent(self):
        code = '''
source "$1"
sudo() { printf '%s\\n' "$@"; }
install_gnome_base
'''
        result = subprocess.run(['bash', '-c', code, 'gnome-check', str(self.fixture)],
                                check=True, text=True, capture_output=True)
        self.assertIn('malcontent', result.stdout.splitlines())

    def test_hidden_apps_use_custom_xdg_data_directory(self):
        templates = self.root / 'system-applications'
        templates.mkdir()
        # 用模拟的系统启动器验证 Vim 和家长控制都走用户级覆盖。
        launchers = ('vim.desktop', 'org.freedesktop.MalcontentControl.desktop')
        for launcher in launchers:
            (templates / launcher).write_text(f'[Desktop Entry]\nName={launcher}\n')
        self.fixture.write_text(self.fixture.read_text().replace('/usr/share/applications/', str(templates) + '/'))
        data = self.root / 'custom-data'
        calls = self.root / 'desktop-entry.calls'
        code = '''
source "$1"
CALLS="$2"
sed() { printf '%s\\0' "$@" >> "$CALLS"; }
hide_dependency_apps
'''
        subprocess.run(['bash', '-c', code, 'xdg-check', str(self.fixture), str(calls)],
                       check=True, text=True, capture_output=True, env={**os.environ, 'XDG_DATA_HOME': str(data)})
        arguments = calls.read_bytes().decode().split('\0')[:-1]
        for launcher in launchers:
            target = data / 'applications' / launcher
            self.assertTrue(target.is_file(), f'缺少用户级启动器：{launcher}')
            self.assertEqual(target.read_text(), (templates / launcher).read_text())
            index = arguments.index(str(target))
            self.assertIn('NoDisplay=true', arguments[index - 1])

    def test_gdm_starts_only_after_terminal_configuration_and_final_question(self):
        if os.geteuid() == 0:
            self.skipTest('完整桌面入口要求普通用户；本测试不绕过该身份检查。')
        functions = ('connect_network', 'install_fonts', 'enable_multilib', 'configure_archlinuxcn',
                     'install_aur_helpers', 'install_flatpak', 'install_amd_graphics',
                     'install_audio_firmware', 'install_audio_services', 'enable_audio_services',
                     'install_bluetooth', 'enable_bluetooth', 'install_power_profiles',
                     'enable_power_profiles', 'install_gnome_base', 'install_gnome_optional_apps',
                     'install_gnome_extras', 'hide_dependency_apps', 'install_nautilus_enhancements',
                     'configure_nautilus_terminal', 'configure_gnome_terminal')
        code = '''
source "$1"
CALLS="$2"
record() { printf '%s\\0' "$@" >> "$CALLS"; printf '\\n' >> "$CALLS"; }
sudo() { record sudo "$@"; }
'''
        code += '\n'.join(name + '() { record ' + name + '; }' for name in functions)
        code += '\nmain\n'
        for answer in ('n', 'y'):
            with self.subTest(answer=answer):
                calls = self.root / ('gdm-' + answer + '.calls')
                result = subprocess.run(['bash', '-c', code, 'gdm-check', str(self.fixture), str(calls)],
                                        input=answer + '\n', text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
                self.assertIn(['sudo', 'systemctl', 'enable', 'gdm'], rows)
                self.assertFalse(any('--now' in row for row in rows))
                self.assertLess(rows.index(['configure_nautilus_terminal']), rows.index(['configure_gnome_terminal']))
                if answer == 'n':
                    self.assertEqual(rows[-1], ['sudo', 'systemctl', 'start', 'gdm'])
                    self.assertNotIn(['sudo', 'reboot'], rows)
                else:
                    self.assertEqual(rows[-1], ['sudo', 'reboot'])
                    self.assertNotIn(['sudo', 'systemctl', 'start', 'gdm'], rows)


if __name__ == '__main__':
    unittest.main()
