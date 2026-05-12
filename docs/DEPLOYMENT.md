# Deployment and Distribution

## No-Cost Customer Delivery

You can distribute:

- Android APK files directly to customers.
- SUNMI APK files directly to SUNMI devices.
- Windows ZIP packages or installers directly to customers.

This avoids paid app stores and paid hosting for the client app.

## Backend Requirement

Activation, licensing verification, sync, backups, and reporting still need a backend when customers are online. For no-cost testing, run the backend on your own PC or local network. For production customers, you eventually need a reliable machine/server or cloud host.

## Scripts

- `scripts\build-android-apk.ps1`
- `scripts\build-windows-package.ps1`
- `scripts\run-backend-prod.ps1`

## Current Machine Status

Flutter, Android SDK, Android licenses, Android Studio JDK, and Visual Studio Build Tools are installed and recognized by `flutter doctor`.

Android release APK builds successfully at:

`apps\pos_flutter\build\app\outputs\flutter-apk\app-release.apk`

Windows builds with plugins require Windows Developer Mode because Flutter creates plugin symlinks. If the build says "Building with plugins requires symlink support", open Windows Settings > System > For developers and turn on Developer Mode, then rerun:

`scripts\build-windows-package.ps1`
