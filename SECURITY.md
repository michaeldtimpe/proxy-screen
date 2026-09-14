# Security & responsible use

`proxy-screen` is a dual-use security-research harness: a macOS + QEMU/HVF
tool that boots an arm64 Linux guest, captures its screen from the host
(invisible to the guest), and gives that guest a believable non-VM hardware
identity. Those same properties make it useful for legitimate analysis and
also, in principle, misusable. This document states the intended use and the
project's no-warranty position plainly.

## Intended, authorized use cases

- **Malware behavior capture and analysis** of samples you are authorized to
  run, in an isolated guest you control.
- **Evaluating monitoring/DLP/proctoring tooling** — testing what a
  browser-based screen-monitoring agent can and cannot detect or block,
  against your own monitoring product or one you are authorized to assess.
- **Testing your own in-house detection/agent software** against ground
  truth (a known-good capture of what actually happened on screen).

All of the above assume the guest, the samples run in it, and any monitored
software are ones you own, control, or have explicit authorization to test.

## Not an intended use

This tool is **not** for evading legitimate oversight, monitoring, or
proctoring that you are personally subject to and expected to comply with
(e.g. an employer's endpoint monitoring, an exam proctoring system, or any
other oversight you have agreed to). It is not built to target, monitor, or
gain access to a third party's system without their authorization. The
stealth features exist to produce realistic, ground-truth conditions for
security research — not to help a user quietly defeat controls they are
supposed to be subject to.

Using this tool against systems, accounts, or samples you do not own or are
not explicitly authorized to test may violate the law (including computer
fraud/anti-hacking statutes) and/or agreements you are party to (terms of
service, employment/proctoring agreements, acceptable-use policies). You are
responsible for ensuring your use is authorized and lawful in your
jurisdiction.

## No warranty

This software is provided "as is," without warranty of any kind, express or
implied — see [LICENSE](LICENSE) (MIT) for the full disclaimer. The stealth
techniques documented in [README.md](README.md#stealth-model--limitations)
are best-effort and have known, documented limits (a remaining virtio PCI
tell, no real GPU acceleration behind the WebGL spoof, and a mitmproxy CA
that is itself detectable, among others); nothing here is guaranteed to be
undetectable, and the project makes no claims of completeness or fitness for
any particular evasion or analysis purpose.

## Reporting a security issue

This is a personal research tool, not a hosted service, so there is no
formal disclosure program. If you find a bug in the harness itself (for
example, something that breaks guest isolation from the host in a way not
already documented as a known limitation), please open an issue in this
repository describing it.
