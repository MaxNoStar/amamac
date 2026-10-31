import Foundation

/// Command-line options. Release builds honour only `--data-dir`; the automation options
/// (`make snapshot`, `make perf`, self tests) exist in Debug builds.
struct LaunchOptions {
    var snapshotDir: URL?
    var dataDir: URL?
    var dumpLayout: URL?
    var selfTestDecoders = false
    var canaryDir: URL?
    var perfOutput: URL?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var i = 1
        func value() -> String? {
            i += 1
            return i < arguments.count ? arguments[i] : nil
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--data-dir": dataDir = value().map { URL(fileURLWithPath: $0) }
            #if DEBUG
            case "--snapshot": snapshotDir = value().map { URL(fileURLWithPath: $0) }
            case "--dump-layout": dumpLayout = value().map { URL(fileURLWithPath: $0) }
            case "--selftest-decoders": selfTestDecoders = true
            case "--canary": canaryDir = value().map { URL(fileURLWithPath: $0) }
            case "--perf": perfOutput = value().map { URL(fileURLWithPath: $0) }
            #endif
            default: break
            }
            i += 1
        }
    }

    var isAutomation: Bool { snapshotDir != nil || selfTestDecoders || canaryDir != nil || perfOutput != nil }
}
