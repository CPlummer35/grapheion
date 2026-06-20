import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // macOS BLE bridge (CoreBluetooth <-> peat-btle), mirroring iOS.
    PeatBleBridge.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
