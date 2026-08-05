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

UnfairKit dependency:
  Vendored in Vendor/unfair. Re-sync with scripts/vendor-unfair.sh or
  make vendor-unfair UNFAIR_REVISION=<commit>.

iOS requirements:
  Theos, iPhoneOS SDK, ldid, libjailbreak.dylib
  roothide packages need RootHide's Theos fork for its roothide scheme.

libjailbreak paths:
  $UNFAIRD_JB_PREFIX/basebin/libjailbreak.dylib
  $UNFAIRD_JB_PREFIX/usr/lib/libjailbreak.dylib
  /var/jb/usr/lib/libjailbreak.dylib
  /var/jb/basebin/libjailbreak.dylib
  /basebin/libjailbreak.dylib

Theos package:
  make package

Rootless and roothide packages in one run:
  make package-all
  bash scripts/package.sh rootless roothide

Rootful iOS package:
  make THEOS_PACKAGE_SCHEME= package

Install on device:
  apt install ./wiki.qaq.unfaird_<version>_iphoneos-arm64_rootless.deb
  apt install ./wiki.qaq.unfaird_<version>_iphoneos-arm64e_roothide.deb

The package installs one prefix-agnostic layout. postinst derives the install
prefix from its own dpkg path, so it resolves "" rootful, /var/jb rootless, and
the randomized jbroot on roothide, then renders the launchd plist and exports
UNFAIRD_JB_PREFIX to the daemon.

Manual iOS package processing:
  DYLD_LIBRARY_PATH=/var/jb/basebin:/var/jb/usr/lib:/usr/lib \
    UnfairDaemon package --input input.ipa --output output.ipa --verbose

Manual iOS HTTP service:
  DYLD_LIBRARY_PATH=/var/jb/basebin:/var/jb/usr/lib:/usr/lib \
    UnfairDaemon serve --hostname 127.0.0.1 --port 6347

The iOS process decrypts in-process on rootless and roothide environments.
Encrypted binaries are staged at the canonical app container root. Every device
uses the same mapping lifecycle across SPTM, PPL, and earlier XNU kernels: map
the vnode with PROT_READ, call mremap_encrypted with
CRYPTID_MODEL_ENCRYPTION, copy the decrypted bytes, and unmap the region.

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
