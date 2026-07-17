package net.touchcapture.qr.flutterqrplus

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.TorchState
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.platform.PlatformView
import zxingcpp.BarcodeReader
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/*
 * CameraX + zxing-cpp implementation of the QR platform view.
 *
 * This replaces the previous zxing-android-embedded implementation (last
 * upstream release 2021, built on the deprecated Camera1 API). The
 * MethodChannel contract with the Dart side is UNCHANGED: same channel name,
 * same method names, same argument shapes, same result types.
 *
 * Architecture:
 *  - PreviewView (camera-view) renders the camera feed. Scale type is the
 *    default FILL_CENTER (center-crop), matching the old CenterCropStrategy.
 *  - ImageAnalysis streams YUV frames to a background executor where
 *    zxing-cpp's BarcodeReader decodes them.
 *  - Scan-area restriction ("framing rect") is implemented by mapping the
 *    Dart overlay's cutout rectangle from view coordinates into analysis
 *    buffer coordinates using CameraX's official transform APIs, then setting
 *    ImageProxy.cropRect, which zxing-cpp honors natively. When no scan area
 *    is configured, the crop is the visible view region, so codes outside the
 *    on-screen (center-cropped) preview can never produce scan events.
 *  - Camera start/stop is driven through a QRView-owned LifecycleRegistry
 *    (QRView implements LifecycleOwner), so pause/resume are plain lifecycle
 *    state transitions and CameraX handles the actual session teardown.
 *
 * Known intentional deviations from the old implementation (see comments at
 * the relevant code):
 *  - 'rawBytes' now carries zxing-cpp's decoded content bytes, not zxing's
 *    raw codeword stream (zxing-cpp does not expose raw codewords).
 *  - RSS-14 results are reported as "RSS14" (the string the Dart side parses);
 *    the old code emitted zxing's enum name "RSS_14", which made the Dart
 *    handler throw on every RSS-14 scan.
 *  - invertScan now replies to the channel (the old code never did, leaving
 *    the Dart future pending forever).
 */
class QRView(
    private val context: Context,
    messenger: BinaryMessenger,
    private val id: Int,
    private val params: HashMap<String, Any>
) : PlatformView, MethodChannel.MethodCallHandler, PluginRegistry.RequestPermissionsResultListener,
    LifecycleOwner {

    private val cameraRequestCode = QrShared.CAMERA_REQUEST_ID + this.id

    private val channel: MethodChannel = MethodChannel(
        messenger, "net.touchcapture.qr.flutterqrplus/qrview_$id"
    )
    private val cameraFacingBack = 0
    private val cameraFacingFront = 1

    private var isRequestingPermission = false
    private var isPaused = false
    private var isDisposed = false

    // Tracks whether the host activity is backgrounded. Camera binding is
    // asynchronous (waits for the ProcessCameraProvider future), so without
    // this flag a bind requested in the foreground could complete after the
    // app was backgrounded and leave the camera running off-screen.
    private var activityPaused = false

    private var unRegisterLifecycleCallback: UnRegisterLifecycleCallback? = null

    // The native view embedded into Flutter. Created eagerly so getView() can
    // never race camera setup.
    //
    // COMPATIBLE forces PreviewView to render through a TextureView. Do not
    // change this to the PERFORMANCE default: that renders through a
    // SurfaceView, which SurfaceFlinger composites on its own hardware layer
    // above Flutter's, hiding every Flutter widget stacked on the platform
    // view — including this plugin's QrScannerOverlayShape. A TextureView
    // draws through the normal View pipeline, so Flutter's overlay composites
    // on top correctly. zxing-android-embedded also always used a TextureView,
    // so this keeps the previous rendering behavior.
    private val previewView: PreviewView = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
    }

    // QRView acts as its own LifecycleOwner for CameraX. RESUMED = camera
    // running, CREATED = camera released (paused), DESTROYED = view disposed.
    private val lifecycleRegistry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    // CameraX handles, populated once bindCameraUseCases() runs.
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null

    // The use cases THIS view bound. ProcessCameraProvider is process-wide and
    // Flutter can instantiate a new QRView before disposing the old one (it
    // disposes the previous controller from onPlatformViewCreated), so we must
    // only ever unbind our own use cases — provider.unbindAll() would kill the
    // camera of the successor view.
    private var boundUseCases: List<UseCase> = emptyList()

    // Which lens is active: 0 = back, 1 = front. Same int contract the Dart
    // side already used with zxing's requestedCameraId.
    private var lensFacing = cameraFacingBack

    // Torch intent, main-thread only. The old zxing setTorch() queued the
    // request when called before the camera was open; this flag reproduces
    // that: it is re-applied every time the camera (re)binds. Reset on lens
    // flip because switching cameras drops the torch at the hardware level.
    private var desiredTorchOn = false

    // zxing-cpp decoder. Its `options` object is written EXCLUSIVELY on the
    // analyzer thread (see analyzeFrame), fed from the @Volatile mirrors
    // below, so main-thread configuration changes are safely published
    // without locks.
    private val barcodeReader = BarcodeReader()

    // Decoder configuration mirrors, written on the main thread by
    // startScan/invertScan, read by the analyzer each frame.
    @Volatile
    private var allowedFormats: Set<BarcodeReader.Format> = ALL_CLASSIC_FORMATS

    @Volatile
    private var tryInvertEnabled = false

    // True between startScan and stopScan/dispose. The analyzer drops frames
    // while false, so stopScan doesn't require unbinding the camera.
    @Volatile
    private var scanning = false

    // Single-threaded so frames are decoded strictly one at a time. Combined
    // with STRATEGY_KEEP_ONLY_LATEST this reproduces the old zxing decoder
    // thread's behavior: decode rate limits event rate, stale frames dropped.
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val mainHandler = Handler(Looper.getMainLooper())

    // --- Scan-area (framing rect) state -------------------------------------
    // The Dart overlay sends its cutout size via 'changeScanArea' (dp). The
    // analyzer needs the equivalent rectangle in analysis-buffer pixels. That
    // mapping is split in two:
    //   1. UI thread (refreshRoiTransform): compute the crop rect in
    //      PreviewView coordinates + snapshot PreviewView's sensor->view
    //      matrix (only legal to read on the UI thread).
    //   2. Analyzer thread (analyzeFrame): compose view->sensor->buffer using
    //      the per-frame sensorToBufferTransformMatrix and map the rect.
    private data class ScanArea(val widthPx: Int, val heightPx: Int, val bottomOffsetPx: Int)

    @Volatile
    private var scanArea: ScanArea? = null

    // Rect and matrix are published together as one immutable snapshot so the
    // analyzer can never observe a rect from one layout paired with a matrix
    // from another.
    private class RoiSnapshot(val viewRect: RectF, val sensorToView: Matrix)

    @Volatile
    private var roiSnapshot: RoiSnapshot? = null

    // Prevents the analyzer from flooding the main thread with refresh posts;
    // at most one refresh is in flight at a time.
    private val roiRefreshPending = AtomicBoolean(false)

    init {
        QrShared.binding?.addRequestPermissionsResultListener(this)

        channel.setMethodCallHandler(this)

        lifecycleRegistry.currentState = Lifecycle.State.CREATED

        // Recompute the scan-area mapping whenever the platform view is laid
        // out (rotation, resize, first layout). Replaces the work
        // zxing-android-embedded's DisplayConfiguration used to do.
        previewView.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            refreshRoiTransform()
        }

        // The sensor->view transform only becomes valid once the preview
        // stream is running; refresh the mapping at that point. Registered
        // once here (not per camera bind) so rebinds don't stack observers.
        previewView.previewStreamState.observe(this) { state ->
            if (state == PreviewView.StreamState.STREAMING) refreshRoiTransform()
        }

        // Mirror the host activity's lifecycle exactly like the old
        // implementation did: background -> release camera, foreground ->
        // restart it (or ask for permission if it was revoked meanwhile).
        unRegisterLifecycleCallback = QrShared.activity?.registerLifecycleCallbacks(
            onPause = {
                activityPaused = true
                if (!isPaused && hasCameraPermission) pauseCameraInternal()
            },
            onResume = {
                activityPaused = false
                if (!hasCameraPermission && !isRequestingPermission) checkAndRequestPermission()
                else if (!isPaused && hasCameraPermission) resumeCameraInternal()
            }
        )

        if (params[PARAMS_CAMERA_FACING] as Int == 1) {
            lensFacing = cameraFacingFront
        }
    }

    override fun dispose() {
        isDisposed = true
        scanning = false

        unRegisterLifecycleCallback?.invoke()

        QrShared.binding?.removeRequestPermissionsResultListener(this)

        // DESTROYED makes CameraX release everything bound to THIS lifecycle.
        // The explicit unbind of our own use cases is belt-and-braces for a
        // provider that resolved without a completed bind. Deliberately NOT
        // unbindAll(): a successor QRView may already be running (Flutter
        // creates the new platform view before the old one is disposed).
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
        if (boundUseCases.isNotEmpty()) {
            cameraProvider?.unbind(*boundUseCases.toTypedArray())
        }
        boundUseCases = emptyList()
        camera = null

        analysisExecutor.shutdown()
    }

    override fun getView(): View = previewView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        @Suppress("UNCHECKED_CAST")
        when (call.method) {
            "startScan" -> startScan(call.arguments as? List<Int>, result)

            "stopScan" -> stopScan()

            "flipCamera" -> flipCamera(result)

            "toggleFlash" -> toggleFlash(result)

            "pauseCamera" -> pauseCamera(result)

            // Stopping camera is the same as pausing camera
            "stopCamera" -> pauseCamera(result)

            "resumeCamera" -> resumeCamera(result)

            "requestPermissions" -> checkAndRequestPermission()

            "getCameraInfo" -> getCameraInfo(result)

            "getFlashInfo" -> getFlashInfo(result)

            "getSystemFeatures" -> getSystemFeatures(result)

            "changeScanArea" -> changeScanArea(
                dpScanAreaWidth = requireNotNull(call.argument<Double>("scanAreaWidth")),
                dpScanAreaHeight = requireNotNull(call.argument<Double>("scanAreaHeight")),
                cutOutBottomOffset = requireNotNull(call.argument<Double>("cutOutBottomOffset")),
                result = result,
            )

            "invertScan" -> setInvertScan(
                isInvert = call.argument<Boolean>("isInvertScan") ?: false,
                result = result,
            )

            else -> result.notImplemented()
        }
    }

    // region Camera lifecycle (CameraX)

    // Resolves the process-wide camera provider (async, main thread) and binds
    // the Preview + ImageAnalysis use cases. Safe to call repeatedly; also
    // used by flipCamera/resumeCamera to rebind with current settings.
    private fun ensureCameraStarted() {
        if (isDisposed) return
        val provider = cameraProvider
        if (provider != null) {
            bindCameraUseCases()
            return
        }
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (isDisposed) return@addListener
            cameraProvider = future.get()
            bindCameraUseCases()
        }, ContextCompat.getMainExecutor(context))
    }

    private fun bindCameraUseCases() {
        val provider = cameraProvider ?: return
        if (isDisposed) return
        // Never (re)start the camera while Dart paused it or while the app is
        // backgrounded. The matching resume path rebinds later. This guard is
        // what keeps the async provider callback above from starting a camera
        // in the background.
        if (isPaused || activityPaused) return

        // Unbind only what THIS view bound before; see boundUseCases comment.
        if (boundUseCases.isNotEmpty()) {
            provider.unbind(*boundUseCases.toTypedArray())
        }

        val preview = Preview.Builder().build().also {
            it.surfaceProvider = previewView.surfaceProvider
        }

        // 1280x720 target: enough pixel density for small/distant codes
        // without paying full-sensor decode cost. The old implementation
        // decoded the preview stream at a comparable resolution.
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            Size(1280, 720),
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                        )
                    )
                    .build()
            )
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
            .also { it.setAnalyzer(analysisExecutor) { image -> analyzeFrame(image) } }

        val selector =
            if (lensFacing == cameraFacingFront) CameraSelector.DEFAULT_FRONT_CAMERA
            else CameraSelector.DEFAULT_BACK_CAMERA

        // RESUMED before binding so CameraX starts the session immediately.
        lifecycleRegistry.currentState = Lifecycle.State.RESUMED
        val cam = provider.bindToLifecycle(this, selector, preview, analysis)
        camera = cam
        boundUseCases = listOf(preview, analysis)

        // Re-apply a torch request made before/while the camera was down
        // (old zxing setTorch() had the same queued-until-open behavior).
        if (desiredTorchOn) {
            cam.cameraControl.enableTorch(true)
        }
    }

    // Releasing the camera is a lifecycle transition: CameraX observes the
    // drop out of STARTED and tears the session down. The last preview frame
    // stays visible in the PreviewView, mimicking the old pause behavior.
    private fun pauseCameraInternal() {
        if (lifecycleRegistry.currentState == Lifecycle.State.RESUMED) {
            lifecycleRegistry.currentState = Lifecycle.State.CREATED
        }
    }

    // Resume always goes through a full rebind instead of only raising the
    // lifecycle state: it picks up whatever changed while the camera was down
    // (lens flip while paused, torch intent) with one code path.
    private fun resumeCameraInternal() {
        if (isDisposed) return
        // Nothing to resume if the camera was never requested.
        if (camera == null && !scanning) return
        ensureCameraStarted()
    }

    // endregion

    // region Frame analysis (zxing-cpp)

    // Runs on analysisExecutor. Applies the visible-region/scan-area crop,
    // decodes with zxing-cpp, and forwards results to Dart on the main thread
    // using the exact payload shape of the old implementation.
    private fun analyzeFrame(image: ImageProxy) {
        image.use { img ->
            if (!scanning || isDisposed) return

            // Keep the ROI snapshot fresh. There is no reliable CameraX
            // callback for "the preview transform changed" (rotation, lens
            // flip), so the analyzer continuously requests a UI-thread
            // refresh; the flag makes it at most one post in flight. The
            // cached snapshot is therefore never more than a frame or two
            // stale after a rotation or camera flip.
            requestRoiRefresh()

            // No snapshot yet (camera still starting / layout pending): skip
            // the frame rather than decode the full buffer — codes outside
            // the visible cutout must never produce scan events.
            val snapshot = roiSnapshot ?: return

            val formats = allowedFormats
            // Dart requested only formats this backend cannot decode
            // standalone (e.g. just upcEanExtension): decode nothing, like
            // the old zxing decoder configured with that same list.
            if (formats.isEmpty()) return

            // view -> sensor -> buffer: invert PreviewView's sensor->view
            // matrix, then append this frame's sensor->buffer matrix. Both
            // matrices come from CameraX and already account for rotation,
            // center-crop and resolution differences between the preview and
            // analysis streams.
            val viewToBuffer = Matrix()
            if (!snapshot.sensorToView.invert(viewToBuffer)) return
            viewToBuffer.postConcat(img.imageInfo.sensorToBufferTransformMatrix)

            val mapped = RectF(snapshot.viewRect)
            viewToBuffer.mapRect(mapped)

            val crop = Rect()
            mapped.round(crop)
            // Clamp to the buffer; an empty intersection means the cutout is
            // entirely outside this frame — nothing to scan.
            if (!crop.intersect(Rect(0, 0, img.width, img.height))) return

            // zxing-cpp's ImageProxy reader decodes only cropRect.
            img.setCropRect(crop)

            // The analyzer thread owns barcodeReader.options: every field the
            // plugin cares about is (re)applied here from the volatile
            // mirrors, so configuration written on the main thread is safely
            // published without locking.
            with(barcodeReader.options) {
                this.formats = formats
                tryInvert = tryInvertEnabled
                // Parity with the old decoder: one result per frame, and
                // plain text output (the HRI default would add GS1 formatting
                // the old zxing text never contained).
                maxNumberOfSymbols = 1
                textMode = BarcodeReader.TextMode.PLAIN
            }

            val results = try {
                barcodeReader.read(img)
            } catch (e: Exception) {
                // Defensive: a single bad frame must not kill the analyzer.
                emptyList()
            }
            if (results.isEmpty()) return

            mainHandler.post {
                if (isDisposed || !scanning) return@post
                for (r in results) {
                    // Formats without a name in the legacy contract are
                    // dropped: the Dart side throws on unknown type strings.
                    val typeName = FORMAT_TO_CONTRACT_NAME[r.format] ?: continue
                    // Note: rawBytes is zxing-cpp's decoded content bytes;
                    // the old implementation sent zxing's raw codeword
                    // stream, which zxing-cpp does not expose.
                    val event = mapOf(
                        "code" to r.text,
                        "type" to typeName,
                        "rawBytes" to r.bytes,
                    )
                    channel.invokeMethod(CHANNEL_METHOD_ON_RECOGNIZE_QR, event)
                }
            }
        }
    }

    // endregion

    // region Scan area (framing rect)

    // UI-thread half of the scan-area mapping: rebuild the crop rectangle in
    // view coordinates and snapshot the sensor->view matrix (PreviewView only
    // exposes it on the UI thread). With a scan area configured the rect is
    // the old CustomFramingRectBarcodeView geometry: centered, shifted up by
    // bottomOffset, clamped to the view — and, like the old code, falling
    // back to the unshifted centered rect when the offset pushes it fully
    // off-screen. Without a scan area the rect is the whole visible view.
    private fun refreshRoiTransform() {
        roiRefreshPending.set(false)

        val viewWidth = previewView.width.toFloat()
        val viewHeight = previewView.height.toFloat()
        if (viewWidth == 0f || viewHeight == 0f) return
        val fullView = RectF(0f, 0f, viewWidth, viewHeight)

        val viewRect = computeViewRect(fullView) ?: run {
            roiSnapshot = null
            return
        }

        // Not yet available while the preview stream is starting; the
        // analyzer keeps requesting refreshes until it appears.
        val sensorToView = previewView.sensorToViewTransform ?: run {
            roiSnapshot = null
            return
        }

        roiSnapshot = RoiSnapshot(viewRect, Matrix(sensorToView))
    }

    private fun computeViewRect(fullView: RectF): RectF? {
        val area = scanArea ?: return RectF(fullView)

        val centerX = fullView.width() / 2f
        val centerY = fullView.height() / 2f
        val halfW = area.widthPx / 2f
        val halfH = area.heightPx / 2f

        val shifted = RectF(
            centerX - halfW,
            centerY - halfH - area.bottomOffsetPx,
            centerX + halfW,
            centerY + halfH - area.bottomOffsetPx,
        )
        if (shifted.intersect(fullView)) return shifted

        // Offset pushed the rect fully off-screen: same fallback the old
        // implementation had — use the unshifted centered rect.
        val centered = RectF(centerX - halfW, centerY - halfH, centerX + halfW, centerY + halfH)
        if (centered.intersect(fullView)) return centered

        return null
    }

    // Called from the analyzer thread. Posts at most one refresh to the UI
    // thread at a time.
    private fun requestRoiRefresh() {
        if (roiRefreshPending.compareAndSet(false, true)) {
            mainHandler.post { refreshRoiTransform() }
        }
    }

    private fun changeScanArea(
        dpScanAreaWidth: Double,
        dpScanAreaHeight: Double,
        cutOutBottomOffset: Double,
        result: MethodChannel.Result
    ) {
        scanArea = ScanArea(
            widthPx = dpScanAreaWidth.convertDpToPixels(),
            heightPx = dpScanAreaHeight.convertDpToPixels(),
            bottomOffsetPx = cutOutBottomOffset.convertDpToPixels(),
        )
        refreshRoiTransform()
        result.success(true)
    }

    // endregion

    // region Camera Info

    private fun getCameraInfo(result: MethodChannel.Result) {
        result.success(lensFacing)
    }

    // Reports the actual hardware torch state once the camera is bound, and
    // the queued torch intent before that (the old implementation's shadow
    // boolean answered false before the camera opened — same observable
    // behavior, never an error).
    private fun getFlashInfo(result: MethodChannel.Result) {
        result.success(isTorchCurrentlyOn())
    }

    private fun isTorchCurrentlyOn(): Boolean {
        val cam = camera ?: return desiredTorchOn
        return cam.cameraInfo.torchState.value == TorchState.ON
    }

    private fun hasFlash(): Boolean {
        return hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH)
    }

    @SuppressLint("UnsupportedChromeOsCameraSystemFeature")
    private fun hasBackCamera(): Boolean {
        return hasSystemFeature(PackageManager.FEATURE_CAMERA)
    }

    private fun hasFrontCamera(): Boolean {
        return hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
    }

    private fun hasSystemFeature(feature: String): Boolean =
        context.packageManager.hasSystemFeature(feature)

    private fun getSystemFeatures(result: MethodChannel.Result) {
        try {
            result.success(
                mapOf(
                    "hasFrontCamera" to hasFrontCamera(),
                    "hasBackCamera" to hasBackCamera(),
                    "hasFlash" to hasFlash(),
                    "activeCamera" to lensFacing
                )
            )
        } catch (e: Exception) {
            result.error("", e.message, null)
        }
    }

    // endregion

    // region Camera Controls

    // Switches lens by rebinding the use cases with the other CameraSelector.
    // If the camera is currently down (paused/backgrounded) only the state
    // flips; the next resume rebinds with the new lens. Torch intent resets
    // because switching cameras drops the torch at the hardware level (same
    // as the old implementation's pause/switch/resume cycle).
    private fun flipCamera(result: MethodChannel.Result) {
        lensFacing =
            if (lensFacing == cameraFacingFront) cameraFacingBack else cameraFacingFront

        desiredTorchOn = false

        if (camera != null) {
            bindCameraUseCases()
        }

        result.success(lensFacing)
    }

    // Torch control moved from zxing's setTorch to CameraX CameraControl.
    // Works before the camera is bound too: the intent is stored and applied
    // on bind, mirroring old zxing's queued setTorch behavior.
    private fun toggleFlash(result: MethodChannel.Result) {
        if (!hasFlash()) {
            result.error(ERROR_CODE_NOT_SET, ERROR_MESSAGE_FLASH_NOT_FOUND, null)
            return
        }

        desiredTorchOn = !isTorchCurrentlyOn()
        camera?.cameraControl?.enableTorch(desiredTorchOn)
        result.success(desiredTorchOn)
    }

    private fun pauseCamera(result: MethodChannel.Result) {
        isPaused = true
        pauseCameraInternal()
        result.success(true)
    }

    private fun resumeCamera(result: MethodChannel.Result) {
        isPaused = false
        resumeCameraInternal()
        result.success(true)
    }

    // Configures the decoder's format allow-list and starts the camera once
    // permission is granted. Contract note: when Dart sends an empty list
    // ("scan everything"), the formats are pinned to the 16 classic ZXing
    // formats rather than zxing-cpp's full set — newer symbologies (MicroQR,
    // rMQR, DataBar Limited, ...) have no type string in the Dart enum and
    // would make the Dart handler throw.
    private fun startScan(arguments: List<Int>?, result: MethodChannel.Result) {
        checkAndRequestPermission()

        allowedFormats =
            if (arguments.isNullOrEmpty()) ALL_CLASSIC_FORMATS
            // May map to an empty set (e.g. only upcEanExtension was
            // requested); the analyzer then decodes nothing, which is what
            // the old decoder did with that same configuration.
            else arguments.mapNotNull { DART_INDEX_TO_FORMAT[it] }.toSet()

        scanning = true

        if (hasCameraPermission) {
            ensureCameraStarted()
        }
        // If permission is not granted yet, onRequestPermissionsResult starts
        // the camera as soon as the user allows it.
    }

    private fun stopScan() {
        // Analyzer keeps receiving frames but drops them; matches the old
        // stopDecoding() which kept the preview alive.
        scanning = false
    }

    // Inverted-color scanning. zxing-cpp's tryInvert decodes both normal and
    // inverted codes per frame (the old cameraSettings.isScanInverted decoded
    // only inverted ones — tryInvert is a strict superset, so inverted codes
    // keep working). Also replies to the channel, which the old code forgot,
    // leaving the Dart future to hang forever.
    private fun setInvertScan(isInvert: Boolean, result: MethodChannel.Result) {
        tryInvertEnabled = isInvert
        result.success(true)
    }

    // endregion

    // region permissions

    private val hasCameraPermission: Boolean
        get() = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        if (requestCode != cameraRequestCode) return false
        isRequestingPermission = false

        val permissionGranted =
            grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED

        channel.invokeMethod(CHANNEL_METHOD_ON_PERMISSION_SET, permissionGranted)

        // Start the camera that startScan requested while permission was
        // still pending.
        if (permissionGranted && scanning && !isPaused) {
            ensureCameraStarted()
        }

        return permissionGranted
    }

    private fun checkAndRequestPermission() {
        if (hasCameraPermission) {
            channel.invokeMethod(CHANNEL_METHOD_ON_PERMISSION_SET, true)
            return
        }

        if (isRequestingPermission) return

        // Only mark the request in flight when it was actually made; with no
        // activity attached there will never be a callback to clear the flag.
        val activity = QrShared.activity ?: return
        isRequestingPermission = true
        activity.requestPermissions(
            arrayOf(Manifest.permission.CAMERA),
            cameraRequestCode
        )
    }

    // endregion

    // region helpers

    private fun Double.convertDpToPixels() =
        (this * context.resources.displayMetrics.density).toInt()

    // endregion

    companion object {
        private const val CHANNEL_METHOD_ON_PERMISSION_SET = "onPermissionSet"
        private const val CHANNEL_METHOD_ON_RECOGNIZE_QR = "onRecognizeQR"

        private const val PARAMS_CAMERA_FACING = "cameraFacing"

        private const val ERROR_CODE_NOT_SET = "404"

        private const val ERROR_MESSAGE_FLASH_NOT_FOUND = "This device doesn't support flash"

        // Dart BarcodeFormat.index -> zxing-cpp Format. Indices are the Dart
        // enum's declaration order, which matched com.google.zxing's ordinal
        // order in the old implementation — this table freezes that contract.
        // Index 16 (upcEanExtension) is intentionally absent: it is not a
        // standalone symbology in zxing-cpp.
        private val DART_INDEX_TO_FORMAT = mapOf(
            0 to BarcodeReader.Format.AZTEC,
            1 to BarcodeReader.Format.CODABAR,
            2 to BarcodeReader.Format.CODE_39,
            3 to BarcodeReader.Format.CODE_93,
            4 to BarcodeReader.Format.CODE_128,
            5 to BarcodeReader.Format.DATA_MATRIX,
            6 to BarcodeReader.Format.EAN_8,
            7 to BarcodeReader.Format.EAN_13,
            8 to BarcodeReader.Format.ITF,
            9 to BarcodeReader.Format.MAXI_CODE,
            10 to BarcodeReader.Format.PDF_417,
            11 to BarcodeReader.Format.QR_CODE,
            12 to BarcodeReader.Format.DATA_BAR,
            13 to BarcodeReader.Format.DATA_BAR_EXP,
            14 to BarcodeReader.Format.UPC_A,
            15 to BarcodeReader.Format.UPC_E,
        )

        private val ALL_CLASSIC_FORMATS: Set<BarcodeReader.Format> =
            DART_INDEX_TO_FORMAT.values.toSet()

        // zxing-cpp Format -> type string sent to Dart. Must produce exactly
        // the strings the Dart BarcodeTypesExtension.fromString understands
        // (the com.google.zxing enum names the old implementation emitted —
        // except RSS14/RSS_EXPANDED, where the Dart parser always expected
        // "RSS14"/"RSS_EXPANDED"; RSS_EXPANDED matched zxing's name, RSS14
        // did not, so RSS-14 scans used to throw on the Dart side).
        private val FORMAT_TO_CONTRACT_NAME = mapOf(
            BarcodeReader.Format.AZTEC to "AZTEC",
            BarcodeReader.Format.CODABAR to "CODABAR",
            BarcodeReader.Format.CODE_39 to "CODE_39",
            BarcodeReader.Format.CODE_93 to "CODE_93",
            BarcodeReader.Format.CODE_128 to "CODE_128",
            BarcodeReader.Format.DATA_MATRIX to "DATA_MATRIX",
            BarcodeReader.Format.EAN_8 to "EAN_8",
            BarcodeReader.Format.EAN_13 to "EAN_13",
            BarcodeReader.Format.ITF to "ITF",
            BarcodeReader.Format.MAXI_CODE to "MAXICODE",
            BarcodeReader.Format.PDF_417 to "PDF_417",
            BarcodeReader.Format.QR_CODE to "QR_CODE",
            BarcodeReader.Format.DATA_BAR to "RSS14",
            BarcodeReader.Format.DATA_BAR_EXP to "RSS_EXPANDED",
            BarcodeReader.Format.UPC_A to "UPC_A",
            BarcodeReader.Format.UPC_E to "UPC_E",
        )
    }
}
