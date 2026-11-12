// swift-tools-version:5.0
import PackageDescription
import Foundation

let localTestPath = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("Tests/ZIPFoundationTests").path
let localTests: [Target] = FileManager.default.fileExists(atPath: localTestPath)
    ? [.testTarget(name: "ZIPFoundationTests", dependencies: ["ZIPFoundation"])] : []

#if canImport(Compression)
let targets: [Target] = [
    .target(name: "ZIPFoundation")
] + localTests
#else
let targets: [Target] = [
    .systemLibrary(name: "CZLib", pkgConfig: "zlib", providers: [.brew(["zlib"]), .apt(["zlib"])]),
    .target(name: "ZIPFoundation", dependencies: ["CZLib"], cSettings: [.define("_GNU_SOURCE", to: "1")])
] + localTests
#endif

let package = Package(
    name: "ZIPFoundation",
    platforms: [
        .macOS(.v10_11), .iOS(.v9), .tvOS(.v9), .watchOS(.v2)
    ],
    products: [
        .library(name: "ZIPFoundation", targets: ["ZIPFoundation"])
    ],
    targets: targets,
    swiftLanguageVersions: [.v4, .v4_2, .v5]
)
