# proxy-screen

A macOS + QEMU/HVF harness that boots an arm64 Linux guest and captures its
screen from the **host**, via QMP `screendump`, so the capture is invisible
to anything running inside the guest — including a browser-based
screen-monitoring agent or sandbox-aware malware trying to detect or block
it. The guest also presents a believable non-VM hardware identity (Lenovo
ThinkPad X13s Gen 1 SMBIOS, real NIC vendor OUI, a fake battery baked into
the initrd, and a matching spoofed WebGL renderer string), so samples that
go dormant when they detect a sandbox keep running instead.

## ⚠️ Authorized use only

This is a **dual-use security-research tool**. It is intended for:

- Malware behavior capture and analysis on samples you are authorized to run.
- Evaluating what a browser-based monitoring/DLP/proctoring agent can and
  cannot detect (i.e. testing *your own* monitoring tooling's blind spots).
- Testing an in-house detection/agent product against ground truth.

It is **not** for evading legitimate oversight, monitoring, or proctoring
that you are subject to and expected to comply with, and it is not built to
target a specific third party's system without authorization. Only run it
against systems and samples you control or are explicitly authorized to
analyze. See [SECURITY.md](SECURITY.md) for the full responsible-use
statement. Provided with **no warranty**; you are responsible for how you
use it.

## Requirements

- Apple Silicon Mac (uses QEMU's `hvf` acceleration for an arm64 `virt` guest).
- Homebrew.
- QEMU 11.1+: `brew install qemu`. The QEMU build used by this project has
  **no OpenGL/virgl support** (`qemu-system-aarch64 -display help` lists only
  `none`, `curses`, `cocoa`, `dbus` — no `gtk,gl=on` / `egl-headless`). This
  is why the stealth model spoofs GL identity at the browser level (WebGL)
  rather than relying on real accelerated GL passthrough — see
  [Stealth model & limitations](#stealth-model--limitations).
- ImageMagick (`convert`/`montage`/`identify`), `tesseract`, and `ffmpeg` on
  `PATH` (`brew install imagemagick tesseract ffmpeg`).
- A Python 3 venv (`.venv/`) with `imagehash` and `pillow`, used by the
  review pipeline. `make setup` / `pipeline.sh` create this automatically.
- Optional, only for the active redirect-chain capture: mitmproxy
  (`brew install mitmproxy`) — see
  [Network visibility: PCAP vs. mitmproxy](#network-visibility-pcap-vs-mitmproxy).

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
       -> capture.sh / bin/capture.py       (single on-demand frame)
       -> record.sh                        (interval loop over capture.sh)
            -> QMP `screendump` -> sessions/<session>/frames/*.png
               (no `quit` sent; guest keeps running)
                 -> bin/session-meta.py -> sessions/<session>/session.json
                 -> pipeline.sh / bin/pipeline.py
                      -> OCR (tesseract) + perceptual-hash de-dupe
                      -> sessions/<session>/analysis/manifest.json
                 -> bin/build_index.py -> analysis/index.html
                      (includes a provenance header from session.json)
                 -> ImageMagick montage -> analysis/contact.png
```

`bin/qmpshot.py` is a separate, **destructive** one-shot QMP script (it sends
`quit` after the screendump, ending the VM). It exists from an earlier phase;
day-to-day capture should use `capture.sh` / `bin/capture.py`, which never
send `quit`.

## Analysis workflow

A typical malware/redirect analysis run looks like this:

```sh
# 1. Stage the sample(s) onto a read-only ingress ISO
./ingress.sh ~/samples/dropper.bin --out vm/ingress.iso --label SAMPLES
# prints the INGRESS_ISO=... ./boot.sh line to copy/paste

# 2. Boot a disposable, clean-state guest with network + sample visibility
PCAP=sessions/run1/traffic.pcap \
EPHEMERAL=1 \
INGRESS_ISO="$PWD/vm/ingress.iso" \
SERIAL=./serial.sock \
  ./boot.sh
# EPHEMERAL boots a throwaway overlay of vm/golden.qcow2 (see snapshot.sh);
# all guest writes vanish when qemu exits, so the next sample starts clean.

# 3. In another terminal, record the screen for the run's duration
./record.sh --session run1 --interval 5 --duration 300 --note "dropper.bin"

# 4. (optional) also capture the decrypted redirect chain
./proxy.sh                       # SESSION=run1 PROXY_PORT=8080 ./proxy.sh
# then inside the guest:
#   sudo PROXY_PORT=8080 bin/guest-proxy-setup.sh

# 5. Review
./pipeline.sh --session run1
open sessions/run1/analysis/index.html
```

For network visibility, reach for the passive `PCAP=` capture first; only
add the active mitmproxy step when you need fully decrypted URLs — see the
tradeoff below.

## Network visibility: PCAP vs. mitmproxy

Two ways to see what the guest talks to on the network, with a real
detectability tradeoff between them:

1. **Passive — `PCAP=<file>` on `boot.sh` (recommended first).** Attaches a
   host-side `filter-dump` to the guest's netdev; nothing is installed in
   the guest and nothing about the guest's configuration changes, so this
   is **undetectable** from inside the VM. Gives you TLS SNI and destination
   IPs for every hop — enough to see the shape of a redirect chain — but
   not decrypted URLs, `Location` headers, or bodies.
2. **Active — `proxy.sh` + `bin/guest-proxy-setup.sh` (mitmproxy).** Runs
   `mitmdump` on the host (`brew install mitmproxy`) with the
   `bin/redirect-log.py` addon; `bin/guest-proxy-setup.sh` (run inside the
   guest) points the system + Firefox at the host proxy
   (`10.0.2.2:<PROXY_PORT>`, the QEMU user-net gateway) and installs the
   mitmproxy CA. This logs the **full decrypted redirect chain**: exact
   URLs, `Location` headers on 3xx hops, and best-effort detection of
   client-side `<meta http-equiv="refresh">` and JS
   (`location.href=`/`location.replace(`/`window.location=`) redirects.
   This is what directly serves the "a sandbox gets served a plain landing
   page, a real host keeps walking the chain" use case — but the installed
   CA and the proxy environment variables are **themselves detectable
   tells** that a sophisticated sample can fingerprint (an unexpected
   `mitmproxy` root CA, `http_proxy`/`https_proxy` pointing at an RFC1918
   gateway, a Firefox enterprise policy pinning both). `guest-proxy-setup.sh
   --off` removes all of it again.

Logs from the active path land at
`sessions/<name>/proxy/redirects.jsonl` (one JSON event per hop) and
`sessions/<name>/proxy/redirects.txt` (human-readable).

## Command / flag reference

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
| `PCAP` | unset | Host-side pcap file of all guest NIC traffic (`-object filter-dump` on netdev `net0`). Invisible to the guest. See [Network visibility](#network-visibility-pcap-vs-mitmproxy). |
| `EPHEMERAL` | unset | `1` boots a disposable qcow2 overlay of a golden/base image; all guest writes are discarded on exit. Pairs with `snapshot.sh golden`. |
| `GOLDEN` | `vm/golden.qcow2` if present, else `DISK` | Backing image used when `EPHEMERAL=1`. |
| `INGRESS_ISO` | unset | Path to a read-only ISO (built by `ingress.sh`) attached as a removable USB mass-storage device — a sample-delivery vector. |
| `LOWVIRTIO` | unset | **EXPERIMENTAL.** `1` swaps NIC `virtio-net-pci` -> `e1000e` and disk `virtio-blk-pci` -> `nvme` to shrink the virtio (`1af4`) PCI fingerprint. May need guest driver support and may change the boot device path — validate the guest still boots before relying on it. |

Flags: `--display`, `--capture`, `--mem`, `--cpus`, `--disk`, `--seed`,
`--qmp`, `--serial`, `--battery`, `--stealth` / `--no-stealth`, `--vars`,
`--pcap <file>`, `--ephemeral`, `--ingress <iso>`, `--low-virtio`,
`-- <extra args>` (env vars override nothing; flags override env).

### `snapshot.sh` — golden/overlay disk management

```sh
./snapshot.sh golden [--from vm/guest.qcow2] [--force]   # flatten -> read-only vm/golden.qcow2
./snapshot.sh new    [--out vm/guest.qcow2]               # fresh CoW overlay backed by golden
./snapshot.sh reset  [--disk vm/guest.qcow2] [--yes]       # DESTRUCTIVE: discard overlay, recreate from golden
./snapshot.sh info                                         # qemu-img info --backing-chain for golden + overlay
```

`golden` refuses to overwrite an existing golden image unless `--force`.
Overlays always carry an **absolute** backing-file path, so they stay valid
regardless of the directory they're booted from. This is what `boot.sh
EPHEMERAL=1` uses under the hood, and what makes clean-state re-runs
(sample after sample, from the same known baseline) possible.

### `ingress.sh` — sample delivery ISO

```sh
./ingress.sh <path> [<path>...] [--out vm/ingress.iso] [--label SAMPLES]
```

Stages one or more host files/directories into a temp directory, builds an
ISO9660+Joliet image with macOS `hdiutil makehybrid`, and prints the
`INGRESS_ISO=... ./boot.sh` line to copy/paste. The guest sees the result as
a removable, read-only USB volume.

### `capture.sh` — single on-demand screenshot

| Flag | Default | Meaning |
|---|---|---|
| `--qmp <sock>` | `./qmp.sock` | QMP unix socket path |
| `--session <name>` | UTC timestamp | Session directory name under `sessions/` |
| `--device <id>` | QEMU's default head | Target a specific display device/head for screendump |
| `--out <file>` | (session scheme) | Explicit output path, overrides the session naming |
| `--verify` | off | After capture, run `identify` and warn if the frame looks blank (stddev ~= 0); still exits 0 if the file exists |

Never sends QMP `quit` — the guest is left running in all cases, success or failure.

### `record.sh` — interval capture loop

```sh
./record.sh --session <name> [--interval 5] [--duration 300] \
            [--qmp ./qmp.sock] [--device <id>] [--note "text"]
```

Wraps `capture.sh` on a fixed cadence; owns no QMP/screendump logic of its
own — every frame goes through `capture.sh` unmodified. `--duration 0`
(default) runs until `SIGINT`/`SIGTERM`; either signal stops the loop
cleanly (no half-written frame) and prints how many frames were captured.
Writes/updates `sessions/<name>/session.json` via `bin/session-meta.py`
before the first capture.

### `bin/session-meta.py` — session provenance

```sh
python3 bin/session-meta.py write --session <name> [--note "text"] \
                                   [--interval N] [--duration N]
```

Writes `sessions/<name>/session.json`: `created_utc` (preserved across
repeat calls), `host`, `qemu_version`, `git_rev` of this repo, `note`,
`interval`/`duration`. `bin/build_index.py` renders this as a provenance
header at the top of `analysis/index.html`. Called automatically by
`record.sh`; stdlib only, no venv needed.

### `pipeline.sh`

| Flag | Default | Meaning |
|---|---|---|
| `--session <name>` | most recently modified dir under `sessions/` | Which session to process |

Steps: ensures `.venv` has `imagehash`+`pillow` -> `bin/pipeline.py` (OCR +
phash dedupe -> `analysis/manifest.json`) -> `bin/build_index.py` (->
`analysis/index.html`, including the session's provenance header) ->
ImageMagick `montage` (-> `analysis/contact.png`). Requires `convert`,
`montage`, `identify`, `tesseract` on `PATH`. Read-only with respect to the
VM — it only touches PNGs (and `session.json`) already on disk.

### `proxy.sh` — redirect-chain MITM proxy (host side)

```sh
SESSION=run1 PROXY_PORT=8080 ./proxy.sh
```

Requires `mitmdump` (`brew install mitmproxy`; the script will not install
it for you). Launches `mitmdump` with the `bin/redirect-log.py` addon
loaded, listening on `127.0.0.1:<PROXY_PORT>` (reachable from the guest at
`10.0.2.2:<PROXY_PORT>`, the QEMU user-net gateway). Logs to
`sessions/<name>/proxy/redirects.jsonl` and `redirects.txt`. See
[Network visibility](#network-visibility-pcap-vs-mitmproxy) for the
detectability tradeoff versus `PCAP=`.

### `bin/guest-proxy-setup.sh` — run inside the guest

```sh
sudo PROXY_PORT=8080 bin/guest-proxy-setup.sh            # fetch CA via mitm.it
sudo bin/guest-proxy-setup.sh --cert /path/to/mitm.pem   # use a local CA
sudo bin/guest-proxy-setup.sh --off                      # remove everything
```

Points system proxy env vars and a Firefox enterprise policy at the host
proxy and trusts the mitmproxy CA. `--off` tears all of it back down
(proxy env, Firefox policy, CA). Read the detectability warning in the
script header before using this instead of `PCAP=`.

### `bin/guest-webgl-spoof.sh` — run inside the guest

```sh
./bin/guest-webgl-spoof.sh [--user <name>] [--print]
```

Sets Firefox's `UNMASKED_RENDERER_WEBGL` / `UNMASKED_VENDOR_WEBGL` to
`FD690` / `freedreno` — the Mesa **freedreno** gallium driver's strings for
an Adreno 690 GPU, which is the real GPU in a Snapdragon 8cx Gen 3 (the SoC
in the Lenovo ThinkPad X13s Gen 1 this guest's SMBIOS identity claims to
be). freedreno's `fd_screen_get_name()` returns bare `"FD%03d"` (device id
690, no `"Mesa"` prefix — unlike Intel's iris driver), and
`fd_screen_get_vendor()` returns `"freedreno"`
(`src/gallium/drivers/freedreno/freedreno_screen.c`). This replaces an
earlier x86 Intel GPU spoof value, which was an arch/vendor mismatch on an
arm64-identified guest — a cheap tell of its own.

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
Last known state: **1 LEAK, 14 OK** — the one leak is `virtio pci (1af4)`
(see [Stealth model & limitations](#stealth-model--limitations));
`LOWVIRTIO=1` on `boot.sh` is the opt-in lever against that last leak.

## Stealth model & limitations

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
  own init/initrd, not by QEMU's `-acpitable` option** — see limit 2 below.
- **Firefox WebGL renderer spoof**: an in-guest Firefox profile
  (`user.js` + AutoConfig `.cfg`, applied by `bin/guest-webgl-spoof.sh`)
  overrides `UNMASKED_RENDERER_WEBGL`/`UNMASKED_VENDOR_WEBGL` to `FD690`/
  `freedreno` — the real Mesa freedreno driver strings for the Adreno 690
  GPU a Snapdragon 8cx Gen 3 (the SMBIOS-claimed ThinkPad X13s) actually
  has, so the GPU identity is now consistent with the arm64/SMBIOS identity
  instead of the earlier x86 Intel string.
- **Opt-in, not always on**: `PCAP=`/`EPHEMERAL=`/`INGRESS_ISO=` add
  analysis capability without changing the guest's fingerprint (pcap is
  host-side only; an ephemeral overlay and an ingress ISO are both
  transparent to in-guest fingerprinting). `LOWVIRTIO=1` is the one flag
  that changes the fingerprint itself (see limit 1) and is experimental.

**Latest self-test result:** 1 LEAK, 14 OK (`sessions/selftest-20260913T203019Z.txt`,
label "STEALTH=1 + Phase4B webgl spoof"). The one leak is `virtio pci (1af4)`
(4 devices visible via `lspci`) — see limit 1 below.

**Known limits (be aware of these before treating this as bulletproof):**

1. **virtio PCI IDs cannot fully be hidden.** The guest's virtio-gpu /
   virtio-blk / virtio-net / virtio-rng devices all show vendor id `1af4` in
   `lspci`, a strong VM tell. `LOWVIRTIO=1` on `boot.sh` swaps the NIC and
   disk to `e1000e`/`nvme` to shrink this surface, but virtio-gpu and
   virtio-rng remain; fully hiding `1af4` needs a custom QEMU build
   (`x-pci-vendor-id` patch or similar), out of scope here. `LOWVIRTIO` is
   EXPERIMENTAL — validate the guest still boots before relying on it. This
   is currently the self-test's one remaining LEAK.
2. **`ACPI_BATTERY=1` / `--battery` is a vestigial no-op** (prints a warning
   only). QEMU's `-acpitable` is x86-only and aborts on the arm64 `virt`
   machine, so the flag no longer passes it. The fake battery is instead
   injected **guest-side** via the early-initrd ACPI table override
   (`CONFIG_ACPI_TABLE_UPGRADE`), baked into the guest's initrd — so
   `/sys/class/power_supply/BAT0` and `ADP0` are present at every boot with no
   flag. `acpi/battery.dsl`/`battery.aml` are the source table.
3. **No real GPU acceleration, so WebGL spoofing is string-level only.**
   This QEMU build has no virgl/GPU passthrough, so there is no real
   accelerated GL to point to. Native `glxinfo` is out of scope and still
   reports the software renderer (`llvmpipe` or similar); only the
   *browser's* WebGL identity strings are overridden (via the Firefox
   profile), not the underlying rendering path. Anything that reads GL
   info outside the browser (e.g. `glxinfo` itself, a native OpenGL app,
   or a check that renders something and inspects pixel-level behavior
   rather than just the reported strings) is unaffected.
4. **The self-test's `webgl` check is config-based**, not a live render: it
   reads the delivered override value out of the Firefox profile config
   files (`user.js` / AutoConfig `.cfg`) and classifies based on that string.
   The actual proof that a page's JS sees the spoofed value is a captured
   screenshot of Firefox pointed at `assets/webgl-info.html`
   (`webgl-proof.png`), not the self-test line alone.
5. **The active mitmproxy path is itself detectable.** Installing a MITM CA
   into the guest trust store and setting `http_proxy`/`https_proxy` are
   both checkable by a sophisticated sample (unexpected root CA name,
   proxy pointed at an RFC1918 gateway, a pinned Firefox enterprise
   policy). Prefer the passive `PCAP=` capture unless you specifically need
   the decrypted chain — see
   [Network visibility](#network-visibility-pcap-vs-mitmproxy).
6. **Not undetectable to a determined kernel-level adversary.** This defeats
   common browser/JS and userspace fingerprinting (DMI, MAC OUI, disk
   serial, cloud-init artifacts, battery presence, WebGL renderer string). It
   does not defeat an adversary who can read `lspci`/`dmesg` for virtio ids,
   inspect hypervisor timing side-channels, or otherwise probe below
   userspace.
7. **Scope is arm64 only.** The guest is an arm64 Debian `virt` machine, so
   x86-only malware or agent samples do not apply.

## File / directory layout

```
boot.sh              Parameterized QEMU launcher (guest boot, stealth hardening,
                      PCAP/EPHEMERAL/INGRESS_ISO/LOWVIRTIO opt-in flags)
snapshot.sh           Golden/overlay disk-state management (golden/new/reset/info)
ingress.sh            Packs host files into a read-only sample-delivery ISO
capture.sh            Non-destructive on-demand screendump (wraps bin/capture.py)
record.sh             Interval capture loop wrapping capture.sh + session provenance
pipeline.sh           Offline review pipeline for one session (wraps bin/*.py)
proxy.sh              Host-side launcher for the redirect-chain MITM proxy (mitmdump)
Makefile              make targets wrapping the above (help/setup/boot/capture/record/golden/review/selftest/clean)
bin/
  capture.py           QMP screendump, no quit sent (used by capture.sh)
  qmpshot.py           DESTRUCTIVE one-shot QMP screendump + quit (legacy/manual use only)
  pipeline.py          OCR + perceptual-hash de-dupe -> analysis/manifest.json
  build_index.py       Builds analysis/index.html from manifest.json + session.json
  session-meta.py      Writes sessions/<name>/session.json provenance
  redirect-log.py      mitmproxy addon: logs the decrypted redirect chain (JSONL + text)
  guest-proxy-setup.sh Run INSIDE the guest: points it at proxy.sh + trusts its CA
  guest-webgl-spoof.sh Run INSIDE the guest: sets Firefox WebGL to FD690/freedreno
  serialcmd.py         Scripted login + command probes over a serial unix socket
  seriallog.py/serialtap.py   Serial console logging/tap helpers
  detect-selftest.sh   VM-detection self-test over the serial console
vm/                  Guest disk image(s), golden.qcow2, EDK2 varstore, cloud-init
                      seed ISO, ingress ISO (large; gitignored)
sessions/            Per-session frames/ + analysis/ + proxy/ + session.json +
                      selftest-*.txt reports (gitignored)
acpi/                battery.dsl / battery.aml (ACPI battery table source; see limit 2 above)
assets/              webgl-info.html (page used to produce webgl-proof.png)
.venv/               Python venv for the review pipeline (imagehash + pillow; gitignored)
seed/                cloud-init NoCloud source (meta-data/user-data) used to build vm/seed.iso
```

## License

[MIT](LICENSE). See also [SECURITY.md](SECURITY.md) for the responsible-use
statement and no-warranty disclaimer.
