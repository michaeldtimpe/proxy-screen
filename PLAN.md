# proxy-screen — Out-of-VM screen capture harness

**Purpose.** A host-side tool that captures the framebuffer of a Linux guest VM directly from the
hypervisor, on demand, and writes frames to host storage for later review. Because the capture reads
the emulated display adapter's memory in the host QEMU process, nothing inside the guest — including a
browser-based screen-monitoring agent — participates in or can observe the capture.

**Frame.** This is an authorized analysis/research harness for use on systems the operator controls:
malware behavior capture, evaluating what a monitoring/DLP/proctoring agent can and cannot detect, and
testing an in-house agent against ground truth. It is not built to target a specific third party's
production system without authorization. The plan is honest about detection limits (see §6).

---

## 1. Key decisions (from scouting)

| Decision | Choice | Why |
|---|---|---|
| Hypervisor front-end | **Raw QEMU**, not UTM | UTM does not expose QMP; `utmctl` has no screenshot command and its guest commands need an in-guest agent, which violates the no-agent requirement. Run `qemu-system-*` directly with our own QMP socket. |
| Guest architecture | **arm64 (aarch64) Linux — CONFIRMED** | On Apple Silicon, HVF only accelerates a same-arch guest. An arm64 guest runs accelerated and sidesteps the entire x86 CPUID-hypervisor-bit / RDTSC detection class. Scope boundary: this covers browser/redirect analysis and arm64-native code. It will not detonate x86-only samples — those need an x86 q35 guest under slow TCG emulation, whose timing is itself a strong VM tell, and are out of scope for this build. |
| Display / desktop use | Interactive backend (`-display cocoa` native window, or SPICE/VNC) **or** `-display none` for headless. `screendump` works with any of them. | The operator uses the guest as a normal Linux desktop through a cocoa window or SPICE viewer, while a host script triggers `screendump` over QMP at the same time — the two are independent because screendump reads the emulated display's memory in the host process regardless of backend. **Avoid the dedicated headless virtio-gpu render mode** — per QEMU docs it may not copy frames into the buffer screendump reads, yielding blank/stale images. Capture device (Phase 0 verified): `ramfb` is simplest and fastest for headless work (~8 ms, 800x600); for interactive desktop use and WebGL realism prefer `virtio-gpu-pci` at a real resolution (also captures cleanly, ~15 ms). |
| Capture channel | Host QMP unix socket: `-qmp unix:/path,server,nowait` | On-demand trigger from a host script: handshake `qmp_capabilities`, then `screendump`. |
| Output format | PNG (needs **QEMU ≥ 7.1**); PPM fallback | Pin/verify the QEMU version. On older builds only PPM is produced regardless of extension. |
| In-guest footprint | **None on the capture path** | screendump reads emulated VRAM in the host process. The guest only needs a stock display driver to set a video mode. Confirmed high-confidence by scouting. |

---

## 2. Architecture

```
 macOS host (Apple Silicon)
 ┌──────────────────────────────────────────────────────────┐
 │  qemu-system-aarch64  -machine virt,accel=hvf             │
 │    ├─ display device (virtio-vga / std VGA / ramfb)       │
 │    │     └─ emulated VRAM  ◄──── screendump reads here     │
 │    ├─ -display none            (no host window)           │
 │    └─ -qmp unix:/run/ps.sock,server,nowait                │
 │                     ▲                                      │
 │   capture.sh ───────┘  (qmp_capabilities → screendump)    │
 │        │                                                   │
 │        ▼                                                   │
 │   frames/  ──►  pipeline (PPM→PNG, contact sheet, OCR,     │
 │                 perceptual-hash diff, timeline index)      │
 └──────────────────────────────────────────────────────────┘
        Guest sees only a normal display adapter. It has no
        process, driver, or signal tied to the capture.
```

## 3. Stealth (full-stealth requirement)

Two surfaces to harden. Be precise about which is which.

**Native/root code in the guest** can read hardware identity. QEMU knobs:
- `-cpu host,hypervisor=off` to clear the CPUID hypervisor bit (documented for x86/KVM; **verify under HVF** — flagged UNKNOWN). arm64 has no equivalent CPUID bit, another reason to prefer arm64.
- `-smbios type=1,manufacturer=...,product=...,serial=...` to overwrite DMI vendor strings.
- Custom `mac=` on the NIC to avoid the `52:54:00` QEMU OUI.
- Prefer emulated **e1000 / AHCI (SATA)** over virtio to avoid the `1af4` (Red Hat/Qumranet) virtio PCI vendor ID.

**Environment realism — a bare VM's absence of a "real machine" is one of the biggest tells, and sandbox-aware malware/redirect gates check it.** These need no physical hardware; ACPI is table-driven, so you present the device as a table entry and the guest's stock generic driver binds to it:
- **Battery + AC adapter** via an injected ACPI SSDT (identifiers `PNP0C0A` battery, `ACPI0003` AC). Linux's generic `battery`/`ac` drivers populate `/sys/class/power_supply/BAT0` and `AC0`. This is the "stub driver, no hardware" model. In QEMU it is a supplied table, not a single flag, so exact mechanism is a Phase 0 item — and on the arm64 `virt` machine it is less trodden than on x86 q35, so verify it binds (boot with `acpi=on`).
- **Sleep states (S3/S4)** advertised in ACPI; a real machine has them, a default VM often does not.
- **Thermal zones**, plausible SMBIOS as above, realistic MAC and disk serial.
- **Behavioral realism**, which modern evasion checks as much as hardware: non-trivial uptime, a real user profile, installed apps, recent files, mouse movement. Cheap to fake, high payoff.

**arm64-specific tells to expect:** the device-tree `model = "linux,dummy-virt"` string and `MIDR_EL1`/CPU identity read as virtual. arm64 has no x86-style CPUID hypervisor bit to worry about, but the `virt` platform is recognizably synthetic to native code — another reason the browser-facing surface below is the priority for the redirect use case.

**Browser JavaScript sees almost no hardware.** It cannot read CPUID, DMI, PCI IDs, ACPI, or MAC. What it can see, in priority order:
1. **WebGL `UNMASKED_RENDERER_WEBGL`** — the single strongest browser-facing tell. Values like `llvmpipe`, `SwiftShader`, `VirGL` scream software rendering. Mitigation: give the guest GPU-backed GL (virtio-gpu venus/virgl through ANGLE→Metal) or spoof the renderer string in the browser under test.
2. `navigator.hardwareConcurrency` / `deviceMemory` — set vCPU/RAM to plausible desktop values.
3. `performance.now()` timing — already coarsened by browsers (~100µs–2ms) as a Spectre mitigation, which helps.

**Cannot be hidden by flags alone (be honest):**
- Std VGA PCI ID is hardcoded `1234:1111` (Bochs heritage). Using a different display device or a patched QEMU build is the only way around it.
- ACPI OEM strings `BOCHS`/`BXPC` require a patched QEMU build, not a CLI flag.
- If forced to x86/TCG, software-emulated timing is a strong, largely unfixable tell.

## 4. Host-side storage & review pipeline

- Frame dir per session: `sessions/<UTC-stamp>/frames/frame_<UTC-stamp>_<seq>.png`.
- PPM→PNG conversion via ImageMagick or ffmpeg (only needed on QEMU < 7.1).
- Contact sheet / timeline via `montage`; optional MP4 rollup via ffmpeg.
- OCR via `tesseract` to make frames text-searchable.
- Perceptual-hash diffing via Python `imagehash` to flag frames that changed, so review skips duplicates.
- On-demand now; directory scheme leaves room to add periodic/event triggers later.

All tools are Homebrew-installable; no exotic dependencies.

## 5. Phase 0 spike — RESULTS (run 2026-09-13, verified on this machine)

Host: Apple Silicon, macOS 26.6, 18 cores, 128 GB RAM. QEMU installed via Homebrew.

| Question | Result |
|---|---|
| QEMU present + version | **QEMU 11.1.1** — far above the 7.1 PNG gate. **PNG `screendump` confirmed.** |
| HVF acceleration | **Available.** `virt,accel=hvf -cpu host` boots with no error. |
| Live non-blank capture, headless | **Yes**, proven by capturing the UEFI shell with `-display none` over a QMP unix socket, no disk, no in-guest agent. |
| Best capture device | **`ramfb`**: 800x600, single dump ~8 ms, no PCI/driver init. `virtio-gpu-pci` also works (1280x800, ~15 ms). Avoid the dedicated headless virtio-gpu variant. |
| Firmware | `edk2-aarch64-code.fd` + `edk2-arm-vars.fd` ship with the QEMU formula under `/opt/homebrew/share/qemu/`. |

Reusable driver: `qmpshot.py` (connect QMP unix socket → `qmp_capabilities` → `screendump` → `quit`). `screendump` filename must be an absolute path. Missing pipeline deps to add later: `socat` (optional; `nc -U`/python work), Python `imagehash` (Phase 3 only).

## 5b. Phase 1 results (verified on this machine)

- **Harness + guest built.** `boot.sh` launcher; Debian 12 arm64 cloud-image guest provisioned non-interactively (cloud-init), user `analyst`. Boots under HVF.
- **Live capture of the booted OS: proven.** Console login and, after installing XFCE, a full desktop, both captured from the host over QMP (`desktop.png`, 1280x800, clearly non-blank).
- **Desktop is usable.** XFCE 4.18 with autologin renders on the virtio-gpu framebuffer; the operator will interact through `-display cocoa`, and capture is backend-independent so it coexists.
- **Fake battery — DONE (Phase 4).** `-acpitable` is x86-only; configfs is absent from Debian's arm64 kernel; the working path is the **early-initrd ACPI table override** (`CONFIG_ACPI_TABLE_UPGRADE=y`). Implemented and bound: `/sys/class/power_supply/BAT0` + `ADP0` present, dmesg confirms the SSDT loaded.
- **WebGL renderer — DONE (Phase 4).** Native GL stays `llvmpipe` (Homebrew QEMU lacks OpenGL/virgl, and even virgl would be a tell), so the fix is a **browser-level spoof**: Firefox `webgl.override-unmasked-renderer`/`-vendor` + `sanitize-unmasked-renderer=false` now report `Mesa Intel(R) UHD Graphics`. Note: the historically-cited pref names `webgl.renderer-string-override`/`vendor-string-override` do not exist in current Firefox (140esr) — the `override-unmasked-*` names are correct.

## 6. Honest detection limits

A determined agent running native code in the guest can still find VM artifacts (std VGA PCI ID, ACPI
OEM strings, HVF-specific timing quirks, device-tree strings like `dummy-virt` on arm64). Full stealth
here means "raises the bar substantially and defeats browser-JS-level and common native checks," not
"undetectable by an adversary with kernel access and unlimited effort." The capture itself remains
invisible to the guest regardless, because it happens entirely in the host process.

---

## 7. Delegated build plan (model routing)

Fable plans and QAs; Opus does the tricky implementation; Sonnet/Haiku take scoped and mechanical work.
Each phase has acceptance criteria; QA reads the real diff/output, never trusts the report.

| Phase | Work | Model | Acceptance criteria |
|---|---|---|---|
| **0. Spike** | Resolve the four §5 unknowns on the actual machine; report findings only, no product code | `haiku` runs commands, **Fable interprets** | A short findings note stating: screendump live-image yes/no per device, hypervisor=off effect under HVF, latency, local QEMU version |
| **1. Launch harness** | `boot.sh`: raw qemu-system-aarch64 with HVF, chosen display device, selectable backend (`-display cocoa`/SPICE for desktop use, `-display none` for headless), QMP socket; documented guest install steps | `opus` | VM boots and is usable as a desktop through the chosen backend; QMP socket accepts a handshake; a live capture works while the desktop is in use |
| **2. Capture trigger — DONE** | `capture.sh` + `bin/capture.py`: fresh QMP connect → `qmp_capabilities` → `screendump` PNG to `sessions/<name>/frames/frame_<UTC>_<seq>.png`, **no `quit`** so the VM keeps running; `--verify` optional blank check; clear nonzero errors. | `sonnet` | ✅ 3 frames captured while QEMU PID stayed alive; ~85–95 ms/frame; missing-socket exits 1; verified by Fable |
| **3. Pipeline — DONE** | `pipeline.sh` + `bin/pipeline.py` (OCR + phash dedup/change-detection → `manifest.json`) + `bin/build_index.py` (`index.html` timeline) + montage `contact.png`; deps in project `.venv`. | `sonnet` | ✅ dedup collapses identical frames, transitions flagged changed, tesseract OCR extracts real text, contact sheet + HTML index built; verified by Fable |
| **4. Stealth layer — DONE** | `boot.sh` STEALTH=1: Lenovo SMBIOS (type 0/1/2/3), real-OUI MAC, disk serial. Guest behavioral cleanup (cloud-init/CIDATA purged, normal hostname/machine-id, home footprint). **Battery BOUND** via early-initrd ACPI override (`battery.aml` cpio prepended to the initrd; `-acpitable` is x86-only). **WebGL renderer spoofed** in Firefox via `webgl.override-unmasked-renderer`/`-vendor` + `webgl.sanitize-unmasked-renderer=false` (user.js + locked AutoConfig) to a Mesa/Intel string matching the ThinkPad identity. `bin/detect-selftest.sh` measures leaks. | `opus` ×2 | ✅ self-test 12→1 leak; BAT0/ADP0 present; WebGL reports `Mesa Intel(R) UHD Graphics`, not llvmpipe (proof capture). **Remaining leak: virtio PCI (1af4)** — unfixable without a custom QEMU build; native `glxinfo` stays llvmpipe because Homebrew QEMU is built without OpenGL/virgl. |
| **5. Glue & docs** | README, `justfile`/`Makefile` targets, config scaffolding | `haiku` | Commands documented; targets run end-to-end |
| **QA** | Read every diff, run the self-test and pipeline, check against criteria above | **Fable** | Diffs match claims; self-test and a real capture both succeed |

**Sequencing.** Phase 0 first (gates everything). Phases 1→2→4 are dependent (same launch harness),
run sequentially. Phase 3 (pipeline) is independent of the VM and can run in parallel with 1/2. Phase 5
last.

**Discipline carried from the delegate skill.** One subsystem per agent; every implementer prompt caps
exploration and requires pasting real `git diff --stat` and command output; a report is never accepted
as done without checking the diff; two consecutive fabrications and the rest is done directly.
