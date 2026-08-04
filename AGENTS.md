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

iOS Theos package:

```bash
make package
make THEOS_PACKAGE_SCHEME= package
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
- Keep A15+ encrypted mapping promotion thread-scoped to the serialized package operation.
- Run the iOS daemon as root, retain its original process credential, clear only its private sandbox slot, and leave `kern_ucred` untouched.
- Preserve mtime and chmod from the IPA entries during extraction and when replacing entries in the output IPA.
- Keep temporary `.sinf` copies metadata-preserving.

## Deploy

Use the scripts in `deploy/` for macOS install and service management.

Use Theos package output from `debs/` for iOS apt install. The launchd label is `wiki.qaq.unfaird`.

The iOS runtime requires jailbreak-provided `libjailbreak.dylib`. The daemon loads its kernel primitives and current-device offsets, stages encrypted binaries under `/var/containers/Bundle/Application`, and promotes the encrypted file mapping before `mremap_encrypted`.

Keep tracked docs and agent notes free of private deployment details:

- Do not write real hostnames, LAN IPs, user accounts, passwords, machine names, live process IDs, or live service status into docs.
- Prefer placeholders such as `user@host`, `/path/to/app.ipa`, and `<job-id>` in examples.
- Keep README concise and operational. Avoid promotional language and public-facing deployment detail.
