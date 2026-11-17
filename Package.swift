// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZaFe",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "ZaFe", targets: ["ZaFe"])],
    targets: [
        .target(name: "ZaFeKit"),
        .executableTarget(name: "ZaFe", dependencies: ["ZaFeKit"]),
        .testTarget(name: "ZaFeKitTests", dependencies: ["ZaFeKit"])
    ]
)
