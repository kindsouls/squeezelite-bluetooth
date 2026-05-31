# squeezelite-bluetooth

Connects a Bluetooth speaker to a **Raspberry Pi running squeezelite**. The speaker auto-connects to the headless Pi; squeezelite starts when the speaker connects and stops when it disconnects — no manual intervention required.

A background service tracks the Bluetooth connection state via D-Bus and starts/stops squeezelite accordingly, solving two problems with the naive setup: squeezelite crashing on disconnection, and the speaker not auto-reconnecting.

Audio transport uses **bluez-alsa** (ALSA ↔ Bluetooth bridge). PipeWire is an alternative on modern Raspberry Pi OS — see [PipeWire note](#pipewire-alternative) at the end.

*Guide enhanced with input from cpd73 and paul- (forum.slimdevices.com) and Eric (github.com/coissac).*

---

## Quick start (recommended)

An installer script handles everything — dependencies, build, files, services, and device pairing:

```bash
# Full install (run once from the repo root)
sudo ./install.sh

# Pair your first Bluetooth speaker
sudo ./install.sh --add-device

# Check what's running and what's connected
./install.sh --status

# After changing files, push updates without a full rebuild
sudo ./install.sh --update

# Remove everything
sudo ./install.sh --uninstall
```

The manual steps below explain what the installer does, if you prefer to do it yourself.

---

## How it works

1. When a trusted Bluetooth speaker powers on, it reconnects to the Pi automatically.
2. The `bluealsa` daemon creates an ALSA audio device for the Bluetooth connection and fires a D-Bus signal (`PCMAdded`).
3. `btspeaker-monitor.py` receives the signal, looks up the device in `bt-devices`, and spawns a `squeezelite` process pointed at that ALSA device.
4. squeezelite connects to your LMS server and the player appears — ready to play.
5. When the speaker powers off, `bluealsa` fires `PCMRemoved`, the monitor stops squeezelite, and the player disappears from LMS.

The monitor also handles failure cases automatically:
- **Pi boots while speaker is already on:** queries bluealsa for active connections at startup.
- **bluealsa crashes:** watches for the service restarting and re-queries connections.
- **squeezelite crashes:** a health check sweep every 10 seconds detects the crash and restarts squeezelite automatically — no speaker power cycle needed.

---

## Manual installation

### 1. Install Bluetooth support

```bash
sudo apt-get install pi-bluetooth bluez bluez-tools
```

### 2. Install squeezelite

```bash
sudo apt-get install squeezelite
```

This installs an older version. For the latest binary, download the appropriate ARM release from [Sourceforge squeezelite/linux](https://sourceforge.net/projects/lmsclients/files/squeezelite/linux/) and replace `/usr/bin/squeezelite`:
- 32-bit Pi OS (armhf): use the `arm6f` archive
- 64-bit Pi OS (aarch64): use the `aarch64` archive

### 3. Build and install bluez-alsa

This library bridges Bluetooth audio to the ALSA sound system.

Install build dependencies:

```bash
sudo apt-get update
sudo apt-get install -y \
  libasound2-dev dh-autoreconf libortp-dev libbluetooth-dev \
  libusb-dev libglib2.0-dev libudev-dev libical-dev \
  libreadline-dev libsbc1 libsbc-dev libdbus-glib-1-dev
```

Build and install. The `--prefix=/usr` flag installs the binary to `/usr/bin/bluealsa`, which matches the service file:

```bash
cd ~
git clone https://github.com/Arkq/bluez-alsa.git
cd bluez-alsa
autoreconf --install
mkdir build && cd build

# 32-bit Raspberry Pi OS (armhf):
../configure --prefix=/usr --disable-hcitop \
  --with-alsaplugindir=/usr/lib/arm-linux-gnueabihf/alsa-lib

# 64-bit Raspberry Pi OS (aarch64) — use this line instead:
# ../configure --prefix=/usr --disable-hcitop \
#   --with-alsaplugindir=/usr/lib/aarch64-linux-gnu/alsa-lib

make && sudo make install
```

### 4. Install Python D-Bus and GLib bindings

```bash
sudo apt-get install python3-dbus python3-gi
```

### 5. Reboot

```bash
sudo reboot
```

### 6. Copy files to the filesystem

```bash
sudo mkdir -p /etc/pyserver
sudo cp src/etc/pyserver/btspeaker-monitor.py  /etc/pyserver/
sudo cp src/etc/pyserver/bt-devices             /etc/pyserver/
sudo cp src/etc/systemd/system/bluezalsa.service          /etc/systemd/system/
sudo cp src/etc/systemd/system/btspeaker-monitor.service  /etc/systemd/system/
```

### 7. Create the `lms` system user and add to audio group

```bash
sudo adduser --disabled-login --no-create-home --system lms
sudo adduser lms audio
```

### 8. Set ownership and permissions

```bash
sudo chown root:root /etc/pyserver/btspeaker-monitor.py
sudo chown root:root /etc/pyserver/bt-devices
sudo chown root:root /etc/systemd/system/btspeaker-monitor.service
sudo chown root:root /etc/systemd/system/bluezalsa.service
sudo chmod +x /etc/pyserver/btspeaker-monitor.py
```

### 9. Enable and start services

```bash
sudo systemctl daemon-reload
sudo systemctl enable bluezalsa.service
sudo systemctl enable btspeaker-monitor.service
sudo systemctl start bluezalsa.service
sudo systemctl start btspeaker-monitor.service
```

---

## Pairing your Bluetooth speaker (first time only)

### 1. Put the speaker in pairing mode, then open bluetoothctl

```bash
sudo bluetoothctl
```

```
[bluetooth]# power on
[bluetooth]# agent on
[bluetooth]# default-agent
[bluetooth]# scan on
```

Wait for your speaker to appear in the list. Note its address (format `AA:BB:CC:DD:EE:FF`). Then:

```
[bluetooth]# scan off
[bluetooth]# pair AA:BB:CC:DD:EE:FF
[bluetooth]# trust AA:BB:CC:DD:EE:FF
[bluetooth]# connect AA:BB:CC:DD:EE:FF
[bluetooth]# exit
```

The device is now trusted and will reconnect automatically on future power-ons.

### 2. Register the speaker in the device list

```bash
sudo nano /etc/pyserver/bt-devices
```

The config uses INI format — one `[MAC]` section per speaker:

```ini
[AA:BB:CC:DD:EE:FF]
name = Livingroom

[11:22:33:44:55:66]
name = Bathroom
codec = aptx
lms = 192.168.1.10
```

| Option | Required | Description |
|---|---|---|
| `name` | Yes | Player name in LMS. **No spaces** — use underscores or CamelCase. |
| `codec` | No | Audio codec: `sbc` (default), `aptx`, `aac`, `sbc-xq`, `faststream`. Only applies if both devices support it. |
| `lms` | No | LMS server IP or hostname. Omit to auto-discover on LAN via mDNS. |

The file is re-read on every connect event — changes take effect on the next speaker connection without restarting the service.

### 3. Reboot

```bash
sudo reboot
```

---

## Normal use

**Turn the speaker on** — squeezelite starts automatically and the player appears in LMS. If it is in a synchronised group, music begins immediately.

**Turn the speaker off** — squeezelite stops and the player disappears from LMS. Wait about 30 seconds before turning it back on.

---

## Troubleshooting

**Check service status:**
```bash
sudo systemctl status bluezalsa.service
sudo systemctl status btspeaker-monitor.service
```

**Follow live logs:**
```bash
sudo journalctl -fu btspeaker-monitor
sudo journalctl -fu bluezalsa
```

**Verify the bluealsa ALSA device appears after the speaker connects:**
```bash
aplay -L | grep bluealsa
```

**Check Bluetooth device state:**
```bash
bluetoothctl info AA:BB:CC:DD:EE:FF
```

**Watch D-Bus signals in real time** (useful for confirming the monitor sees events):
```bash
dbus-monitor --system "type='signal',interface='org.bluealsa.Manager1'"
```

**Query what PCMs bluealsa currently knows about:**
```bash
busctl call org.bluealsa /org/bluealsa org.bluealsa.Manager1 GetPCMs
```

**Common problems:**

| Symptom | Likely cause | Fix |
|---|---|---|
| Player never appears in LMS | Speaker not trusted / not reconnecting | Re-run `sudo ./install.sh --add-device` |
| Player appears then immediately disappears | squeezelite can't reach LMS | Set `lms = <ip>` in bt-devices for that speaker |
| `bluezalsa.service` fails to start | bluealsa binary not at `/usr/bin/bluealsa` | Re-run `sudo ./install.sh` or check `which bluealsa` |
| `btspeaker-monitor.service` exits instantly | squeezelite or bt-devices not found | Check `/usr/bin/squeezelite` exists and `/etc/pyserver/bt-devices` is present |
| Sound plays but is choppy | A2DP buffer underrun | Try `export LIBASOUND_THREAD_SAFE=0` before testing manually |
| Speaker connects but no ALSA device | PipeWire conflict on Bookworm | See PipeWire note below |
| squeezelite keeps restarting in logs | ALSA or LMS error on startup | Check `journalctl -fu btspeaker-monitor`; set explicit `lms =` in bt-devices |
| No devices watched after `--update` | bt-devices still in old `MAC=Name` format | Restart the monitor — it auto-migrates the file and backs up the original |

---

## PipeWire alternative

Modern Raspberry Pi OS (Bookworm, 2023+) ships **PipeWire** by default, which handles Bluetooth audio natively without bluez-alsa. If your Pi is already running PipeWire, you can skip building bluez-alsa entirely — configure squeezelite to use `pipewire` as its output and use WirePlumber rules or a BlueZ D-Bus watcher to start/stop it.

The approach in this repo (bluez-alsa + ALSA) works on all Pi OS versions and requires no PipeWire knowledge, making it the more broadly compatible option.
