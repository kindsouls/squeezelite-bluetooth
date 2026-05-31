#!/usr/bin/python3 -u

import configparser
import logging
import os
import shutil
import signal
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional

from gi.repository import GLib
import dbus
import dbus.mainloop.glib

CONFIG_FILE    = '/etc/pyserver/bt-devices'
SQUEEZE_LITE   = '/usr/bin/squeezelite'
BLUEALSA_BUS   = 'org.bluealsa'
BLUEALSA_PATH  = '/org/bluealsa'
BLUEALSA_IFACE = 'org.bluealsa.Manager1'

HEALTH_CHECK_INTERVAL_S = 10   # seconds between dead-process sweeps
STARTUP_QUERY_DELAY_S   = 2    # wait after bluealsa appears before querying PCMs
RESTART_DELAY_S         = 3    # delay before restarting a crashed squeezelite

logging.basicConfig(
    level=logging.INFO,
    format='%(levelname)s: %(message)s',
    stream=sys.stdout,
)
log = logging.getLogger(__name__)

bus = None


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class DeviceConfig:
    mac:   str
    name:  str
    codec: Optional[str] = None   # e.g. 'aptx', 'aac', 'sbc-xq'
    lms:   Optional[str] = None   # LMS server IP/hostname; None = auto-discover


@dataclass
class Player:
    proc:   subprocess.Popen
    hci:    str
    config: DeviceConfig


players = {}   # key: 'AA_BB_CC_DD_EE_FF' -> Player


# ---------------------------------------------------------------------------
# Config — INI format, re-read on every connect event for hot-reload
# ---------------------------------------------------------------------------

def _is_old_format(path):
    """Return True if the file uses the legacy MAC=Name flat format."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('['):
                    return False   # INI section found — already new format
                if '=' in line:
                    key = line.split('=', 1)[0].strip().upper()
                    if _valid_mac(key):
                        return True   # MAC=Name line found — old format
    except OSError:
        pass
    return False


def _migrate_to_ini(path):
    """Convert legacy MAC=Name file to INI format in-place; back up the original."""
    backup = path + '.bak'
    try:
        shutil.copy2(path, backup)
    except OSError as e:
        log.error("Cannot create backup before migration: %s", e)
        return

    entries = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                parts = line.split('=', 1)
                if len(parts) == 2:
                    mac  = parts[0].strip().upper()
                    name = parts[1].strip()
                    if _valid_mac(mac) and name:
                        entries.append((mac, name))
    except OSError as e:
        log.error("Migration read failed: %s", e)
        return

    try:
        with open(path, 'w') as f:
            f.write("# bt-devices — auto-migrated from old MAC=Name format\n")
            f.write(f"# Original backed up to: {backup}\n")
            f.write("#\n")
            f.write("# name   = Player name in LMS (no spaces)\n")
            f.write("# codec  = sbc (default) | aptx | aac | sbc-xq | faststream\n")
            f.write("# lms    = LMS server IP or hostname (default: auto-discover)\n\n")
            for mac, name in entries:
                f.write(f"[{mac}]\nname = {name}\n\n")
        log.warning(
            "bt-devices migrated from old format — %d device(s) converted. "
            "Original saved as %s", len(entries), backup,
        )
    except OSError as e:
        log.error("Migration write failed: %s — restoring backup", e)
        shutil.copy2(backup, path)


def load_devices():
    """Return {uppercase_mac: DeviceConfig} parsed from CONFIG_FILE."""
    if _is_old_format(CONFIG_FILE):
        _migrate_to_ini(CONFIG_FILE)

    parser = configparser.ConfigParser()
    parser.optionxform = str   # preserve key case
    devices = {}
    try:
        if not parser.read(CONFIG_FILE):
            log.error("Cannot read %s", CONFIG_FILE)
            return devices
    except configparser.Error as e:
        log.error("Error parsing %s: %s", CONFIG_FILE, e)
        return devices

    for section in parser.sections():
        mac = section.upper()
        if not _valid_mac(mac):
            log.warning("Skipping section [%s]: not a valid MAC address", section)
            continue
        name = parser.get(section, 'name', fallback='').strip()
        if not name:
            log.warning("Skipping [%s]: missing required 'name' option", mac)
            continue
        codec = parser.get(section, 'codec', fallback='').strip() or None
        lms   = parser.get(section, 'lms',   fallback='').strip() or None
        devices[mac] = DeviceConfig(mac=mac, name=name, codec=codec, lms=lms)

    return devices


def _valid_mac(mac):
    parts = mac.split(':')
    if len(parts) != 6:
        return False
    try:
        return all(0 <= int(p, 16) <= 255 for p in parts)
    except ValueError:
        return False


def get_device_config(dev):
    return load_devices().get(dev.upper())


# ---------------------------------------------------------------------------
# Player lifecycle
# ---------------------------------------------------------------------------

def start_squeezelite(hci, device_config, _attempt=0):
    key = device_config.mac.replace(':', '_')
    if key in players:
        return False   # already running

    alsa_parts = [f'HCI={hci}', f'DEV={device_config.mac}', 'PROFILE=a2dp-source']
    if device_config.codec:
        alsa_parts.append(f'CODEC={device_config.codec}')
    alsa_dev = 'bluealsa:' + ','.join(alsa_parts)

    cmd = [SQUEEZE_LITE, '-o', alsa_dev, '-n', device_config.name,
           '-m', device_config.mac, '-f', '/dev/null']
    if device_config.lms:
        cmd += ['-s', device_config.lms]

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        players[key] = Player(proc=proc, hci=hci, config=device_config)
        log.info("Started squeezelite for %s (%s) via %s", device_config.name, device_config.mac, hci)
    except OSError as e:
        if _attempt < 3:
            delay = 2 ** _attempt   # 1 s, 2 s, 4 s
            log.warning("Failed to start squeezelite for %s — retry in %ds: %s",
                        device_config.name, delay, e)
            GLib.timeout_add_seconds(
                delay,
                lambda h=hci, c=device_config, a=_attempt: start_squeezelite(h, c, a + 1)
            )
        else:
            log.error("Gave up starting squeezelite for %s after %d attempts: %s",
                      device_config.name, _attempt, e)
    return False   # GLib: don't repeat


def stop_squeezelite(dev, name):
    key = dev.replace(':', '_')
    player = players.pop(key, None)
    if player is None:
        return
    log.info("Stopping squeezelite for %s (%s)", name, dev)
    player.proc.terminate()
    try:
        player.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        log.warning("squeezelite for %s did not stop gracefully, killing", name)
        player.proc.kill()
        player.proc.wait()


def stop_all_players():
    for player in list(players.values()):
        stop_squeezelite(player.config.mac, player.config.name)


# ---------------------------------------------------------------------------
# Health check — sweeps for crashed squeezelite and restarts automatically
# ---------------------------------------------------------------------------

def check_player_health():
    for key, player in list(players.items()):
        if player.proc.poll() is not None:
            log.warning(
                "squeezelite for %s exited unexpectedly (code %s) — restarting in %ds",
                player.config.name, player.proc.returncode, RESTART_DELAY_S,
            )
            players.pop(key, None)
            # Re-read config in case it was edited since last start
            fresh_config = get_device_config(player.config.mac) or player.config
            GLib.timeout_add_seconds(
                RESTART_DELAY_S,
                lambda h=player.hci, c=fresh_config: start_squeezelite(h, c),
            )
    return True   # keep the GLib timeout repeating


# ---------------------------------------------------------------------------
# D-Bus: bluealsa PCM signals
# ---------------------------------------------------------------------------

def _parse_pcm_path(path):
    """Return (hci, dev) from /org/bluealsa/hci0/dev_AA_BB_CC_DD_EE_FF/..."""
    parts = str(path).split('/')
    if len(parts) < 5:
        return None, None
    hci = parts[3]
    dev = ':'.join(parts[4].split('_')[1:])
    return hci, dev


def bluealsa_handler(path, *args, **kwargs):
    member = kwargs.get('member')
    hci, dev = _parse_pcm_path(path)
    if not hci or not dev:
        return
    device_config = get_device_config(dev)
    if device_config is None:
        log.debug("Ignoring unknown device: %s", dev)
        return
    if member == 'PCMAdded':
        start_squeezelite(hci, device_config)
    elif member == 'PCMRemoved':
        stop_squeezelite(dev, device_config.name)


# ---------------------------------------------------------------------------
# Startup query — pick up speakers already connected before we started
# ---------------------------------------------------------------------------

def query_existing_pcms():
    """Ask bluealsa for its current PCM list; safe to call when not yet up."""
    try:
        mgr_obj = bus.get_object(BLUEALSA_BUS, BLUEALSA_PATH)
        mgr     = dbus.Interface(mgr_obj, BLUEALSA_IFACE)
        pcms    = mgr.GetPCMs()
        for path in pcms:
            bluealsa_handler(path, member='PCMAdded')
        if pcms:
            log.info("Picked up %d existing PCM(s) from bluealsa", len(pcms))
    except dbus.exceptions.DBusException as e:
        log.debug("Startup PCM query skipped (bluealsa not ready): %s", e)
    return False   # GLib: don't repeat


# ---------------------------------------------------------------------------
# D-Bus: watch for bluealsa service appearing / disappearing
# ---------------------------------------------------------------------------

def on_name_owner_changed(name, old_owner, new_owner):
    if name != BLUEALSA_BUS:
        return
    if new_owner:
        log.info("bluealsa service appeared — querying for active PCMs in %ds",
                 STARTUP_QUERY_DELAY_S)
        GLib.timeout_add_seconds(STARTUP_QUERY_DELAY_S, query_existing_pcms)
    else:
        log.warning("bluealsa service disappeared — stopping all players")
        stop_all_players()


# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------

def shutdown(signum, frame):
    log.info("Shutting down (signal %d)", signum)
    stop_all_players()
    sys.exit(0)


# ---------------------------------------------------------------------------
# Startup validation
# ---------------------------------------------------------------------------

def preflight_check():
    ok = True
    if not os.path.isfile(SQUEEZE_LITE):
        log.error("squeezelite not found at %s — install it first", SQUEEZE_LITE)
        ok = False
    if not os.path.isfile(CONFIG_FILE):
        log.error("Device config not found at %s — create it first", CONFIG_FILE)
        ok = False
    return ok


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    if not preflight_check():
        sys.exit(1)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()

    bus.add_signal_receiver(
        bluealsa_handler,
        dbus_interface=BLUEALSA_IFACE,
        interface_keyword='dbus_interface',
        member_keyword='member',
    )

    bus.add_signal_receiver(
        on_name_owner_changed,
        dbus_interface='org.freedesktop.DBus',
        signal_name='NameOwnerChanged',
        path='/org/freedesktop/DBus',
    )

    devices = load_devices()
    if devices:
        log.info("Watching %d device(s): %s", len(devices),
                 ', '.join(f"{c.name} ({c.mac})" for c in devices.values()))
    else:
        log.warning("No devices in %s — add entries and restart this service", CONFIG_FILE)

    GLib.idle_add(query_existing_pcms)
    GLib.timeout_add_seconds(HEALTH_CHECK_INTERVAL_S, check_player_health)

    GLib.MainLoop().run()
