import Flutter
import UIKit
import XCTest
@testable import qr_code_scanner_plus

final class PluginRegistrationTests: XCTestCase {
    func testRegistersSameInstanceForBothLifecycles() throws {
        let registrar = RecordingRegistrar()

        SwiftFlutterQrPlusPlugin.register(with: registrar)

        XCTAssertEqual(registrar.applicationDelegates.count, 1)
        XCTAssertEqual(registrar.sceneDelegates.count, 1)
        let instance = try XCTUnwrap(
            registrar.applicationDelegates.first as? SwiftFlutterQrPlusPlugin
        )
        XCTAssertTrue(registrar.sceneDelegates.first === instance)
    }

    func testRegistersPlatformViewFactoryOnlyOnce() throws {
        let registrar = RecordingRegistrar()

        SwiftFlutterQrPlusPlugin.register(with: registrar)

        XCTAssertEqual(registrar.factories.count, 1)
        let registration = try XCTUnwrap(registrar.factories.first)
        XCTAssertEqual(registration.id, "net.touchcapture.qr.flutterqrplus/qrview")
        let instance = try XCTUnwrap(
            registrar.applicationDelegates.first as? SwiftFlutterQrPlusPlugin
        )
        XCTAssertTrue(registration.factory === instance.factory)
        XCTAssertTrue(instance.factory.registrar === registrar)
    }
}

private final class RecordingRegistrar: NSObject, FlutterPluginRegistrar {
    var applicationDelegates: [FlutterPlugin] = []
    var sceneDelegates: [FlutterSceneLifeCycleDelegate] = []
    var factories: [(factory: FlutterPlatformViewFactory, id: String)] = []
    var viewController: UIViewController? { nil }
    // Required by FlutterBaseRegistrar since Flutter 3.50.
    var engineIdentifier: Int64 { 0 }

    func addApplicationDelegate(_ delegate: FlutterPlugin) {
        applicationDelegates.append(delegate)
    }

    func addSceneDelegate(_ delegate: FlutterSceneLifeCycleDelegate) {
        sceneDelegates.append(delegate)
    }

    func register(_ factory: FlutterPlatformViewFactory, withId factoryId: String) {
        factories.append((factory, factoryId))
    }

    func register(
        _ factory: FlutterPlatformViewFactory,
        withId factoryId: String,
        gestureRecognizersBlockingPolicy: FlutterPlatformViewGestureRecognizersBlockingPolicy
    ) {
        factories.append((factory, factoryId))
    }

    func messenger() -> FlutterBinaryMessenger {
        fatalError("Plugin registration must not access the messenger")
    }

    func textures() -> FlutterTextureRegistry {
        fatalError("Plugin registration must not access textures")
    }

    func publish(_ value: NSObject) {
        XCTFail("Unexpected plugin publication")
    }

    func addMethodCallDelegate(_ delegate: FlutterPlugin, channel: FlutterMethodChannel) {
        XCTFail("Unexpected plugin-level method channel")
    }

    func lookupKey(forAsset asset: String) -> String {
        fatalError("Plugin registration must not look up assets")
    }

    func lookupKey(forAsset asset: String, fromPackage package: String) -> String {
        fatalError("Plugin registration must not look up assets")
    }

    func valuePublished(byPlugin pluginKey: String) -> NSObject? {
        fatalError("Plugin registration must not look up other plugins")
    }
}
