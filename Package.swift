// swift-tools-version:5.9
// Used for `swift test` (./test.sh) and benchmarks (./bench.sh). The app itself is built with ./build.sh.
import PackageDescription

let package = Package(
    name: "Diary",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DiaryCore", path: "Sources", exclude: ["main.swift"]),
        .testTarget(name: "DiaryTests", dependencies: ["DiaryCore"], path: "Tests/DiaryTests"),
        .executableTarget(name: "Benchmarks", dependencies: ["DiaryCore"], path: "Benchmarks"),
    ]
)
