#!/usr/bin/env python3
"""用临时配置和命令替身验证两个脚本自动连接 Wi-Fi，不操作真实网络。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CUSTOM = Path(__file__).resolve().parents[1]
COMMANDS = r'''
source "$1"
CALLS="$2"
connected=0
record() { printf '%s\0' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"; }
curl() { record curl "$@"; [[ $CASE == online || $connected == 1 ]]; }
systemctl() { record systemctl "$@"; }
sudo() { "$@"; }
iwctl() {
    record iwctl "$@"
    if [[ $CASE == failed ]]; then return 1; fi
    connected=1
}
nmcli() {
    record nmcli "$@"
    if [[ $CASE == failed ]]; then return 1; fi
    connected=1
}
connect_network
printf 'AFTER_NETWORK\n'
'''


class WifiConfigTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='wifi-config-regression-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.net = self.root / 'sys/class/net'
        (self.net / 'wlan0').mkdir(parents=True)
        (self.net / 'wlan0/phy80211').touch()
        (self.net / 'wlp2s0').mkdir()
        (self.net / 'wlp2s0/phy80211').touch()

    def run_config(self, script, config, case='offline'):
        # 从其他目录运行，确认配置路径以脚本所在目录为准。
        fixture = self.root / script
        fixture.write_text((CUSTOM / script).read_text().replace('/sys/class/net/', str(self.net) + '/'))
        (self.root / 'wifi.conf').write_text(config)
        calls = self.root / 'calls'
        calls.unlink(missing_ok=True)
        result = subprocess.run(['bash', '-c', COMMANDS, 'wifi-check', str(fixture), str(calls)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
                                cwd=self.root.parent, env={**os.environ, 'CASE': case})
        rows = [row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
        return result, rows

    def test_config_connects_without_input_and_preserves_literal_credentials(self):
        marker = self.root / 'must-not-exist'
        ssid = '测试 Wi-Fi #=$HOME'
        password = '空 格#=$HOME\\"\'$(touch ' + str(marker) + ')'
        for script in ('install-arch.sh', 'setup-desktop.sh'):
            for interface in ('', 'wlp2s0'):
                with self.subTest(script=script, interface=interface):
                    # 无结尾换行也要正确读取最后一项。
                    config = f'WIFI_SSID={ssid}\nWIFI_PASSWORD={password}\nWIFI_INTERFACE={interface}'
                    result, rows = self.run_config(script, config)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('AFTER_NETWORK', result.stdout)
                    iface = interface or 'wlan0'
                    if script == 'install-arch.sh':
                        expected = ['iwctl', '--passphrase', password, 'station', iface, 'connect', ssid]
                    else:
                        expected = ['nmcli', 'device', 'wifi', 'connect', ssid, 'password', password, 'ifname', iface]
                    self.assertIn(expected, rows)
                    self.assertEqual([row[-1] for row in rows if row[0] == 'curl'],
                                     ['https://www.baidu.com/'] * 2)
                    self.assertNotIn(password, result.stdout + result.stderr)
                    self.assertFalse(marker.exists())

    def test_available_network_skips_wifi_config(self):
        for script in ('install-arch.sh', 'setup-desktop.sh'):
            with self.subTest(script=script):
                result, rows = self.run_config(script, 'WIFI_SSID=incomplete\n', 'online')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(any(row[0] in ('iwctl', 'nmcli') for row in rows))

    def test_failed_config_connection_stops_without_prompting(self):
        for script in ('install-arch.sh', 'setup-desktop.sh'):
            with self.subTest(script=script):
                result, _ = self.run_config(script, 'WIFI_SSID=test\nWIFI_PASSWORD=test-password\n', 'failed')
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('AFTER_NETWORK', result.stdout)
                self.assertIn('请检查 wifi.conf 后重试', result.stdout + result.stderr)
                self.assertNotIn('test-password', result.stdout + result.stderr)

    def test_incomplete_config_stops_with_clear_error(self):
        for script in ('install-arch.sh', 'setup-desktop.sh'):
            with self.subTest(script=script):
                result, rows = self.run_config(script, 'WIFI_SSID=test\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('请在 wifi.conf 中填写', result.stdout + result.stderr)
                self.assertFalse(any(row[0] in ('iwctl', 'nmcli') for row in rows))


class TargetWifiTests(unittest.TestCase):
    def run_target(self, answer, config=None, generate_status=0):
        # 只在临时目标目录生成文件，arch-chroot 替身模拟 nmcli 的离线输出。
        code = r'''
source "$1"
TARGET="$2"
WIFI_CONFIG="$3"
CALLS="$4"
ANSWER="$5"
GENERATE_STATUS="$6"
ask() { printf -v "$2" '%s' "$ANSWER"; }
arch-chroot() {
    printf '%s\0' "$@" >> "$CALLS"
    printf '\n' >> "$CALLS"
    printf '[connection]\nid=install-wifi\n[wifi-security]\npsk=test-password\n'
    return "$GENERATE_STATUS"
}
configure_target_wifi
printf 'AFTER_TARGET_WIFI\n'
'''
        with tempfile.TemporaryDirectory(prefix='target-wifi-regression-') as directory:
            root = Path(directory)
            config_path = root / 'wifi.conf'
            if config is not None:
                config_path.write_text(config)
            calls = root / 'calls'
            result = subprocess.run(['bash', '-c', code, 'target-wifi-check', str(CUSTOM / 'install-arch.sh'),
                                     str(root / 'target'), str(config_path), str(calls), answer,
                                     str(generate_status)], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=10)
            rows = ([row[:-1].decode().split('\0') for row in calls.read_bytes().splitlines()]
                    if calls.exists() else [])
            profile = root / 'target/etc/NetworkManager/system-connections/install-wifi.nmconnection'
            content = profile.read_text() if profile.exists() else None
            mode = profile.stat().st_mode & 0o777 if profile.exists() else None
            return result, rows, content, mode

    def test_no_skips_profile_and_does_not_require_config(self):
        result, rows, content, _ = self.run_target('n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows, [])
        self.assertIsNone(content)

    def test_yes_generates_private_autoconnect_profile_in_target(self):
        for interface in ('', 'wlan0'):
            with self.subTest(interface=interface):
                ssid = '测试 Wi-Fi #=$HOME'
                password = 'test-password $ # = "'
                result, rows, content, mode = self.run_target(
                    'y', f'WIFI_SSID={ssid}\nWIFI_PASSWORD={password}\nWIFI_INTERFACE={interface}')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0][1:], ['nmcli', '--offline', 'connection', 'add',
                    'type', 'wifi', 'con-name', 'install-wifi', 'ssid', ssid,
                    'connection.autoconnect', 'yes', 'wifi-sec.key-mgmt', 'wpa-psk',
                    'wifi-sec.psk', password] + (['ifname', interface] if interface else []))
                self.assertTrue(rows[0][0].endswith('/target'))
                self.assertEqual(mode, 0o600)
                self.assertEqual(content, '[connection]\nid=install-wifi\n[wifi-security]\npsk=test-password\n')
                self.assertNotIn('test-password', result.stdout + result.stderr)

    def test_yes_requires_complete_config(self):
        for config in (None, 'WIFI_SSID=test\n'):
            with self.subTest(config=config):
                result, rows, content, _ = self.run_target('y', config)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(rows, [])
                self.assertIsNone(content)
                self.assertNotIn('AFTER_TARGET_WIFI', result.stdout)

    def test_generation_failure_stops_installation(self):
        result, _, _, _ = self.run_target('y', 'WIFI_SSID=test\nWIFI_PASSWORD=test-password\n', 10)
        self.assertEqual(result.returncode, 10)
        self.assertNotIn('AFTER_TARGET_WIFI', result.stdout)
        self.assertNotIn('配置已保存', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
