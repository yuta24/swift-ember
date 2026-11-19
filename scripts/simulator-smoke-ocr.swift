import CoreML
import Foundation
import Vision

let screenshot = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .fast
request.recognitionLanguages = ["en-US"]
// Keep OCR independent of GPU and Neural Engine availability on hosted runners.
for (stage, devices) in try request.supportedComputeStageDevices {
    let cpu = devices.first { device in
        if case .cpu = device { return true }
        return false
    }
    if let cpu { request.setComputeDevice(cpu, for: stage) }
}
try VNImageRequestHandler(url: screenshot).perform([request])
for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string {
        print(text)
    }
}
