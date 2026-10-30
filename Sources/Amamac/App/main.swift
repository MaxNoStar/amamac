import AppKit

let options = LaunchOptions.current
if options.selfTestDecoders {
    exit(SelfTest.runDecoders())
}

let app = NSApplication.shared
if let canaryDir = options.canaryDir {
    app.setActivationPolicy(.accessory)
    let canary = CanaryController()
    canary.run(output: canaryDir)
    Snapshotter.startWatchdog(seconds: 30)
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
