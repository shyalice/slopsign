// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localTests: [Target] = FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Tests/SignerCoreTests").path)
    ? [.testTarget(name: "SignerCoreTests", dependencies: ["SignerCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")])]
    : []
let package = Package(
    name: "SignerCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "SignerCore", targets: ["SignerCore"])],
    dependencies: [
        .package(path: "../../Vendor/Zsign"),
        .package(path: "../../Vendor/ZIPFoundation"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", exact: "3.3.3001")
    ],
    targets: [
        .target(name: "SignerArchive", cSettings: [.define("MINIZIP_FOPEN_NO_64"), .define("NOUNCRYPT"), .define("NOCRYPT"), .unsafeFlags(["-O3"], .when(configuration: .release))], linkerSettings: [.linkedLibrary("archive"), .linkedLibrary("z")]),
        .target(name: "SignerCrypto", dependencies: [.product(name: "OpenSSL", package: "OpenSSL")], linkerSettings: [.linkedFramework("OpenSSL")]),
        .target(name: "SignerCore", dependencies: ["SignerArchive", "SignerCrypto", .product(name: "Zsign", package: "Zsign"), .product(name: "ZIPFoundation", package: "ZIPFoundation")])
    ] + localTests, cxxLanguageStandard: .cxx17
)
