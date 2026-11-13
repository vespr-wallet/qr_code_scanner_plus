//
//  QRViewFactory.swift
//  flutter_qr
//
//  Created by Julius Canute on 21/12/18.
//

import Foundation
import Flutter

public class QRViewFactory: NSObject, FlutterPlatformViewFactory {

    let registrar: FlutterPluginRegistrar

    public init(withRegistrar registrar: FlutterPluginRegistrar){
        self.registrar = registrar
        super.init()
    }

    public func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        let params = args as? Dictionary<String, Any> ?? [:]
        return QRView(withFrame: frame, withRegistrar: registrar, withId: viewId, params: params)
    }

    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec(readerWriter: FlutterStandardReaderWriter())
    }
}
