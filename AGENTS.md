# AGENTS.md

## Project

`unfaird` is a SwiftPM 5.9 Vapor daemon. It accepts IPA decrypt requests over HTTP and runs UnfairKit directly in the daemon process.

## Build

```bash
swift build
make build
```

Run locally:

```bash
swift build
swift run UnfairDaemon serve
```

UnfairKit is vendored at `Vendor/unfair` and consumed as a local path dependency.
Do not edit it in place; land the change upstream and re-sync:

```bash
make vendor-unfair                              # re-sync the pinned revision
make vendor-unfair UNFAIR_REVISION=<commit>     # move the pin
```

iOS Theos package:

```bash
make package
make THEOS_PACKAGE_SCHEME= package
make package-all                                # rootless + roothide in one run
```

## API

Decrypt an IPA:

```bash
curl -sS -F "ipa=@/path/to/app.ipa" \
  http://127.0.0.1:6347/api/v1/decrypt
```

Decrypt jobs always run with verbose UnfairKit logs enabled.

The response includes `exit.code`, `exit.stdout`, `exit.stderr`, `exit.download_url`, and `exit.validate_until`.

Download a successful output:

```bash
curl -L -o output.ipa http://127.0.0.1:6347/api/v1/decrypt/<job-id>/output
```

## Decrypt Runtime Invariants

These are fixed runtime contracts.

- The UnfairKit extraction directory must be `$TMPDIR/../X/unfair/{UDID}`.
- Resolve `$TMPDIR` dynamically at process runtime. Launchd can change it across daemon starts.
- Do not override, rewrite, or sandbox-remap `TMPDIR` for decrypt/package runs.
- Serialize package processing because UnfairKit changes the process working directory while decrypting staged binaries.
- Use one encrypted mapping lifecycle on every supported kernel: `mmap(PROT_READ, MAP_PRIVATE)`, `mremap_encrypted(..., CRYPTID_MODEL_ENCRYPTION)`, copy the plaintext, then `munmap`.
- Run the iOS daemon as root and prepare jailbreak primitives plus the platform code-signing flag before staging and decrypting app binaries.
- Preserve mtime and chmod from the IPA entries during extraction and when replacing entries in the output IPA.
- Keep temporary `.sinf` copies metadata-preserving.

## Deploy

Use the scripts in `deploy/` for macOS install and service management.

Use Theos package output from `debs/` for iOS apt install. The launchd label is `wiki.qaq.unfaird`.

The iOS runtime requires jailbreak-provided `libjailbreak.dylib`. Rootless and roothide share one runtime path: resolve the jailbreak library through `UNFAIRD_JB_PREFIX`, dyld, or `/var/jb`, stage encrypted binaries under `/var/containers/Bundle/Application`, and use the same read-only model-encryption mapping lifecycle.

Packaging is prefix-agnostic. Theos resolves `rootless` to a `/var/jb` install prefix and `roothide` to an empty prefix with `iphoneos-arm64e` arch, and a roothide jbroot is randomized per device. So the staged launchd plist keeps its `@INSTALL_PREFIX@`, `@DYLD_LIBRARY_PATH@` and `@LAUNCHD_PATH@` placeholders, and `layout/DEBIAN/postinst` derives the prefix from its own `<prefix>/var/lib/dpkg/info/...` path and renders them on device. Never re-introduce build-time prefix substitution in the Makefile: it cannot express a roothide jbroot.

Keep tracked docs and agent notes free of private deployment details:

- Do not write real hostnames, LAN IPs, user accounts, passwords, machine names, live process IDs, or live service status into docs.
- Prefer placeholders such as `user@host`, `/path/to/app.ipa`, and `<job-id>` in examples.
- Keep README concise and operational. Avoid promotional language and public-facing deployment detail.
