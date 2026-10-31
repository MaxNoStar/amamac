import AppKit

let app = NSApplication.shared
#if DEBUG
let options = LaunchOptions.current
if options.selfTestDecoders {
    exit(SelfTest.runDecoders())
}
if let canaryDir = options.canaryDir {
    app.setActivationPolicy(.accessory)
    let canary = CanaryController()
    canary.run(output: canaryDir)
    Snapshotter.startWatchdog(seconds: 30)
    app.run()
}
#endif
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
