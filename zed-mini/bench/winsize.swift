// Prints "<width>x<height> at <x>,<y> z=<n> id=<window id>" (points) for each on-screen
// window of a pid; z counts the normal windows in front of it, so z=0 is the topmost
// window on screen, and the id is what `screencapture -l` takes.
//   winsize <pid>
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
var z = 0
for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
    if (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        let id = w[kCGWindowNumber as String] as? Int ?? 0
        print("\(Int(b["Width"]!))x\(Int(b["Height"]!)) at \(Int(b["X"]!)),\(Int(b["Y"]!)) z=\(z) id=\(id)")
    }
    z += 1
}
