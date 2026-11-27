// Measures how regularly a region of the screen is updated.
//
//   cadence <x> <y> <width> <height> <seconds>      (points, origin at the top left)
//
// The window server reports a frame as complete only when the region changed, so with a
// video playing there the gaps between complete frames are the gaps between video frames
// that reached the display. Smooth 120 fps is one frame every refresh; a refresh without
// a new frame, or two video frames falling in the same refresh, shows up as judder.
//
// It also compares each frame with the one before and the one two before. Motion that
// keeps going makes the second difference larger than the first; frames shown out of
// order, or an image shaking back and forth, make it smaller.
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput {
    var times: [Double] = []
    /// Mean absolute difference to the previous frame and to the one before it.
    var changes: [(one: Double, two: Double)] = []
    private var history: [[UInt8]] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }
        times.append(buffer.presentationTimeStamp.seconds)
        guard let image = buffer.imageBuffer else { return }
        let pixels = Recorder.sample(image)
        if history.count == 2 {
            changes.append((Recorder.difference(pixels, history[1]), Recorder.difference(pixels, history[0])))
            history.removeFirst()
        }
        history.append(pixels)
    }

    /// Every fourth pixel's green channel: enough to follow motion, cheap enough for 120 Hz.
    private static func sample(_ image: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        var pixels: [UInt8] = []
        for y in stride(from: 0, to: CVPixelBufferGetHeight(image), by: 4) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(image), by: 4) {
                pixels.append(base[y * rowBytes + x * 4 + 1])
            }
        }
        return pixels
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }
}

@main
struct Cadence {
    static func main() async throws {
        let numbers = CommandLine.arguments.dropFirst().compactMap(Double.init)
        guard numbers.count == 5 else {
            FileHandle.standardError.write(Data("usage: cadence <x> <y> <width> <height> <seconds>\n".utf8))
            exit(2)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { exit(1) }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        configuration.width = Int(numbers[2])
        configuration.height = Int(numbers[3])
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.queueDepth = 8
        configuration.showsCursor = false

        let recorder = Recorder()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cadence"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(numbers[4] * 1e9))
        try await stream.stopCapture()

        let gaps = zip(recorder.times.dropFirst(), recorder.times).map { ($0 - $1) * 1000 }
        guard !gaps.isEmpty else {
            print("no frames: the region did not change")
            return
        }
        let refresh = 1000.0 / Double(CGDisplayCopyDisplayMode(display.displayID)?.refreshRate ?? 120)
        var histogram: [Int: Int] = [:]
        for gap in gaps { histogram[Int((gap / refresh).rounded()), default: 0] += 1 }
        let fps = Double(gaps.count) / (recorder.times.last! - recorder.times.first!)
        print(String(format: "%.1f updates/s over %.1f s (refresh %.2f ms)", fps, numbers[4], refresh))
        for refreshes in histogram.keys.sorted() {
            let share = 100 * Double(histogram[refreshes]!) / Double(gaps.count)
            print(String(format: "  %d refresh%@ apart: %5.1f%%  (%d)", refreshes, refreshes == 1 ? "" : "es",
                         share, histogram[refreshes]!))
        }

        let changes = recorder.changes
        guard changes.count > 10 else { return }
        let one = changes.map(\.one).reduce(0, +) / Double(changes.count)
        let two = changes.map(\.two).reduce(0, +) / Double(changes.count)
        let backward = changes.filter { $0.two < $0.one * 0.6 }.count
        print(String(format: "change per frame %.3f, over two frames %.3f (ratio %.2f)", one, two, two / one))
        print(String(format: "frames closer to the one two before than to the previous: %.1f%%",
                     100 * Double(backward) / Double(changes.count)))
    }
}
