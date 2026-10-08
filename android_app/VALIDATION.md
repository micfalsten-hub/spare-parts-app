# Validation of the delivered APK

Version 1.0.1 (2), package com.daftar.spare_parts.
SHA-256: 9b9fc1726ab51c4735aa832ddfad528ca2539bba11cfe54bbd26a86eab59cdb7.

All 14 automated app tests and static analysis passed in run 37807029098.
Release signature, package/version and no-INTERNET permission checks passed.
That run's legacy Android 7 emulator preparation failed before launching the app.

Run 37840741140 downloaded the same APK and verified its checksum. It passed
actual release first launch and force-stop/relaunch on Android 11, with airplane
mode on, Wi-Fi disabled and no active default network. Fresh UI snapshots
positively asserted the Arabic home screen after both launches.

The APK was then published without rebuilding. Both runs used GitHub-hosted
servers; no local toolchain was installed. Camera/gallery, file chooser and
WhatsApp require a physical-phone check. Android 7 is supported by the declared
minimum SDK but is not claimed to have passed native testing.

The workflow's Android diagnostic artifact includes XML, screenshots, logcat
and disconnected-network details. No user database or private signing key is included.
