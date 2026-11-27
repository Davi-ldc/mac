// A minimal CAMetalLayer app: clears its layer 60 times a second for 12 s, without taking
// focus. It answers whether the GPU memory Zed holds while it redraws (18 unmapped 8 MB
// blocks) comes with any CAMetalLayer rendering on this system, or with how Zed renders.
//   metal-probe [nosync] [transaction] [readable] [seconds=N]
//   (then: footprint -v <pid> | grep "Owned physical")
// The switches try layer settings that might avoid those blocks: no display sync,
// presenting with the Core Animation transaction, and a readable framebuffer.
import AppKit
import Metal
import QuartzCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let window = NSWindow(
    contentRect: NSRect(x: 80, y: 80, width: 800, height: 500),
    styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Zed Mini bench: Metal probe"
let view = NSView(frame: window.contentView!.bounds)
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.isOpaque = true
layer.drawableSize = CGSize(width: 1600, height: 1000)
let switches = Set(CommandLine.arguments.dropFirst())
let seconds = switches.compactMap { $0.hasPrefix("seconds=") ? Double($0.dropFirst(8)) : nil }.first ?? 12
if switches.contains("nosync") { layer.displaySyncEnabled = false }
if switches.contains("transaction") { layer.presentsWithTransaction = true }
if switches.contains("readable") { layer.framebufferOnly = false }
view.layer = layer
view.wantsLayer = true
window.contentView = view
window.orderFrontRegardless()

var frame = 0
let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    guard let drawable = layer.nextDrawable() else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
        red: Double(frame % 60) / 240.0, green: 0.16, blue: 0.21, alpha: 1)
    let commands = queue.makeCommandBuffer()!
    commands.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    if layer.presentsWithTransaction {
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    } else {
        commands.present(drawable)
        commands.commit()
    }
    frame += 1
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
