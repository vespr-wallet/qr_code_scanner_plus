// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "qr_code_scanner_plus",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(name: "qr-code-scanner-plus", targets: ["qr_code_scanner_plus"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "qr_code_scanner_plus",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
