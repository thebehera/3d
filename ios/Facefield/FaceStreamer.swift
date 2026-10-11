import ARKit
import WebKit

/// Runs ARKit face tracking and streams each frame into the page's `window.facefieldNative.frame()`.
///
/// Everything is sent in the subject's own frame (+x = their left, +y = up, +z = out of the face),
/// the same frame the web build gets from MediaPipe, so the page mirrors both the same way.
final class FaceStreamer: NSObject, ARSessionDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "facefield.ar")
    private var started = false
    private var inFlight = false
    private var lastSent: TimeInterval = 0
    private var sends = 0
    private var micLevel: Float = 0

    // depth grid covering the page's pin field: x -19...19, y -15...13 model units (1 unit ≈ 1 cm)
    private let gridW = 80, gridH = 60

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "ready", !started else { return }
        started = true
        start()
    }

    private func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            say("This device has no TrueDepth camera, so face tracking is unavailable.")
            return
        }
        let config = ARFaceTrackingConfiguration()
        config.providesAudioData = true
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        session.delegate = self
        session.delegateQueue = queue
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        say("Tracking with ARKit and the TrueDepth camera.")
    }

    private func say(_ text: String) {
        let js = "document.getElementById('camMsg').textContent = \(jsonString(text));"
        DispatchQueue.main.async { self.webView?.evaluateJavaScript(js) }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !inFlight, frame.timestamp - lastSent >= 1.0 / 30.0,
              let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked
        else { return }
        lastSent = frame.timestamp
        sends += 1

        let camPos = frame.camera.transform.columns.3.xyz
        let facePos = face.transform.columns.3.xyz
        // a frame that faces the camera upright: z toward the camera, y against gravity, x = subject's left
        let toCam = simd_normalize(camPos - facePos)
        let left = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), toCam))
        let up = simd_cross(toCam, left)
        let mirrorFrame = simd_float3x3(left, up, toCam)
        let faceRot = simd_float3x3(face.transform.columns.0.xyz, face.transform.columns.1.xyz, face.transform.columns.2.xyz)
        let r = mirrorFrame.transpose * faceRot
        let pose: [Float] = [r.columns.0.x, r.columns.0.y, r.columns.0.z, 0,
                             r.columns.1.x, r.columns.1.y, r.columns.1.z, 0,
                             r.columns.2.x, r.columns.2.y, r.columns.2.z, 0,
                             0, 0, 0, 1]

        var blend: [String: Float] = [:]
        for (key, value) in face.blendShapes { blend[key.rawValue] = value.floatValue }

        let verts = face.geometry.vertices
        var flat = [Float](); flat.reserveCapacity(verts.count * 3)
        for v in verts { flat.append(v.x); flat.append(v.y); flat.append(v.z) }

        var payload: [String: Any] = [
            "pose": pose,
            "bs": blend,
            "mic": micLevel,
            "verts": base64(flat),
        ]
        // depth arrives at ~15 Hz; every other send is plenty for the pins
        if sends % 2 == 0, let depth = frame.capturedDepthData,
           let grid = depthGrid(depth, frame: frame, facePos: facePos, camPos: camPos, left: left, up: up) {
            payload["depth"] = grid
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        inFlight = true
        DispatchQueue.main.async {
            guard let web = self.webView else { self.queue.async { self.inFlight = false }; return }
            web.evaluateJavaScript("window.facefieldNative && facefieldNative.frame(\(json))") { _, _ in
                self.queue.async { self.inFlight = false }
            }
        }
    }

    /// Samples the TrueDepth map on a camera-facing plane through the face, laid out the way the
    /// mirrored screen shows it: grid +x is the subject's right, row 0 is the top.
    private func depthGrid(_ raw: AVDepthData, frame: ARFrame, facePos: SIMD3<Float>, camPos: SIMD3<Float>,
                           left: SIMD3<Float>, up: SIMD3<Float>) -> [String: Any]? {
        let depth = raw.depthDataType == kCVPixelFormatType_DepthFloat32
            ? raw : raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), rowBytes = CVPixelBufferGetBytesPerRow(map)
        let viewport = CGSize(width: w, height: h)
        let forward = -frame.camera.transform.columns.2.xyz
        let dc = simd_dot(facePos - camPos, forward)

        var out = [Float](repeating: 0, count: gridW * gridH)
        for gy in 0..<gridH {
            let my = 13 - 28 * Float(gy) / Float(gridH - 1)
            for gx in 0..<gridW {
                let mx = -19 + 38 * Float(gx) / Float(gridW - 1)
                let world = facePos - left * (mx / 100) + up * (my / 100)
                // landscapeRight + the buffer's own size = pixel coordinates in the captured buffers
                let p = frame.camera.projectPoint(world, orientation: .landscapeRight, viewportSize: viewport)
                let px = Int(p.x), py = Int(p.y)
                guard px >= 0, py >= 0, px < w, py < h else { continue }
                let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: Float32.self)
                let d = row[px]
                out[gy * gridW + gx] = d.isFinite ? d : 0
            }
        }
        return ["w": gridW, "h": gridH, "dc": dc, "data": base64(out)]
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { return }
        let raw = UnsafeRawPointer(pointer)
        var sum: Float = 0, n = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            n = length / 4
            let s = raw.assumingMemoryBound(to: Float.self)
            for i in 0..<n { sum += s[i] * s[i] }
        } else {
            n = length / 2
            let s = raw.assumingMemoryBound(to: Int16.self)
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        }
        if n > 0 { micLevel = min(1, (sum / Float(n)).squareRoot() * 9) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        say("ARKit stopped: \(error.localizedDescription)")
    }
}

private func base64(_ floats: [Float]) -> String {
    floats.withUnsafeBufferPointer { Data(buffer: $0).base64EncodedString() }
}

private func jsonString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
