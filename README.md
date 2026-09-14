# proxy-screen

Host-side (hypervisor-level) screen capture of an arm64 Linux guest, for
authorized security analysis: malware behavior capture, evaluating what a
browser-based monitoring/DLP/proctoring agent can and cannot detect, and
testing an in-house detection agent against ground truth.

Capture reads the emulated framebuffer inside the host QEMU process via the
QMP `screendump` command. Nothing inside the guest — including a
screen-monitoring agent running in it — participates in, or can observe,
the capture.

This is intended for use on systems the operator controls. It is not built
to target a specific third party's software, and it targets an arm64 guest
only (no x86-only malware/agent samples apply here).

## Requirements

- Apple Silicon Mac (uses QEMU's `hvf` acceleration for an arm64 `virt` guest).
- Homebrew.
- QEMU 11.1+: `brew install qemu`. The QEMU build used by this project has
  **no OpenGL/virgl support** (`qemu-system-aarch64 -display help` lists only
  `none`, `curses`, `cocoa`, `dbus` — no `gtk,gl=on` / `egl-headless`). This
  is why the stealth model spoofs GL identity at the browser level (WebGL)
  rather than relying on a real accelerated GL passthrough — see below.
- ImageMagick (`convert`/`montage`/`identify`), `tesseract`, and `ffmpeg` on
  `PATH` (`brew install imagemagick tesseract ffmpeg`).
- A Python 3 venv (`.venv/`) with `imagehash` and `pillow`, used by the
  review pipeline. `make setup` / `pipeline.sh` create this automatically.

## Quickstart

```sh
# One-time / idempotent: venv + tool checks
make setup

# Boot the guest headless (serial console only, no window)
make boot

# ...or boot with a visible desktop window (cocoa display)
make boot-gui

# From another terminal, while the guest is running: grab one frame
make capture
# repeat make capture as many times as you want; each call is a fresh
# QMP connection and does not stop the VM

# Review a session: OCR + de-dupe + contact sheet + HTML timeline
make review
open sessions/<name>/analysis/index.html
```

Raw-script equivalents (what the Makefile wraps):

```sh
./boot.sh                                   # headless boot, STEALTH=1 by default
DISPLAY_BACKEND=cocoa ./boot.sh             # boot with a visible window
./capture.sh --session demo                 # one non-destructive frame grab
./pipeline.sh --session demo                # OCR/hash/contact-sheet/index for that session
./bin/detect-selftest.sh --serial <sock> --label "STEALTH=1"
```

## How it works

```
boot.sh
  -> qemu-system-aarch64 (virt/hvf guest, virtio-gpu-pci framebuffer,
     QMP unix socket, optional serial unix socket)
       -> capture.sh / bin/capture.py
            -> QMP `screendump` -> sessions/<session>/frames/*.png
               (no `quit` sent; guest keeps running)
                 -> pipeline.sh / bin/pipeline.py
                      -> OCR (tesseract) + perceptual-hash de-dupe
                      -> sessions/<session>/analysis/manifest.json
                 -> bin/build_index.py -> analysis/index.html
                 -> ImageMagick montage -> analysis/contact.png
```

`bin/qmpshot.py` is a separate, **destructive** one-shot QMP script (it sends
`quit` after the screendump, ending the VM). It exists from an earlier phase;
day-to-day capture should use `capture.sh` / `bin/capture.py`, which never
send `quit`.

## Command reference

### `boot.sh` — env vars (all also have `--flag` equivalents shown below)

| Var | Default | Meaning |
|---|---|---|
| `DISPLAY_BACKEND` | `none` | `none` \| `cocoa` \| `spice` — QEMU `-display` |
| `CAPTURE_DEV` | `virtio-gpu-pci` | `virtio-gpu-pci` \| `ramfb` — guest framebuffer device |
| `MEM` | `4096` | Guest RAM in MiB |
| `CPUS` | `4` | vCPU count |
| `DISK` | `vm/guest.qcow2` | Path to guest qcow2 |
| `SEED` | `vm/seed.iso` if present | Optional cloud-init NoCloud seed ISO |
| `QMP_SOCK` | `./qmp.sock` | QMP unix socket path |
| `SERIAL` | `stdio` | `stdio` \| `none` \| `<path>` for a unix-socket serial console (logged to `serial.log`) |
| `ACPI_BATTERY` | unset | Vestigial no-op on arm64 (prints a warning). The fake battery is baked into the guest initrd, so `BAT0`/`ADP0` are present without any flag. **See limit 2 below.** |
| `VARS` | `vm/<disk-basename>-vars.fd` | Per-VM writable EDK2 varstore (auto-created from the EDK2 template on first use) |
| `EXTRA_ARGS` | unset | Extra raw args appended to the QEMU command line |
| `STEALTH` | `1` | `1` (default) applies the stealth hardening below; `0` boots an unhardened baseline for A/B comparison |

Flags: `--display`, `--capture`, `--mem`, `--cpus`, `--disk`, `--seed`,
`--qmp`, `--serial`, `--battery`, `--stealth` / `--no-stealth`, `--vars`,
`-- <extra args>` (env vars override nothing; flags override env).

### `capture.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--qmp <sock>` | `./qmp.sock` | QMP unix socket path |
| `--session <name>` | UTC timestamp | Session directory name under `sessions/` |
| `--device <id>` | QEMU's default head | Target a specific display device/head for screendump |
| `--out <file>` | (session scheme) | Explicit output path, overrides the session naming |
| `--verify` | off | After capture, run `identify` and warn if the frame looks blank (stddev ~= 0); still exits 0 if the file exists |

Never sends QMP `quit` — the guest is left running in all cases, success or failure.

### `pipeline.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--session <name>` | most recently modified dir under `sessions/` | Which session to process |

Steps: ensures `.venv` has `imagehash`+`pillow` -> `bin/pipeline.py` (OCR +
phash dedupe -> `analysis/manifest.json`) -> `bin/build_index.py` (->
`analysis/index.html`) -> ImageMagick `montage` (-> `analysis/contact.png`).
Requires `convert`, `montage`, `identify`, `tesseract` on `PATH`. Read-only
with respect to the VM — it only touches PNGs already on disk.

### `bin/detect-selftest.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--serial <sock>` | required | Unix-socket serial console of a *running* guest (boot with `SERIAL=<sock> ./boot.sh`) |
| `--label <text>` | `(unlabeled)` | Free-text label recorded in the report header |
| `--user` / `--pass` | `analyst` / `analyst` | Guest login used to run probe commands over serial |

Logs into the running guest over its serial console and probes 16 values
(device-tree model, 5x DMI fields, NIC MAC/OUI, disk serial, battery
`power_supply`, `glxinfo` renderer, WebGL config, `lspci` virtio ids,
cloud-init package/CIDATA/datasource, hostname, plus informational
machine-id/timezone), classifies each OK/LEAK/N/A/INFO, and writes
`sessions/selftest-<UTC>.txt`. Does not modify the guest; leaves it running.

## Stealth model and known limits

With `STEALTH=1` (the default), `boot.sh` delivers:

- **SMBIOS identity**: Lenovo ThinkPad X13s Gen 1 (21BX/21BY, arm64/Snapdragon)
  `type=0/1/2/3` strings (`sys_vendor`/`product_name`/`board_vendor`/
  `chassis_vendor`/`bios_vendor` all read as LENOVO, not QEMU/Bochs), UUID
  persisted per-install at `vm/smbios-uuid` (stable across boots, like real
  hardware) instead of randomized per boot.
- **Real-vendor NIC MAC**: an LCFC/Lenovo-family OUI (`e8:6a:64:...`)
  instead of QEMU's default `52:54:00` OUI.
- **Realistic disk serial**: the virtio-blk drive is attached explicitly
  (`if=none` + `virtio-blk-pci`) with a Samsung-style NVMe serial, visible
  in-guest via `/sys/block/vda/serial`.
- **Cloud-init cleaned up**: with stealth on, the CIDATA seed ISO is not
  attached at all (cloud-init has been purged from the guest image), which
  removes the CIDATA block device / XFCE auto-mount icon tell.
- **Bound battery**: the guest reports a real-looking battery
  (`power_supply` shows `ADP0`/`BAT0`). **This is delivered by the guest's
  own init/initrd, not by QEMU's `-acpitable` option** — see the limitation
  immediately below.
- **Firefox WebGL renderer spoof**: an in-guest Firefox profile
  (`user.js` + AutoConfig `.cfg`) overrides `UNMASKED_RENDERER_WEBGL` to a
  plausible real-GPU string (`Mesa Intel(R) UHD Graphics (CML GT2)`)
  instead of the software renderer a browser would otherwise see.

**Latest self-test result:** 1 LEAK, 14 OK (`sessions/selftest-20260913T203019Z.txt`,
label "STEALTH=1 + Phase4B webgl spoof"). The one leak is `virtio pci (1af4)`
(4 devices visible via `lspci`) — see limit (a) below.

**Known limits (be aware of these before treating this as bulletproof):**

1. **virtio PCI IDs cannot be hidden.** The guest's virtio-gpu / virtio-blk /
   virtio-net / virtio-rng devices all show vendor id `1af4` in `lspci`, a
   strong VM tell. Hiding this needs a custom QEMU build (`x-pci-vendor-id`
   patch or similar); out of scope here. This is currently the self-test's
   one remaining LEAK.
2. **`ACPI_BATTERY=1` / `--battery` is a vestigial no-op** (prints a warning
   only). QEMU's `-acpitable` is x86-only and aborts on the arm64 `virt`
   machine, so the flag no longer passes it. The fake battery is instead
   injected **guest-side** via the early-initrd ACPI table override
   (`CONFIG_ACPI_TABLE_UPGRADE`), baked into the guest's initrd — so
   `/sys/class/power_supply/BAT0` and `ADP0` are present at every boot with no
   flag. `acpi/battery.dsl`/`battery.aml` are the source table.
3. **Native `glxinfo` is out of scope and still reports the software
   renderer** (`llvmpipe` or similar). Only the *browser's* WebGL string is
   spoofed (via the Firefox profile override); anything reading GL info
   outside the browser (e.g. `glxinfo` itself, a native OpenGL app) is
   unaffected. This QEMU build has no virgl/GPU passthrough, so there is no
   real accelerated GL to point to instead.
4. **The self-test's `webgl` check is config-based**, not a live render: it
   reads the delivered override value out of the Firefox profile config
   files (`user.js` / AutoConfig `.cfg`) and classifies based on that string.
   The actual proof that a page's JS sees the spoofed value is the captured
   screenshot `webgl-proof.png` (Firefox pointed at `assets/webgl-info.html`),
   not the self-test line alone.
5. **Not undetectable to a determined kernel-level adversary.** This defeats
   common browser/JS and userspace fingerprinting (DMI, MAC OUI, disk
   serial, cloud-init artifacts, battery presence, WebGL renderer string). It
   does not defeat an adversary who can read `lspci`/`dmesg` for virtio ids,
   inspect hypervisor timing side-channels, or otherwise probe below
   userspace.
6. **Scope is arm64 only.** The guest is an arm64 Debian `virt` machine, so
   x86-only malware or agent samples do not apply.

## File / directory layout

```
boot.sh              Parameterized QEMU launcher (guest boot, stealth hardening)
capture.sh           Non-destructive on-demand screendump (wraps bin/capture.py)
pipeline.sh          Offline review pipeline for one session (wraps bin/*.py)
Makefile             make targets wrapping the above (help/setup/boot/capture/review/selftest/clean)
bin/
  capture.py           QMP screendump, no quit sent (used by capture.sh)
  qmpshot.py           DESTRUCTIVE one-shot QMP screendump + quit (legacy/manual use only)
  pipeline.py          OCR + perceptual-hash de-dupe -> analysis/manifest.json
  build_index.py       Builds analysis/index.html from manifest.json
  serialcmd.py         Scripted login + command probes over a serial unix socket
  seriallog.py/serialtap.py   Serial console logging/tap helpers
  detect-selftest.sh   VM-detection self-test over the serial console
vm/                  Guest disk image(s), EDK2 varstore, cloud-init seed ISO (large; gitignored)
sessions/            Per-session frames/ + analysis/ + selftest-*.txt reports (gitignored)
acpi/                battery.dsl / battery.aml (ACPI battery table source; see limit 2 above)
assets/              webgl-info.html (page used to produce webgl-proof.png)
.venv/               Python venv for the review pipeline (imagehash + pillow; gitignored)
seed/                cloud-init NoCloud source (meta-data/user-data) used to build vm/seed.iso
```
