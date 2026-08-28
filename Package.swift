// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "CapsizedMoneroKit.Swift",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "CapsizedMoneroKit",
            targets: ["CapsizedMoneroKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.0.0")),
        .package(url: "https://github.com/horizontalsystems/HdWalletKit.Swift.git", .upToNextMajor(from: "1.2.1")),
        .package(url: "https://github.com/horizontalsystems/HsToolKit.Swift.git", .upToNextMajor(from: "2.0.5")),
    ],
    targets: [
        .target(
            name: "CapsizedMoneroKit",
            dependencies: [
                "CMonero",
                "CPolyseed",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HdWalletKit", package: "HdWalletKit.Swift"),
                .product(name: "HsToolKit", package: "HsToolKit.Swift"),
            ],
            path: "Sources/CapsizedMoneroKit"
        ),
        .target(
            name: "CMonero",
            dependencies: ["MoneroBinary"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .define("BOOST_ERROR_CODE_HEADER_ONLY"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "CPolyseed",
            path: "Sources/CPolyseed",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("NDEBUG"),
            ]
        ),
        .binaryTarget(
            name: "MoneroBinary",
            url: "https://github.com/viproject/CapsizedMoneroKit.Swift/releases/download/v1.0.0/Monero.xcframework.zip",
            checksum: "3c37734225a04a909194ede55deaa39efeb136a754c5013b1c44b79e6e44deba"
        ),
    ],
    cxxLanguageStandard: .cxx11
)
