// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SonixLink",
    platforms: [.iOS(.v16)],
    products: [.executable(name: "SonixLink", targets: ["SonixLink"])],
    targets: [.executableTarget(name: "SonixLink", path: "SonixLink", exclude: ["Info.plist"])]
)
