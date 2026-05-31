# squeezelite-bluetooth

Connects a Bluetooth speaker to a **Raspberry Pi running squeezelite**. The speaker auto-connects to the headless Pi; squeezelite starts when the speaker connects and stops when it disconnects — no manual intervention required.

A background service tracks the Bluetooth connection state via D-Bus and starts/stops squeezelite accordingly, solving two problems with the naive setup: squeezelite crashing on disconnection, and the speaker not auto-reconnecting.

The installer auto-detects your audio system and configures accordingly: **bluez-alsa** on older Pi OS (Buster/Bullseye), **PipeWire** on Bookworm (2023+). Both are fully supported.

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

# Remove everything (reads install manifest for precise removal)
sudo ./uninstall.sh

# Non-interactive removal (e.g. in scripts)
sudo ./uninstall.sh --yes
```

The manual steps below explain what the installer does, if you prefer to do it yourself.

---

## How it works

1. When a trusted Bluetooth speaker powers on, it reconnects to the Pi automatically.
2. The audio stack (bluealsa or PipeWire) makes the BT connection available and signals readiness via D-Bus.
3. `btspeaker-monitor.py` receives the signal, looks up the device in `bt-devices`, and spawns a `squeezelite` process.
4. squeezelite connects to your LMS server and the player appears — ready to play.
5. When the speaker powers off, the monitor detects the disconnection, stops squeezelite, and the player disappears from LMS.

**bluealsa mode** (Buster/Bullseye): watches `PCMAdded`/`PCMRemoved` signals from `org.bluealsa.Manager1`.
**PipeWire mode** (Bookworm): watches `Connected` property changes directly on BlueZ device objects via `org.freedesktop.DBus.Properties`.

The monitor also handles failure cases automatically:
- **Pi boots while speaker is already on:** queries the audio stack for active connections at startup.
- **Audio service crashes:** watches for it restarting and re-queries connections automatically.
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

### 3. Build and install bluez-alsa *(bluez-alsa backend only)*

Skip this step if your Pi runs Raspberry Pi OS Bookworm — `sudo ./install.sh` detects PipeWire and skips bluez-alsa automatically. Only needed on Buster/Bullseye or if forcing the bluealsa backend.

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
# bluezalsa only needed on bluez-alsa backend (not PipeWire):
sudo systemctl enable bluezalsa.service
sudo systemctl start bluezalsa.service
sudo systemctl enable btspeaker-monitor.service
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
| `codec` | No | Audio codec: `sbc` (default), `aptx`, `aac`, `sbc-xq`, `faststream`. bluez-alsa backend only — ignored in PipeWire mode (PipeWire negotiates codec internally). |
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

**Check Bluetooth device state:**
```bash
bluetoothctl info AA:BB:CC:DD:EE:FF
```

**bluealsa backend — verify ALSA device appears after speaker connects:**
```bash
aplay -L | grep bluealsa
```

**bluealsa backend — watch D-Bus PCM signals in real time:**
```bash
dbus-monitor --system "type='signal',interface='org.bluealsa.Manager1'"
```

**bluealsa backend — query active PCMs:**
```bash
busctl call org.bluealsa /org/bluealsa org.bluealsa.Manager1 GetPCMs
```

**PipeWire backend — watch BlueZ device property changes in real time:**
```bash
dbus-monitor --system "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'"
```

**PipeWire backend — verify WirePlumber is running:**
```bash
systemctl status wireplumber
pgrep -a wireplumber
```

**Inspect what was installed** (useful after a partial install or upgrade):
```bash
cat /var/lib/squeezelite-bluetooth/install.manifest
```

**Common problems:**

| Symptom | Likely cause | Fix |
|---|---|---|
| Player never appears in LMS | Speaker not trusted / not reconnecting | Re-run `sudo ./install.sh --add-device` |
| Player appears then immediately disappears | squeezelite can't reach LMS | Set `lms = <ip>` in bt-devices for that speaker |
| `bluezalsa.service` fails to start | bluealsa binary not at `/usr/bin/bluealsa` | Re-run `sudo ./install.sh` or check `which bluealsa` |
| `btspeaker-monitor.service` exits instantly | squeezelite or bt-devices not found | Check `/usr/bin/squeezelite` exists and `/etc/pyserver/bt-devices` is present |
| Sound plays but is choppy | A2DP buffer underrun | Try `export LIBASOUND_THREAD_SAFE=0` before testing manually |
| Speaker connects but no ALSA device | PipeWire conflict on Bookworm | Re-run `sudo ./install.sh` — it now detects PipeWire and switches backends |
| squeezelite keeps restarting in logs | ALSA or LMS error on startup | Check `journalctl -fu btspeaker-monitor`; set explicit `lms =` in bt-devices |
| No devices watched after `--update` | bt-devices still in old `MAC=Name` format | Restart the monitor — it auto-migrates the file and backs up the original |

---

## PipeWire support

Modern Raspberry Pi OS (**Bookworm**, 2023+) ships PipeWire by default. On these systems, bluez-alsa cannot claim the A2DP Bluetooth profile because PipeWire already owns it. The installer detects PipeWire automatically and switches to a PipeWire-native audio path — no manual configuration needed.

### What the installer does

```
sudo ./install.sh          # auto-detects PipeWire or bluez-alsa
```

| Pi OS version | Detected backend | Audio path |
|---|---|---|
| Bookworm (2023+) | PipeWire | squeezelite `-o pipewire` |
| Bullseye / Buster | bluez-alsa | squeezelite `-o bluealsa:...` |

To override auto-detection:
```bash
FORCE_AUDIO_BACKEND=pipewire  sudo ./install.sh   # force PipeWire
FORCE_AUDIO_BACKEND=bluealsa  sudo ./install.sh   # force bluez-alsa
```

### How PipeWire mode works

Instead of watching bluez-alsa's `PCMAdded`/`PCMRemoved` D-Bus signals, the monitor watches BlueZ directly for `Connected` property changes on device objects. When a trusted speaker connects, squeezelite is started with `-o pipewire`; PipeWire routes the audio automatically. When the speaker disconnects, squeezelite is stopped.

The `codec` option in `bt-devices` is **not used in PipeWire mode** — PipeWire handles codec negotiation internally.

### Requirements for PipeWire mode

- squeezelite must be compiled with PipeWire support (`-o pipewire`). The `squeezelite` package on Bookworm includes this by default. If you downloaded a binary from Sourceforge, verify it supports PipeWire with `squeezelite -o pipewire -? 2>&1 | head -5`.
- WirePlumber (PipeWire's session manager) must be running — it handles BT audio routing.
