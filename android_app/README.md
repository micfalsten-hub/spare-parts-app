# دفتر القطع — standalone offline Android app

Version 1.0.1 (build 2). Arabic RTL Flutter app for one spare-parts trader.

[Download the signed APK](https://github.com/micfalsten-hub/spare-parts-app/releases/download/v1.0.1-cloud/Daftar-Parts-1.0.1.apk)

Daily use needs only the installed APK. Products, suppliers, purchases, photos,
search, prices, history, CSV import/export and full ZIP backup/restore run on
the phone. No account, server or internet permission is required. Calls and
WhatsApp are optional external actions.

## Install

Download the APK directly to your phone and open it. Allow installation from
the source you opened it with when Android requests it.

This APK uses a new development signature. An earlier differently signed app
must be uninstalled first. Export a full backup before uninstalling if you have
entered any records; uninstalling removes the phone's local app data.

## Verified cloud build

The APK was compiled entirely on GitHub's server. No build tools were installed
on the user's PC. All 14 SQLite, widget and Android startup regression tests
passed. Signature, package/version and absence of INTERNET permission were checked.

The exact compiled APK passed first launch and force-stop/relaunch on Android 11
with airplane mode enabled, Wi-Fi disabled and no active default network.
The Arabic home screen was positively asserted after both launches.
Android 7 is the declared minimum; native testing passed on Android 11.
Camera, gallery/file chooser and WhatsApp still need a physical-phone check.

- [App tests and compilation](https://github.com/micfalsten-hub/spare-parts-app/actions/runs/37807029098)
- [Successful offline Android verification and publishing](https://github.com/micfalsten-hub/spare-parts-app/actions/runs/37840741140)
- [Exact app source](https://github.com/micfalsten-hub/spare-parts-app/tree/v1.0.1-cloud/android_app)

The first run's legacy emulator preparation failed after compilation; the
separate verification run checked and published the same APK without rebuilding.
The released APK SHA-256 is:
`9b9fc1726ab51c4735aa832ddfad528ca2539bba11cfe54bbd26a86eab59cdb7`.

No original signing key or user database/photos were published. A fresh
development key was generated on the cloud runner. Future in-place updates
require retaining the same signing key securely; otherwise export a backup
and restore after a fresh installation. Installed APKs have no dependency
on GitHub or on the continued availability of the download.

## Build from source

Flutter 3.47.6, Java 17, Android SDK/build tools 36 and NDK 28.2.13676358.
Run from android_app:

```sh
flutter pub get
flutter analyze
flutter test
keytool -genkeypair -keystore android/app/development.keystore -storetype JKS -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Daftar Development"
flutter build apk --release
```

The installer is build/app/outputs/flutter-apk/app-release.apk.
The cloud workflow files show the pinned SDK and signing setup.
Build dependencies are downloaded during compilation; they are bundled into
the installed app or supplied by Android for offline daily use.

## Local storage

SQLite schema version remains 1. Version 1.0.1 fixes Android startup by querying
the result-returning journal mode PRAGMA. It preserves existing records/images,
closes failed database handles and offers copyable error details and retry.
It never deletes the database on startup failure.

Full backups include SQLite, referenced photos and checksum metadata. Restore
validates the archive/database before replacing current data, with rollback
on failure. CSV import validates records/references before committing.
Prices are stored as integer minor units.

Examples are optional and added only to an empty notebook. Their unknown
purchase dates remain blank; no historical dates or contact details are invented.
