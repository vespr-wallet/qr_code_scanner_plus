## 2.2.0

- Migrated to built-in Kotlin (AGP 9.0 compatibility). Removed `apply plugin: 'kotlin-android'` and the Kotlin Gradle Plugin classpath from `android/build.gradle`; same change in the example app's `example/android/app/build.gradle`. The `kotlin.compilerOptions { jvmTarget = JVM_17 }` block is now used in place of the legacy `kotlinOptions` block.
- Bumped minimum Dart SDK to 3.12.0 and minimum Flutter version to 3.44.0, as required by the new built-in Kotlin DSL.
- Example app: enabled `android.builtInKotlin=true` and `android.newDsl=true` in `example/android/gradle.properties`.

## 2.1.2

- [iOS] Fix iOS crash when popping QR scanner page during resume (#21)

## 2.1.1

- [iOS] Fixed CocoaPods build broken in 2.1.0 (duplicate class definition when ObjC bridge and Swift @objc coexisted)

## 2.1.0

- Retracted (broken CocoaPods build)

Breaking changes:

- Minimum Flutter version is now 3.24.0 (Dart 3.5.0)
- [iOS] Minimum deployment target raised to iOS 12.0

#### Features

- [iOS] Added Swift Package Manager support (dual CocoaPods + SPM)
- [iOS] Replaced MTBBarcodeScanner dependency with native AVFoundation scanner — the plugin now has zero third-party iOS dependencies

## 2.0.14

- Updated android compile and target SDK to 36
- Updated android targets to java 17
- Fixed android build for example app

## 2.0.13

Fix:

- Correctly parse all iOS versions to reliably apply the UI Hanging fix from version 2.0.12

## 2.0.12

- For iOS 18 or newer, call `pauseCamera` on dispose instead of `stopCamera` to avoid UI hang

**L.e. The iOS version detection was not correctly parsed, causing this fix to not apply for hotfix iOS versions (such as 26.0.1)**

## 2.0.11

FIX for iOS 26:

- For iOS 26 or newer, call `pauseCamera` on dispose instead of `stopCamera`

Note: Calling stopCamera on dispose was causing UI to hang for 1-3 seconds

## 2.0.10+1

- Increased android compile SDK to 35 and removed android test deps

## 2.0.10

- Improved back camera selection for WEB on mobile
- Fixed default overlay for `QrScannerOverlayShape` which was full black instead of translucent

## 2.0.9+1

- Fix a bad import causing mobile builds to fail

## 2.0.9

- Updated QrViewController to self-dispose when the QrView is disposed
- Fixed WEB support for WASM

Note: The public `dispose()` function for `QRViewController` is now a no-op function and deprecated. You should stop calling it. It will be removed fully in the future.

## 2.0.8+1

- Updated package list of supported platforms to include web

## 2.0.8

- [WEB] Fixed support for WEB platform (thanks [@mikeesouth](https://github.com/mikeesouth))

## 2.0.7

- [Android] Updated Android AGP to version 8.9 (thanks [@SOMBORO](https://github.com/SOMBORO))
- [Android] Removed Core Library Desugaring (thanks [@SOMBORO](https://github.com/SOMBORO))

## 2.0.6

- Fixed additional js_interop issues causing failure to build on web

## 2.0.5

- Fixed additional js_interop issues causing failure to build on web

## 2.0.4

- Fixed js_interop usage causing failure to build on web

## 2.0.3

- Updated flutter to ">=3.3.0"
- Updated dart to ">=3.0.0"
- Migrated from js and html to js_interop and web package

## 2.0.0, 2.0.1 and 2.0.2

- Retracted

## 1.0.0

Breaking changes:
Minimum Flutter version is now Flutter 3.0.0 (Dart 2.17.0).

#### Features

- Inverted is now mixed with normal scanning.
- onPermissionSet now works on web aswell.
- [Android] zxing core is updated to 3.5.0.
- [Android] Several code improvements.
- [Android] Several dependencies updated.

## 0.7.0

#### Features

- Add inverted feature for Android. See https://github.com/juliuscanute/qr_code_scanner/issues/403

#### Bugfixes

- Fixed permission error on devices running Android 7 or lower.
- Fixed error being thrown when user declines permission on iOS.
- Updated dependencies

## 0.6.1

- Fix bug which caused build to fail for iOS. (#452)

## 0.6.0

#### Features

- Add support for raw bytes on iOS. (#421)
- Add custom cutout width and height next to cutout size. (#432)

#### Bugfixes

- Fix for calling permission multiple times. (#381)
- Fix for QRView Overlay cutoutbottomoffset. (#383)
- Multiple minor improvements

## 0.5.2

#### Bugfixes

- Increased delay to fix QRView opening zoomed in on some devices by adding small delay to updateDimensions(). (#250)
- Updated ZXING from 3.3.0 to 3.4.1 (#369)
- Fixed permission not being called correctly on Android (#351)

## 0.5.1

Removed web from library export.

## 0.5.0

- Added initial web-support. This function is still under development and not fully tested.
- Fixed permissions on iOS.
- Updated dependencies.

## 0.4.0

Stable null-safety support. (#278)

## 0.3.5

#### Bug fixes

- Fixed QRView opening zoomed in on some devices by adding small delay to updateDimensions(). (#250)
- Changed upc-A to EAN13 on iOS. (#262)
- Fixed null-pointer on BarcodeFormat array on iOS. (#262)
- Added LifecycleEventHandler to dispose(). (#265)

## 0.3.4

#### Bug fixes

- Fixed No barcode view found on Android when calling controller.dispose() (#257)
- Fixed Hot reload not working on Android.

## 0.3.3

#### Bug fixes

- Fixed updateDimensions not being called causing zoom on iOS. (#250)
- Fixed Android permission callback not working. (#251) (#252)
- Fixed null-pointers after declining permission on Android.

## 0.3.2

#### Bug fixes

- Fixed null-pointer when no overlay provided on iOS. (#245)
- Fixed camera not stopping (green dot on iOS 14) when navigating to other page. (#240)

## 0.3.1

#### Bug fixes

- Fixed permission callback on iOS & Android.
- Fixed camera facing not working on Android.
- Fixed scanArea not being honored on Android.
- Updated ShapeBorder to QrScannerOverlayShape.

## 0.3.0

#### Breaking change

Its not necessary anymore to wrap the QRView in a SizeChangedLayoutNotifier because this is handled inside the plugin.

#### New Features

- Added possibility to set allowed barcodes. (#135)
- Added possibility to check what features are supported by device. (hasFlash, hasBackCamera, hasFrontCamera) (#135)
- Added possibility to check if flash is on. (#135)
- Added possibility to check which camera is active. (#135)
- All functions are now async so you can await them. (#135)

See the updated example on how to implement these features.

#### Bug fixes

- Fixed permission handling in Android.
- Native functions now returns results so exceptions can be thrown when an error occurs.

## 0.2.1

- Fixed critical bug where scanner wouldn't open when no scan overlay was configured.

## 0.2.0

#### Breaking change

- The plugin now returns Barcode object instead of QR String. This object includes the type of code, the code itself and on Android devices the raw bytes. (#63)

#### New Features

- Added possibility to provide scanArea on iOS. (#165)

#### Bug fixes

- Fixed preview going black after hot reload. (#76)
- Fixed nullpointer when plugin binding order isn't correct. (#181)
- Fixed permission being asked on startup (#185)

## 0.1.0

- Changed Android minSDKversion from 24 to 21 (#170)
- Fix preview size after iPad rotation (#125)
- Implemented Android Embedding V2 (#132)
- Added cutout bottom offset (#115)
- Fix Android ActivityLifecycleCallbacks (#166)
- Fix some other small bugs

## 0.0.14

- Fix disposing camera on iOS 14 (#113)

## 0.0.13

- Fix misalignment when QRView doesn't start from the top left (#45)
- Fix crash on iOS when scanning returns nil (#69, #72)
- Fix ArithmeticException on Android (#43)

## 0.0.12

- Add optional parameter to use a camera overlay.
- Simplify controller, expose scanDataStream.
- Fix for Android flash toggle.
- Add ability to pause/resume the camera.
- Thanks! to Luis Thein for all the above contributions.

## 0.0.11

- android build break fix

## 0.0.10

- update README.md

## 0.0.9

- update README.md

## 0.0.8

- migrated Android project to androidx (by Felipe César)
- migrated iOS to Swift 5 (by Felipe César)

## 0.0.7

- flash light support added

## 0.0.6

- camera flip added

## 0.0.5

- preview stretching after change screen orientation fix

## 0.0.4

- fix black screen orientation/unlock/focus

## 0.0.3

- iOS library reference fix
- Android pause/resume fix

## 0.0.2

- Added documentation to cover how to use the plugin.

## 0.0.1

- QR Code scanner embedded inside flutter.
