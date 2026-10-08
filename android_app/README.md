# دفتر القطع — standalone offline Android app

Version 1.0.1 (build 2). Arabic RTL Flutter app for one spare-parts trader.

Daily use needs only the installed APK. Products, suppliers, purchases, photos,
search, prices, history, CSV import/export and complete ZIP backup/restore run
on the phone. There is no account, server, cloud sync or internet permission in
the release Android manifest. Calls and WhatsApp are optional external actions.

## Cloud build

The workflow on branch codex/android-offline-build builds entirely on a GitHub-hosted Ubuntu runner.
It runs static analysis, SQLite/widget/startup regression tests, verifies the
release signature/version/permissions, and launches the actual APK twice on an
Android 7 emulator with Wi-Fi and mobile data disabled.

After a successful run, download the Daftar-Parts-1.0.1 artifact from GitHub Actions.
Unzip it on your phone and open Daftar-Parts-1.0.1.apk to install.
The APK has a new development signature. An earlier differently signed APK must
be uninstalled first. If it contains records, export a full backup before uninstalling.

No original signing key or user database/photos are published. A fresh development
key is generated on the cloud runner. For future in-place upgrades use a securely
retained production signing key; these test builds are intended for fresh installation.

## Build from source

Flutter 3.47.6, Java 17, Android SDK/build tools 36 and NDK 28.2.13676358 are the pinned tools.
Run the following from android_app:

```sh
flutter pub get
flutter analyze
flutter test
keytool -genkeypair -keystore android/app/development.keystore -storetype JKS -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Daftar Development"
flutter build apk --release
```

The installer is build/app/outputs/flutter-apk/app-release.apk.

## Storage and recovery

SQLite schema version remains 1. Version 1.0.1 fixes Android startup by querying
the result-returning journal mode PRAGMA, preserves existing local records and
images, closes failed database handles, and provides optional copyable startup
diagnostics and retry. It never deletes the local database on a startup failure.

A full backup includes SQLite, referenced product photos and checksum metadata.
Restore validates the archive/database before replacing current data and
preserves a rollback copy if restoration fails. CSV import validates records and
references before committing. Prices are integer minor units.

Examples are optional and added only to an empty notebook. They contain the
three prototype products/suppliers with unknown purchase dates left blank.
No fabricated historical dates or contact details are included.

Camera/gallery and external file selection still need a real-phone check.
Automated emulator startup checks validate the delivered release APK.
