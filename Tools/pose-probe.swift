// Vision pose probe: prints face count, bbox, yaw/pitch/roll (degrees) per image.
// Usage: swift probe.swift <image files...>
import CoreGraphics
import Foundation
import ImageIO
import Vision

func cgImage(at url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let args = Array(CommandLine.arguments.dropFirst())
for path in args {
  let url = URL(fileURLWithPath: path)
  guard let image = cgImage(at: url) else {
    print("\(url.lastPathComponent): cannot load")
    continue
  }
  let sem = DispatchSemaphore(value: 0)
  Task {
    do {
      let request = DetectFaceRectanglesRequest()
      let faces = try await request.perform(on: image)
      if faces.isEmpty {
        print("\(url.lastPathComponent): no face")
      } else {
        let primary = faces.max { a, b in
          a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }!
        let bb = primary.boundingBox.cgRect
        let yaw = primary.yaw.converted(to: .degrees).value
        let pitch = primary.pitch.converted(to: .degrees).value
        let roll = primary.roll.converted(to: .degrees).value
        print(String(
          format: "%@: faces=%d bbox=(%.2f,%.2f %.2fx%.2f) yaw=%+.1f pitch=%+.1f roll=%+.1f conf=%.2f",
          url.lastPathComponent, faces.count, bb.origin.x, bb.origin.y, bb.width, bb.height,
          yaw, pitch, roll, primary.confidence))
      }
    } catch {
      print("\(url.lastPathComponent): error \(error)")
    }
    sem.signal()
  }
  sem.wait()
}
