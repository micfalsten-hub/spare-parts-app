# Cloud validation

The Android workflow runs Flutter static analysis, the complete SQLite/widget/startup regression tests, release APK signature/version checks and a no-INTERNET manifest check. It then installs the same release APK on an Android API 24 emulator with Wi-Fi and mobile data disabled. Both first launch and a force-stop/relaunch must expose the Arabic home screen; the reported database error causes failure.

The verified installer is uploaded only after all checks pass. Inspect the GitHub Actions run for the result; this document does not claim checks passed before that run completes. Android startup XML/screenshots/logcat are separate diagnostics artifacts. No user data or private signing keys are included.

Camera, gallery/file chooser and WhatsApp integrations require a physical-phone check. No physical-device compatibility claim is made.
