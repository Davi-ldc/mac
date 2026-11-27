// Display control for the power bench: list and switch display modes, read and set brightness.
//
//   displayctl modes                 list the modes of the main display
//   displayctl current               print the current mode
//   displayctl set <id>              switch to the mode with that id (from `modes`)
//   displayctl brightness            print brightness, 0.0 to 1.0
//   displayctl brightness <value>    set brightness
import CoreGraphics
import Foundation

let display = CGMainDisplayID()

// Without this option the list hides the scaled HiDPI modes, including the one in use.
let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []

func describe(_ mode: CGDisplayMode) -> String {
    "id=\(mode.ioDisplayModeID) points=\(mode.width)x\(mode.height) pixels=\(mode.pixelWidth)x\(mode.pixelHeight) hz=\(mode.refreshRate)"
}

func fail(_ message: String) -> Never {
    fputs("displayctl: \(message)\n", stderr)
    exit(1)
}

// Brightness of the built-in panel is only exposed by the private DisplayServices framework.
typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

func symbol<T>(_ name: String, as type: T.Type) -> T {
    guard let handle = displayServices, let pointer = dlsym(handle, name) else {
        fail("\(name) is unavailable")
    }
    return unsafeBitCast(pointer, to: type)
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "modes":
    for mode in modes where mode.isUsableForDesktopGUI() {
        print(describe(mode))
    }
case "current":
    if let mode = CGDisplayCopyDisplayMode(display) {
        print(describe(mode))
    }
case "set":
    guard let id = arguments.dropFirst().first.flatMap({ Int32($0) }),
          let mode = modes.first(where: { $0.ioDisplayModeID == id }) else {
        fail("unknown mode id")
    }
    // A plain CGDisplaySetDisplayMode is undone when this process exits; a configuration
    // completed for the session outlives it and lasts until logout.
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success else {
        fail("cannot begin a display configuration")
    }
    CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
    let status = CGCompleteDisplayConfiguration(configuration, .forSession)
    if status != .success {
        fail("switching failed with \(status.rawValue)")
    }
case "brightness":
    if let value = arguments.dropFirst().first.flatMap({ Float($0) }) {
        let status = symbol("DisplayServicesSetBrightness", as: SetBrightness.self)(display, value)
        if status != 0 {
            fail("setting brightness failed with \(status)")
        }
    } else {
        var value: Float = 0
        let status = symbol("DisplayServicesGetBrightness", as: GetBrightness.self)(display, &value)
        if status != 0 {
            fail("reading brightness failed with \(status)")
        }
        print(value)
    }
default:
    fputs("usage: displayctl modes | current | set <id> | brightness [value]\n", stderr)
    exit(2)
}
