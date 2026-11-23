// swift-tools-version:5.9
import PackageDescription

// The C libraries are built by scripts/build-deps.sh into ./vendor (universal dylibs).
let vendor = Context.packageDirectory + "/vendor"

let package = Package(
    name: "iPhoneBackupHelper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "iPhoneBackupHelper", targets: ["iPhoneBackupHelper"]),
        .library(name: "BackupCore", targets: ["BackupCore"]),
    ],
    targets: [
        // Thin module over the vendored headers (libimobiledevice, libplist).
        .target(
            name: "CLibimobiledevice",
            path: "Sources/CLibimobiledevice",
            cSettings: [.unsafeFlags(["-I", vendor + "/include"])],
            linkerSettings: [
                .unsafeFlags([
                    "-L", vendor + "/lib",
                    "-limobiledevice-1.0", "-lplist-2.0", "-lusbmuxd-2.0", "-limobiledevice-glue-1.0",
                    // Dev/test builds find the dylibs in vendor/lib; make-app.sh replaces
                    // this with @executable_path/../Frameworks and drops the absolute one.
                    "-Xlinker", "-rpath", "-Xlinker", vendor + "/lib",
                ])
            ]
        ),
        .target(
            name: "BackupCore",
            dependencies: ["CLibimobiledevice"],
            path: "Sources/BackupCore"
        ),
        .executableTarget(
            name: "iPhoneBackupHelper",
            dependencies: ["BackupCore"],
            path: "Sources/iPhoneBackupHelper",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "BackupCoreTests",
            dependencies: ["BackupCore"],
            path: "Tests/BackupCoreTests"
        ),
    ]
)
