import 'dart:async';
import 'dart:developer';
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'lifecycle_event_handler.dart';
import 'qr_scanner_overlay_shape.dart';
import 'types/barcode.dart';
import 'types/barcode_format.dart';
import 'types/camera.dart';
import 'types/camera_exception.dart';
import 'types/features.dart';
import 'web/flutter_qr_stub.dart'
    if (dart.library.js) "web/flutter_qr_web.dart"
    if (dart.library.js_interop) "web/flutter_qr_web.dart"
    if (dart.library.html) "web/flutter_qr_web.dart";

import 'platform/platform_info_stub.dart'
    if (dart.library.io) "platform/platform_info_vm.dart"
    if (dart.library.js) "platform/platform_info_web.dart"
    if (dart.library.js_interop) "platform/platform_info_web.dart"
    if (dart.library.html) "platform/platform_info_web.dart";

typedef QRViewCreatedCallback = void Function(QRViewController);
typedef PermissionSetCallback = void Function(QRViewController, bool);

const _defaultIOSMajorVersionOnUnknown = 18;

/// The [QRView] is the view where the camera
/// and the barcode scanner gets displayed.
class QRView extends StatefulWidget {
  const QRView({
    required Key key,
    required this.onQRViewCreated,
    this.overlay,
    this.overlayMargin = EdgeInsets.zero,
    this.cameraFacing = CameraFacing.back,
    this.onPermissionSet,
    this.formatsAllowed = const <BarcodeFormat>[],
    this.cameraErrorMessage = 'Could not start the camera',
    this.cameraRetryLabel = 'Retry',
  }) : super(key: key);

  /// [onQRViewCreated] gets called when the view is created
  final QRViewCreatedCallback onQRViewCreated;

  /// Use [overlay] to provide an overlay for the view.
  /// This can be used to create a certain scan area.
  final QrScannerOverlayShape? overlay;

  /// Use [overlayMargin] to provide a margin to [overlay]
  final EdgeInsetsGeometry overlayMargin;

  /// Set which camera to use on startup.
  ///
  /// [cameraFacing] can either be CameraFacing.front or CameraFacing.back.
  /// Defaults to CameraFacing.back
  final CameraFacing cameraFacing;

  /// Calls the provided [onPermissionSet] callback when the permission is set.
  final PermissionSetCallback? onPermissionSet;

  /// Use [formatsAllowed] to specify which formats needs to be scanned.
  final List<BarcodeFormat> formatsAllowed;

  /// Shown inside the scan area when the camera fails to start, above a
  /// button labelled [cameraRetryLabel] that starts it again.
  ///
  /// Pass localized text here; the default is English.
  final String cameraErrorMessage;

  /// Label of the button that restarts the camera after it failed to start.
  ///
  /// Pass localized text here; the default is English.
  final String cameraRetryLabel;

  @override
  State<StatefulWidget> createState() => _QRViewState();
}

class _QRViewState extends State<QRView> {
  MethodChannel? _channel;
  QRViewController? controller;
  late LifecycleEventHandler _observer;

  /// Set when the camera failed to start; cleared by a retry or a later start.
  CameraException? _cameraError;

  @override
  void initState() {
    super.initState();
    _observer = LifecycleEventHandler(resumeCallBack: updateDimensions);
    WidgetsBinding.instance.addObserver(_observer);
  }

  @override
  Widget build(BuildContext context) {
    final cameraError = _cameraError;
    final overlay = widget.overlay;
    return NotificationListener(
      onNotification: onNotification,
      child: SizeChangedLayoutNotifier(
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            _getPlatformQrView(),
            if (cameraError != null)
              // Opaque, so nothing the app draws under the scanner (such as a
              // loading indicator) shows through: without a camera frame the
              // platform view is transparent.
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFF000000),
                  child: _CameraErrorView(
                    overlay: overlay,
                    overlayMargin: widget.overlayMargin,
                    message: widget.cameraErrorMessage,
                    retryLabel: widget.cameraRetryLabel,
                    onRetry: _retryCamera,
                  ),
                ),
              ),
            // The overlay stays on top so its border frames the error too, but
            // it must not take the Retry button's taps.
            if (overlay != null)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: cameraError != null,
                  child: Padding(
                    padding: widget.overlayMargin,
                    child: Container(
                      decoration: ShapeDecoration(shape: overlay),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
    WidgetsBinding.instance.removeObserver(_observer);
    controller?._disposeImpl();
  }

  /// iOS reads the view's size through its [GlobalKey].
  GlobalKey? get _globalKey => switch (widget.key) {
    final GlobalKey key => key,
    _ => null,
  };

  Future<void> updateDimensions() async {
    final channel = _channel;
    if (channel == null) return;
    await QRViewController.updateDimensions(
      _globalKey,
      channel,
      overlay: widget.overlay,
    );
  }

  bool onNotification(Notification notification) {
    updateDimensions();
    return false;
  }

  Widget _getPlatformQrView() {
    if (kIsWeb) {
      return createWebQrView(
        onPlatformViewCreated: widget.onQRViewCreated,
        onPermissionSet: widget.onPermissionSet,
        cameraFacing: widget.cameraFacing,
      );
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          return AndroidView(
            viewType: 'net.touchcapture.qr.flutterqrplus/qrview',
            onPlatformViewCreated: _onPlatformViewCreated,
            creationParams: _QrCameraSettings(
              cameraFacing: widget.cameraFacing,
            ).toMap(),
            creationParamsCodec: const StandardMessageCodec(),
          );
        case TargetPlatform.iOS:
          return UiKitView(
            viewType: 'net.touchcapture.qr.flutterqrplus/qrview',
            onPlatformViewCreated: _onPlatformViewCreated,
            creationParams: _QrCameraSettings(
              cameraFacing: widget.cameraFacing,
            ).toMap(),
            creationParamsCodec: const StandardMessageCodec(),
          );
        default:
          throw UnsupportedError(
            "Trying to use the default qrview implementation for $defaultTargetPlatform but there isn't a default one",
          );
      }
    }
  }

  void _onPlatformViewCreated(int id) {
    if (!mounted) {
      return;
    }

    final channel = MethodChannel(
      'net.touchcapture.qr.flutterqrplus/qrview_$id',
    );
    _channel = channel;

    final newController = QRViewController._(
      channel,
      widget.onPermissionSet,
      widget.cameraFacing,
    );
    newController._onCameraError = (error) {
      _showCameraError(newController, error);
    };
    newController._onCameraStarted = () => _clearCameraError(newController);

    // Dispose the previous controller if it exists
    controller?._disposeImpl();
    controller = newController;
    if (_cameraError != null) setState(() => _cameraError = null);

    // Start scan after creation of the view
    unawaited(_startCamera(newController));

    // Initialize the controller for controlling the QRView
    widget.onQRViewCreated(newController);
  }

  /// Starts the camera and shows the error state when it fails, instead of
  /// leaving an unhandled [CameraException] and a blank preview.
  Future<void> _startCamera(QRViewController controller) async {
    try {
      await controller._startScan(
        _globalKey,
        widget.overlay,
        widget.formatsAllowed,
      );
    } on CameraException catch (error) {
      _showCameraError(controller, error);
    }
  }

  void _showCameraError(QRViewController controller, CameraException error) {
    if (!mounted || controller != this.controller || controller.disposed) {
      return;
    }
    log(
      'Camera failed to start: $error',
      name: 'qr_code_scanner_plus',
      level: 900, // warning
    );
    setState(() => _cameraError = error);
  }

  void _clearCameraError(QRViewController controller) {
    if (!mounted || controller != this.controller || _cameraError == null) {
      return;
    }
    setState(() => _cameraError = null);
  }

  void _retryCamera() {
    final controller = this.controller;
    if (controller == null || controller.disposed) return;
    setState(() => _cameraError = null);
    unawaited(_startCamera(controller));
  }
}

/// The failed-camera message and its Retry button, centred in the overlay's
/// cut-out (or in the whole view when there is no overlay).
class _CameraErrorView extends StatelessWidget {
  const _CameraErrorView({
    required this.overlay,
    required this.overlayMargin,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final QrScannerOverlayShape? overlay;
  final EdgeInsetsGeometry overlayMargin;
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  static const _textColor = Color(0xFFFFFFFF);
  static const _maxWidthWithoutOverlay = 320.0;

  @override
  Widget build(BuildContext context) {
    final overlay = this.overlay;
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _textColor, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Semantics(
            button: true,
            child: GestureDetector(
              onTap: onRetry,
              behavior: HitTestBehavior.opaque,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44, minWidth: 88),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: _textColor),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  retryLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _textColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Wrap the text at the available width and scale it down only when it
    // still does not fit the height (a small cut-out or long translations).
    Widget fitted(double width) => Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(width: width, child: content),
      ),
    );

    if (overlay == null) {
      return LayoutBuilder(
        builder: (context, constraints) =>
            fitted(min(constraints.maxWidth, _maxWidthWithoutOverlay)),
      );
    }

    return Padding(
      padding: overlayMargin,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Same cut-out geometry as QrScannerOverlayShape.paint.
          final width = min(overlay.cutOutWidth, constraints.maxWidth);
          final height = min(overlay.cutOutHeight, constraints.maxHeight);
          return Stack(
            children: [
              Positioned(
                left: (constraints.maxWidth - width) / 2,
                top:
                    (constraints.maxHeight - height) / 2 -
                    overlay.cutOutBottomOffset,
                width: width,
                height: height,
                child: fitted(width),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QrCameraSettings {
  _QrCameraSettings({this.cameraFacing = CameraFacing.unknown});

  final CameraFacing cameraFacing;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{'cameraFacing': cameraFacing.index};
  }
}

class QRViewController {
  QRViewController._(
    MethodChannel channel,
    PermissionSetCallback? onPermissionSet,
    CameraFacing cameraFacing,
  ) : _channel = channel,
      _cameraFacing = cameraFacing {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRecognizeQR':
          final args = call.arguments;
          if (args is Map) {
            final rawType = args['type'];
            final format = rawType is String
                ? BarcodeTypesExtension.fromString(rawType)
                : BarcodeFormat.unknown;
            if (format == BarcodeFormat.unknown) {
              throw Exception('Unexpected barcode type $rawType');
            }
            final code = args['code'];
            // Raw bytes are only supported by Android.
            final rawBytes = args['rawBytes'];
            _scanUpdateController.sink.add(
              Barcode(
                code is String ? code : null,
                format,
                rawBytes is List<int> ? rawBytes : null,
              ),
            );
          }
          break;
        case 'onCameraError':
          final message = call.arguments;
          _onCameraError?.call(
            CameraException('cameraError', message is String ? message : null),
          );
          break;
        case 'onCameraStarted':
          _onCameraStarted?.call();
          break;
        case 'onPermissionSet':
          if (call.arguments != null && call.arguments is bool) {
            _hasPermissions = call.arguments;
            if (onPermissionSet != null) {
              onPermissionSet(this, _hasPermissions);
            }
          }
          break;
      }
    });
  }
  bool disposed = false;
  final MethodChannel _channel;

  /// Set by the [QRView] that owns this controller.
  void Function(CameraException error)? _onCameraError;
  void Function()? _onCameraStarted;
  final CameraFacing _cameraFacing;
  final StreamController<Barcode> _scanUpdateController =
      StreamController<Barcode>();

  Stream<Barcode> get scannedDataStream => _scanUpdateController.stream;

  bool _hasPermissions = false;
  bool get hasPermissions => _hasPermissions;

  /// Starts the barcode scanner
  Future<void> _startScan(
    GlobalKey? key,
    QrScannerOverlayShape? overlay,
    List<BarcodeFormat>? barcodeFormats,
  ) async {
    // We need to update the dimension before the scan is started.
    try {
      await QRViewController.updateDimensions(key, _channel, overlay: overlay);
      return await _channel.invokeMethod(
        'startScan',
        barcodeFormats?.map((e) => e.asInt()).toList() ?? [],
      );
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Gets information about which camera is active.
  Future<CameraFacing> getCameraInfo() async {
    try {
      var cameraFacing = await _channel.invokeMethod('getCameraInfo') as int;
      if (cameraFacing == -1) return _cameraFacing;
      return CameraFacing.values[await _channel.invokeMethod('getCameraInfo')
          as int];
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Flips the camera between available modes
  Future<CameraFacing> flipCamera() async {
    try {
      return CameraFacing.values[await _channel.invokeMethod('flipCamera')
          as int];
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Get flashlight status
  Future<bool?> getFlashStatus() async {
    try {
      return await _channel.invokeMethod('getFlashInfo');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Toggles the flashlight between available modes
  Future<void> toggleFlash() async {
    try {
      await _channel.invokeMethod('toggleFlash') as bool?;
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Pauses the camera and barcode scanning
  Future<void> pauseCamera() async {
    try {
      await _channel.invokeMethod('pauseCamera');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Stops barcode scanning and the camera
  Future<void> stopCamera() async {
    if (isIos) {
      try {
        final osVersionSplit = osVersion.split(' ');

        // iOS version is sth like 26.0 or 26.0.1, etc.
        // We cannot assume it would parse as a double, so we need to handle that.
        final iOSVersion = osVersionSplit.length > 1
            ? osVersionSplit[1]
            : "$_defaultIOSMajorVersionOnUnknown.0";

        final iOSMajorVersion =
            int.tryParse(
              iOSVersion.split('.').firstOrNull ??
                  '$_defaultIOSMajorVersionOnUnknown',
            ) ??
            _defaultIOSMajorVersionOnUnknown;
        final isAtLeastIOS18 = iOSMajorVersion >= 18;

        if (isAtLeastIOS18) {
          // Don't call stopCamera on iOS 18+
          // -- it causes UI to hang for a few seconds, especially on iOS 26+
          await _channel.invokeMethod('pauseCamera');
        } else {
          await _channel.invokeMethod('stopCamera');
        }
      } on PlatformException catch (e) {
        throw CameraException(e.code, e.message);
      }
    } else {
      // no-op on other platforms
    }
  }

  /// Resumes barcode scanning
  Future<void> resumeCamera() async {
    try {
      await _channel.invokeMethod('resumeCamera');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  /// Returns which features are available on device.
  Future<SystemFeatures> getSystemFeatures() async {
    try {
      var features = await _channel.invokeMapMethod<String, dynamic>(
        'getSystemFeatures',
      );
      if (features != null) {
        return SystemFeatures.fromJson(features);
      }
      throw CameraException('Error', 'Could not get system features');
    } on PlatformException catch (e) {
      throw CameraException(e.code, e.message);
    }
  }

  @Deprecated(
    "Disposing the QRViewController is no longer necessary. The controller will self-dispose when the QRView is un-mounted.",
  )
  void dispose() {
    // NO-OP | Function kept for backward compatibility
    // QRViewController will self-dispose when the QRView is disposed
    log(
      "It is not required to call dispose() on QRViewController anymore. It will be auto disposed.",
      name: "qr_code_scanner_plus",
      level: 900, // warning
    );
  }

  /// Stops the camera and disposes the barcode stream.
  void _disposeImpl() {
    if (disposed) {
      log(
        "QRViewController was disposed more than once",
        name: "qr_code_scanner_plus",
        level: 900, // warning
      );
      return;
    }
    disposed = true;
    _onCameraError = null;
    _onCameraStarted = null;
    // Nobody awaits this, so a failure (no scanner, or the native view is
    // already gone) must not surface as an unhandled error.
    unawaited(
      stopCamera().catchError(
        (Object error) => log(
          'Could not stop the camera on dispose: $error',
          name: 'qr_code_scanner_plus',
          level: 900, // warning
        ),
      ),
    );
    _scanUpdateController.close();
  }

  /// Updates the view dimensions for iOS.
  static Future<bool> updateDimensions(
    GlobalKey? key,
    MethodChannel channel, {
    QrScannerOverlayShape? overlay,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Add small delay to ensure the render box is loaded
      await Future.delayed(const Duration(milliseconds: 300));
      final renderBox = key?.currentContext?.findRenderObject();
      if (renderBox is! RenderBox) return false;
      try {
        await channel.invokeMethod('setDimensions', {
          'width': renderBox.size.width,
          'height': renderBox.size.height,
          'scanAreaWidth': overlay?.cutOutWidth ?? 0,
          'scanAreaHeight': overlay?.cutOutHeight ?? 0,
          'scanAreaOffset': overlay?.cutOutBottomOffset ?? 0,
        });
        return true;
      } on PlatformException catch (e) {
        throw CameraException(e.code, e.message);
      }
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      if (overlay == null) {
        return false;
      }
      await channel.invokeMethod('changeScanArea', {
        'scanAreaWidth': overlay.cutOutWidth,
        'scanAreaHeight': overlay.cutOutHeight,
        'cutOutBottomOffset': overlay.cutOutBottomOffset,
      });
      return true;
    }
    return false;
  }

  //Starts/Stops invert scanning.
  Future<void> scanInvert(bool isScanInvert) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod('invertScan', {
          "isInvertScan": isScanInvert,
        });
      } on PlatformException catch (e) {
        throw CameraException(e.code, e.message);
      }
    }
  }
}
