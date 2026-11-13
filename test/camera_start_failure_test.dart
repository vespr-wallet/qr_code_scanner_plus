import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

/// Fakes the iOS platform view and the per-view scanner channel.
class _FakeScanner {
  _FakeScanner(this.tester);

  final WidgetTester tester;
  final List<String> calls = [];
  late String channelName;

  /// Whether the next `startScan` calls fail, in order; later calls succeed.
  final List<bool> failures = [];

  TestDefaultBinaryMessenger get _messenger =>
      tester.binding.defaultBinaryMessenger;

  void install() {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map<Object?, Object?>;
        channelName = 'net.touchcapture.qr.flutterqrplus/qrview_${args['id']}';
        _messenger.setMockMethodCallHandler(
          MethodChannel(channelName),
          _handleScannerCall,
        );
      }
      return null;
    });
  }

  Future<Object?> _handleScannerCall(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'startScan':
        final fail = failures.isNotEmpty && failures.removeAt(0);
        if (fail) {
          throw PlatformException(
            code: 'unknown-error',
            message: 'Unable to start scanning',
            details: 'No camera available for position 0',
          );
        }
        return null;
      case 'setDimensions':
        return 0.0;
      default:
        return true;
    }
  }

  /// Delivers a call from the native side, like `onCameraError` on Android.
  Future<void> sendFromNative(String method, [Object? arguments]) =>
      _messenger.handlePlatformMessage(
        channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );

  int get startScanCount => calls.where((c) => c == 'startScan').length;
}

Widget _app(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(data: const MediaQueryData(), child: child),
);

/// Lets the iOS dimension update (a 300 ms delay) and the start finish.
Future<void> _settleStart(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  testWidgets('a failed start shows the error and Retry restarts the camera', (
    tester,
  ) async {
    final scanner = _FakeScanner(tester)..install();
    scanner.failures.add(true);
    QRViewController? created;

    await tester.pumpWidget(
      _app(
        QRView(
          key: GlobalKey(),
          onQRViewCreated: (controller) => created = controller,
        ),
      ),
    );
    await _settleStart(tester);

    expect(tester.takeException(), isNull);
    expect(created, isNotNull);
    expect(scanner.startScanCount, 1);
    expect(find.text('Could not start the camera'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Could not start the camera'), findsNothing);
    await _settleStart(tester);

    expect(scanner.startScanCount, 2);
    expect(find.text('Could not start the camera'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  }, variant: _ios);

  testWidgets('a retry that fails again shows the error again', (tester) async {
    final scanner = _FakeScanner(tester)..install();
    scanner.failures.addAll([true, true]);

    await tester.pumpWidget(
      _app(QRView(key: GlobalKey(), onQRViewCreated: (_) {})),
    );
    await _settleStart(tester);
    await tester.tap(find.text('Retry'));
    await _settleStart(tester);

    expect(scanner.startScanCount, 2);
    expect(find.text('Could not start the camera'), findsOneWidget);
  }, variant: _ios);

  testWidgets(
    'uses the provided texts, centred in the overlay cut-out, and the overlay lets Retry through',
    (tester) async {
      final scanner = _FakeScanner(tester)..install();
      scanner.failures.add(true);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _app(
          QRView(
            key: GlobalKey(),
            onQRViewCreated: (_) {},
            overlay: QrScannerOverlayShape(
              cutOutSize: 300,
              cutOutBottomOffset: 100,
            ),
            cameraErrorMessage: 'Kamera nicht verfügbar',
            cameraRetryLabel: 'Erneut versuchen',
          ),
        ),
      );
      await _settleStart(tester);

      expect(find.text('Could not start the camera'), findsNothing);
      expect(find.text('Erneut versuchen'), findsOneWidget);
      final cutOut = Rect.fromCenter(
        center: const Offset(200, 400 - 100),
        width: 300,
        height: 300,
      );
      expect(
        cutOut.contains(tester.getCenter(find.text('Kamera nicht verfügbar'))),
        isTrue,
      );
      expect(
        cutOut.contains(tester.getCenter(find.text('Erneut versuchen'))),
        isTrue,
      );

      // The overlay is drawn above the error but must not swallow the tap.
      await tester.tap(find.text('Erneut versuchen'));
      await _settleStart(tester);
      expect(scanner.startScanCount, 2);
      expect(find.text('Kamera nicht verfügbar'), findsNothing);
    },
    variant: _ios,
  );

  testWidgets('a camera error reported later by the native side shows the '
      'error, and a camera start clears it', (tester) async {
    final scanner = _FakeScanner(tester)..install();

    await tester.pumpWidget(
      _app(QRView(key: GlobalKey(), onQRViewCreated: (_) {})),
    );
    await _settleStart(tester);
    expect(find.text('Retry'), findsNothing);

    await scanner.sendFromNative('onCameraError', 'Camera in use');
    await tester.pump();
    expect(find.text('Could not start the camera'), findsOneWidget);

    await scanner.sendFromNative('onCameraStarted');
    await tester.pump();
    expect(find.text('Could not start the camera'), findsNothing);
  }, variant: _ios);

  testWidgets('long texts fit a small cut-out without overflowing', (
    tester,
  ) async {
    final scanner = _FakeScanner(tester)..install();
    scanner.failures.add(true);

    await tester.pumpWidget(
      _app(
        QRView(
          key: GlobalKey(),
          onQRViewCreated: (_) {},
          overlay: QrScannerOverlayShape(cutOutSize: 120, borderLength: 30),
          cameraErrorMessage:
              'Die Kamera konnte nicht gestartet werden. Bitte schließe andere '
              'Apps, die die Kamera verwenden, und versuche es erneut.',
          cameraRetryLabel: 'Erneut versuchen',
        ),
      ),
    );
    await _settleStart(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Erneut versuchen'), findsOneWidget);
  }, variant: _ios);

  testWidgets('the error hides a loading indicator the app draws under the '
      'scanner', (tester) async {
    final scanner = _FakeScanner(tester)..install();
    scanner.failures.add(true);
    const spinnerKey = Key('app-spinner');

    // Like the app: a spinner below the scanner until the camera shows.
    await tester.pumpWidget(
      _app(
        Stack(
          children: [
            const Center(
              child: SizedBox.square(key: spinnerKey, dimension: 40),
            ),
            QRView(
              key: GlobalKey(),
              onQRViewCreated: (_) {},
              overlay: QrScannerOverlayShape(cutOutSize: 200),
            ),
          ],
        ),
      ),
    );
    await _settleStart(tester);

    // The error view itself has no progress indicator.
    expect(
      find.descendant(
        of: find.byType(QRView),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString().contains('ProgressIndicator'),
        ),
      ),
      findsNothing,
    );

    // An opaque box covering the whole scanner sits under the message.
    final backdrop = find.ancestor(
      of: find.text('Could not start the camera'),
      matching: find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color.a == 1.0,
      ),
    );
    expect(backdrop, findsOneWidget);
    final covered = tester.getRect(backdrop);
    expect(covered, tester.getRect(find.byType(QRView)));
    final spinner = tester.getRect(find.byKey(spinnerKey));
    expect(covered.intersect(spinner), spinner);

    // While a retry runs the backdrop is gone, so the app's spinner shows.
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(backdrop, findsNothing);
    await _settleStart(tester);
  }, variant: _ios);

  testWidgets('a failure after the view is removed is ignored', (tester) async {
    final scanner = _FakeScanner(tester)..install();
    scanner.failures.add(true);

    await tester.pumpWidget(
      _app(QRView(key: GlobalKey(), onQRViewCreated: (_) {})),
    );
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
  }, variant: _ios);

  testWidgets('with a key that is not a GlobalKey, iOS still gets the view '
      'size before the camera starts', (tester) async {
    final scanner = _FakeScanner(tester)..install();

    await tester.pumpWidget(
      _app(QRView(key: const ValueKey('qr'), onQRViewCreated: (_) {})),
    );
    await _settleStart(tester);

    expect(tester.takeException(), isNull);
    expect(scanner.calls, containsAllInOrder(['setDimensions', 'startScan']));
    expect(find.text('Could not start the camera'), findsNothing);
  }, variant: _ios);

  testWidgets('malformed native messages do not throw', (tester) async {
    final scanner = _FakeScanner(tester)..install();
    final scanned = <Barcode>[];

    await tester.pumpWidget(
      _app(
        QRView(
          key: GlobalKey(),
          onQRViewCreated: (c) => c.scannedDataStream.listen(scanned.add),
        ),
      ),
    );
    await _settleStart(tester);

    await scanner.sendFromNative('onCameraError', 42);
    await tester.pump();
    expect(find.text('Could not start the camera'), findsOneWidget);

    await scanner.sendFromNative('onRecognizeQR', {
      'code': 7,
      'type': 'QR_CODE',
      'rawBytes': 'x',
    });
    await tester.pump();
    expect(scanned.single.format, BarcodeFormat.qrcode);
    expect(scanned.single.code, isNull);
    expect(scanned.single.rawBytes, isNull);
    expect(tester.takeException(), isNull);
  }, variant: _ios);
}
