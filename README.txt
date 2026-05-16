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
  Theos, iPhoneOS SDK, ldid, appinst, libjailbreak.dylib

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
