unfaird

Local HTTP service for IPA processing.

macOS build:
  swift build
  make build

macOS run:
  swift run UnfairDaemon serve

macOS launchd install:
  make mac-install
  make mac-uninstall

iOS requirements:
  Theos, iPhoneOS SDK, ldid, libjailbreak.dylib

libjailbreak paths:
  /var/jb/usr/lib/libjailbreak.dylib
  /var/jb/basebin/libjailbreak.dylib
  /basebin/libjailbreak.dylib

Theos package:
  make package

Rootful iOS package:
  make THEOS_PACKAGE_SCHEME= package

Install on device:
  apt install ./wiki.qaq.unfaird_<version>_iphoneos-arm64.deb

Manual iOS package processing:
  DYLD_LIBRARY_PATH=/var/jb/basebin:/var/jb/usr/lib:/usr/lib \
    UnfairDaemon package --input input.ipa --output output.ipa --verbose

Manual iOS HTTP service:
  DYLD_LIBRARY_PATH=/var/jb/basebin:/var/jb/usr/lib:/usr/lib \
    UnfairDaemon serve --hostname 127.0.0.1 --port 6347

The iOS process decrypts in-process on rootless and roothide environments.
Encrypted binaries are staged at the canonical app container root. Every device
uses the same mapping lifecycle: map the vnode read-only, promote its VM entry
to executable with kernel primitives, call mremap_encrypted, restore the exact
read-only VM flags, and copy the decrypted bytes.
XNU 8020 also scopes its legacy kernel credential across signature registration
and mremap_encrypted, then restores the original credential before the copy.

launchd service:
  launchctl print system/wiki.qaq.unfaird
  launchctl kickstart -k system/wiki.qaq.unfaird
  launchctl bootout system/wiki.qaq.unfaird

Health:
  curl http://127.0.0.1:6347/health

Decrypt:
  curl -sS -F "ipa=@/path/to/app.ipa" http://127.0.0.1:6347/api/v1/decrypt

Download:
  curl -L -o output.ipa http://127.0.0.1:6347/api/v1/decrypt/<job-id>/output

CLI help:
  swift run UnfairDaemon --help

Use this project only with IPAs you own or have permission to analyze.
