// Pocket3Bar: menu bar controller for the DJI Osmo Pocket 3 in webcam mode.
//
// Talks to the bundled panel server (server.py on 127.0.0.1:8765) for every camera
// control, and runs face tracking natively (AVFoundation + Vision), so tracking keeps
// going while the menu is closed. Pops open when another app (a meeting) turns the
// camera on. `open pocket3bar://show` also pops the menu open.

import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import Vision

let BASE = URL(string: "http://127.0.0.1:8765")!
/// The panel server ships inside the app (Contents/Resources/server); POCKET3_SERVER_DIR overrides it.
let SERVER_DIR = ProcessInfo.processInfo.environment["POCKET3_SERVER_DIR"]
    ?? (Bundle.main.resourcePath ?? ".") + "/server"
let LOG_DIR = NSHomeDirectory() + "/Library/Logs"

func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = LOG_DIR + "/Pocket3Bar.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8)) }
}

// MARK: - Server API

struct Ranges: Decodable { let pan: [Double]; let tilt: [Double]; let zoom: [Double]; let roll: [Double] }
struct Preset: Decodable { let pan: Double; let tilt: Double; let zoom: Double; let roll: Double }
struct CamState: Decodable {
    let pan: Double, tilt: Double, zoom: Double, roll: Double
    let hold: Bool
    let facing: String
    let ranges: Ranges
    let presets: [String: Preset]
}
struct APIError: Decodable { let error: String? }

enum API {
    static func call(_ path: String, _ body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: BASE.appendingPathComponent(path))
        req.timeoutInterval = 4
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, rsp) = try await URLSession.shared.data(for: req)
        if let h = rsp as? HTTPURLResponse, h.statusCode != 200 {
            let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error ?? "HTTP \(h.statusCode)"
            throw NSError(domain: "Pocket3", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    /// Fire-and-forget POST used by the tracker (no state decode).
    static func send(_ path: String, _ body: [String: Any], done: (() -> Void)? = nil) {
        var req = URLRequest(url: BASE.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, _, _ in done?() }.resume()
    }
}

// MARK: - Model

enum TrackMode { case off, on, paused }

@MainActor
final class Model: ObservableObject {
    @Published var state: CamState?
    @Published var error: String?
    @Published var serverDown = false
    @Published var trackMode: TrackMode = .off { didSet { tracker.mode = trackMode; onIconChange?() } }
    @Published var trackStatus = ""
    @Published var pace: Double = 3 { didSet { tracker.pace = pace } }
    @Published var speed: Double = 3
    @Published var face: CGRect?           // normalized, top-left origin
    @Published var eyes: CGPoint?          // between the eyes, normalized, top-left origin
    @Published var zoomDraft: Double?      // while dragging the zoom slider
    @Published var rollDraft: Double?
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled
    @Published var videoProblem: String?
    @Published var previewOn = UserDefaults.standard.object(forKey: "previewOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(previewOn, forKey: "previewOn"); updateCamera() }
    }

    var popoverOpen = false { didSet { updateCamera() } }

    /// Run the camera while the preview is visible or tracking is on.
    func updateCamera() {
        tracker.wantPreview = popoverOpen && previewOn
        tracker.wantTracking = trackMode != .off
        if tracker.wantPreview || tracker.wantTracking {
            tracker.start { [weak self] err in
                Task { @MainActor in if let err { self?.videoProblem = err } }
            }
        } else {
            tracker.stopIfUnused()
        }
    }
    var onIconChange: (() -> Void)?
    let tracker = Tracker()
    private var moveTimer: Timer?
    private var lastServerStart = 0.0
    private var lastAutoOpen = 0.0
    private var cameraWasBusy = false
    var onMeetingStart: (() -> Void)?
    @Published var autoOpen = UserDefaults.standard.object(forKey: "autoOpen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOpen, forKey: "autoOpen") }
    }

    init() {
        tracker.model = self
        _ = tracker.previewLayer
        tracker.onProblem = { [weak self] p in Task { @MainActor in self?.videoProblem = p } }
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkMeeting() }
        }
        refresh()
    }

    /// Meeting detection: another app (Zoom, Meet, FaceTime…) turned the Pocket 3 on.
    /// `isInUseByAnotherApplication` ignores this app's own preview and tracking.
    func checkMeeting() {
        let busy = Tracker.findPocket3()?.isInUseByAnotherApplication ?? false
        defer { cameraWasBusy = busy }
        guard busy, !cameraWasBusy else { return }
        debugLog("another app turned the camera on")
        if serverDown || state == nil { refresh() }
        let now = CACurrentMediaTime()
        if autoOpen, now - lastAutoOpen > 300 {   // at most once every 5 minutes
            lastAutoOpen = now
            onMeetingStart?()
        }
    }

    private var tickCount = 0
    func tick() {
        tickCount += 1
        // Poll fast while the menu is open, slowly otherwise (for the icon).
        if popoverOpen || tickCount % 5 == 0 { if moveTimer == nil { refresh() } }
    }

    func refresh() { Task { await run(nil) } }

    func run(_ path: String?, _ body: [String: Any] = [:]) async {
        do {
            let data = try await API.call(path ?? "api/state", path == nil ? nil : body)
            if let s = try? JSONDecoder().decode(CamState.self, from: data) {
                state = s
                tracker.zoom = s.zoom
            }
            error = nil
            serverDown = false
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .networkConnectionLost {
            serverDown = true
            error = "Panel server isn't running."
            startServer()
        } catch {
            self.error = error.localizedDescription
        }
        onIconChange?()
    }

    func post(_ path: String, _ body: [String: Any] = [:]) { Task { await run(path, body) } }

    static func findPython() -> String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Start the bundled panel server (at most once every 30 s while it's unreachable).
    func startServer() {
        let now = CACurrentMediaTime()
        guard now - lastServerStart > 30 else { return }
        lastServerStart = now
        guard let python = Model.findPython() else {
            error = "Python 3 not found. Install it (e.g. `xcode-select --install`)."
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-B", SERVER_DIR + "/server.py"]
        p.currentDirectoryURL = URL(fileURLWithPath: SERVER_DIR)
        let logPath = LOG_DIR + "/Pocket3Bar-server.log"
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        debugLog("starting panel server with \(python)")
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }

    // manual control
    func pauseTracking() { if trackMode == .on { trackMode = .paused; trackStatus = "Paused because you moved the camera." } }

    func startMove(_ dx: Double, _ dy: Double) {
        stopMove()
        pauseTracking()
        let step = { [weak self] in
            guard let self else { return }
            self.post("api/nudge", ["pan": dx * self.speed, "tilt": dy * self.speed])
        }
        step()
        moveTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            Task { @MainActor in step() }
        }
    }
    func stopMove() { moveTimer?.invalidate(); moveTimer = nil }

    func toggleHold() {
        guard let s = state else { return }
        if s.hold { setTracking(.off); post("api/release") }
        else { pauseTracking(); post("api/goto", ["pan": s.pan, "tilt": s.tilt]) }
    }
    func level() { pauseTracking(); post("api/level") }
    func preset(_ i: Int, save: Bool) {
        if save { post("api/preset/save", ["slot": i]) }
        else if state?.presets[String(i)] != nil { pauseTracking(); post("api/preset/recall", ["slot": i]) }
    }

    func setTracking(_ m: TrackMode) {
        switch m {
        case .on:
            trackStatus = "Starting camera…"
            tracker.wantTracking = true
            tracker.start { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    if let err { self.trackMode = .off; self.trackStatus = err; self.updateCamera() }
                    else { self.trackMode = .on; self.trackStatus = "Looking for a face…" }
                }
            }
        case .off:
            trackMode = .off
            face = nil
            eyes = nil
            trackStatus = ""
            updateCamera()
        case .paused:
            trackMode = .paused
        }
    }
    func toggleTracking() { setTracking(trackMode == .on ? .off : .on) }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Open at login: " + error.localizedDescription }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

}

// MARK: - Face tracking (native)

final class Tracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var model: Model?
    let session = AVCaptureSession()
    /// One preview layer for the app's lifetime. Creating/destroying layers attached to
    /// the session while it starts on the capture queue crashes AVFoundation, so the
    /// view only borrows this one.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        return l
    }()
    private let queue = DispatchQueue(label: "pocket3.tracker")
    private var configured = false
    private var frames = 0, startedAt = 0.0
    var wantPreview = false, wantTracking = false
    var onProblem: ((String?) -> Void)?    // nil = video is flowing

    // shared with the capture queue
    var mode: TrackMode = .off
    var pace: Double = 3
    var zoom: Double = 1

    // Aim the point between the eyes at the classic portrait eye line (38% from the top).
    private let EYE_Y = 0.38
    private var face: CGRect?
    private var eyes: CGPoint?
    // Degrees across the visible (16:9) picture, horizontally and vertically, at 1x zoom.
    private var spanX = 95.0, spanY = 53.0
    private var lastShape = ""    // smoothed midpoint between the pupils (normalized, top-left origin)
    private var lastSeen = 0.0, lastStep = 0.0, lastUI = 0.0
    private var busy = false, gliding = false, movingX = false, movingY = false
    private var panSign = 1.0, badPan = 0
    private var pending: (ex: Double, t: Double)?

    /// Start the camera (if not already running) for preview and/or tracking.
    func start(_ done: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else { return done("Camera access is off for Pocket3Bar. Turn it on in System Settings › Privacy & Security › Camera.") }
            self.queue.async {
                if !self.configured, let err = self.configure() { return done(err) }
                if !self.session.isRunning {
                    self.frames = 0
                    self.startedAt = CACurrentMediaTime()
                    self.session.startRunning()
                    debugLog("session started, running=\(self.session.isRunning)")
                    self.queue.asyncAfter(deadline: .now() + 3) { self.checkFlowing() }
                }
                done(nil)
            }
        }
    }

    private func checkFlowing() {
        guard session.isRunning else { return }
        debugLog("frames after 3s: \(frames)")
        if frames == 0 {
            onProblem?("No video from the Pocket 3 yet. Unplug it and plug it back in, or quit other apps using it.")
            queue.asyncAfter(deadline: .now() + 3) { self.checkFlowing() }
        }
    }

    /// Stop the camera once neither the preview nor tracking needs it.
    func stopIfUnused() {
        queue.async {
            if !self.wantTracking { self.glideStop(); self.face = nil; self.eyes = nil }
            if !self.wantPreview && !self.wantTracking && self.session.isRunning {
                self.session.stopRunning()
                debugLog("session stopped")
            }
        }
    }

    static func findPocket3() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .first { $0.localizedName.range(of: "osmo|pocket|dji", options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private func configure() -> String? {
        guard let dev = Tracker.findPocket3() else { return "Pocket 3 isn't connected as a webcam." }
        debugLog("device: \(dev.localizedName) format: \(dev.activeFormat.formatDescription)")
        session.beginConfiguration()
        // Use the camera's own current format (forcing a preset it doesn't offer
        // can leave the session running with no frames).
        guard let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else {
            session.commitConfiguration(); return "Couldn't open the Pocket 3 camera."
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let e = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            debugLog("runtime error: \(e)")
            self?.onProblem?("Camera error: " + e)
        }
        configured = true
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from conn: AVCaptureConnection) {
        frames += 1
        if frames == 1 {
            debugLog("first frame after \(String(format: "%.2f", CACurrentMediaTime() - startedAt))s")
            DispatchQueue.main.async { self.onProblem?(nil) }
        }
        guard wantTracking, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let now = CACurrentMediaTime()
        // The picture people see (this preview, and most meeting apps) is a centred 16:9
        // crop. When the Pocket 3 sends portrait video (screen turned vertical) that crop is
        // only the middle strip, so work in the crop's coordinates, not the full frame's.
        let bw = Double(CVPixelBufferGetWidth(px)), bh = Double(CVPixelBufferGetHeight(px))
        let aspect = bw / bh, wide = 16.0 / 9.0
        let hv = aspect < wide ? aspect / wide : 1, wv = aspect > wide ? wide / aspect : 1
        let top = (1 - hv) / 2, left = (1 - wv) / 2
        let portrait = bh > bw
        spanX = (portrait ? 53.0 : 95.0) * wv
        spanY = (portrait ? 95.0 : 53.0) * hv
        let shape = "\(Int(bw))x\(Int(bh))"
        if shape != lastShape { lastShape = shape; debugLog("video \(shape): tracking in the centred 16:9 crop (\(Int(spanX))° × \(Int(spanY))°)") }
        let toView = { (p: CGPoint) in CGPoint(x: (Double(p.x) - left) / wv, y: (Double(p.y) - top) / hv) }

        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: px, options: [:]).perform([req])
        let found = (req.results ?? []).map { o -> (CGRect, CGPoint) in
            let b = o.boundingBox  // normalized, bottom-left origin, full frame
            let full = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            let o0 = toView(full.origin)
            let rect = CGRect(x: o0.x, y: o0.y, width: full.width / wv, height: full.height / hv)
            let eyeFull = Tracker.eyePoint(o) ?? CGPoint(x: full.midX, y: full.minY + full.height * 0.38)
            return (rect, toView(eyeFull))
        }
        if let (f, e) = pick(found, now) {
            let a = 0.35
            if let p = face {
                face = CGRect(x: p.minX + (f.minX - p.minX) * a, y: p.minY + (f.minY - p.minY) * a,
                              width: p.width + (f.width - p.width) * a, height: p.height + (f.height - p.height) * a)
            } else { face = f }
            if let pe = eyes { eyes = CGPoint(x: pe.x + (e.x - pe.x) * a, y: pe.y + (e.y - pe.y) * a) } else { eyes = e }
            lastSeen = now
        } else if now - lastSeen > 0.8 { face = nil; eyes = nil }

        if mode == .on {
            if face != nil { checkDirection(now); step(now) } else { glideStop() }
        } else { glideStop() }

        if now - lastUI > 0.1 {
            lastUI = now
            let f = face, e = eyes, m = mode
            DispatchQueue.main.async {
                guard let model = self.model else { return }
                model.face = f
                model.eyes = e
                if m == .on { model.trackStatus = f != nil ? "Following your eyes." : "No face in view. Holding position." }
            }
        }
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// Midpoint between the pupils (or eye outlines), in normalized top-left coordinates.
    static func eyePoint(_ o: VNFaceObservation) -> CGPoint? {
        guard let lm = o.landmarks else { return nil }
        let regions = [lm.leftPupil, lm.rightPupil].compactMap { $0 }.filter { $0.pointCount > 0 }
        let use = regions.count == 2 ? regions : [lm.leftEye, lm.rightEye].compactMap { $0 }.filter { $0.pointCount > 0 }
        let pts = use.flatMap { $0.normalizedPoints }   // relative to the face box, bottom-left origin
        guard !pts.isEmpty else { return nil }
        let mx = pts.map { Double($0.x) }.reduce(0, +) / Double(pts.count)
        let my = pts.map { Double($0.y) }.reduce(0, +) / Double(pts.count)
        let b = o.boundingBox
        return CGPoint(x: Double(b.minX) + mx * Double(b.width), y: 1 - (Double(b.minY) + my * Double(b.height)))
    }

    private func pick(_ faces: [(CGRect, CGPoint)], _ now: Double) -> (CGRect, CGPoint)? {
        guard !faces.isEmpty else { return nil }
        if let f = face, now - lastSeen < 1.5 {
            let c = center(f)
            return faces.min { hypot(center($0.0).x - c.x, center($0.0).y - c.y) < hypot(center($1.0).x - c.x, center($1.0).y - c.y) }
        }
        return faces.max { $0.0.width * $0.0.height < $1.0.width * $1.0.height }
    }

    // Glide: speed proportional to how far the face is off-centre; the server eases it.
    private func step(_ now: Double) {
        guard let e = eyes, !busy, now - lastStep >= 0.1 else { return }
        let ex = Double(e.x) - 0.5, ey = Double(e.y) - EYE_Y
        let START = 0.07, STOP = 0.025
        movingX = abs(ex) > (movingX ? STOP : START)
        movingY = abs(ey) > (movingY ? STOP : START * 1.3)
        let gain = 0.5 + pace * 0.3, vmax = 6 + pace * 6
        let lim = { (x: Double) in max(-vmax, min(vmax, x)) }
        let vpan = movingX ? panSign * lim(ex * (spanX / zoom) * gain) : 0
        let vtilt = movingY ? lim(-ey * (spanY / zoom) * gain) : 0
        if vpan == 0 && vtilt == 0 && !gliding { return }
        gliding = vpan != 0 || vtilt != 0
        lastStep = now
        busy = true
        if vpan != 0 && pending == nil { pending = (ex, now) }
        API.send("api/glide", ["pan": vpan, "tilt": vtilt]) { [weak self] in self?.queue.async { self?.busy = false } }
    }

    private func glideStop() {
        guard gliding else { return }
        gliding = false; movingX = false; movingY = false
        API.send("api/glide", ["pan": 0, "tilt": 0])
    }

    // If panning keeps pushing the face further off-centre, the image is mirrored.
    private func checkDirection(_ now: Double) {
        guard let p = pending, now - p.t >= 0.6, let e = eyes else { return }
        let ex = Double(e.x) - 0.5
        if abs(p.ex) > 0.1 && (ex > 0) == (p.ex > 0) && abs(ex) > abs(p.ex) + 0.03 { badPan += 1 } else { badPan = 0 }
        pending = nil
        if badPan >= 4 { panSign = -panSign; badPan = 0 }
    }
}

// MARK: - UI

final class PreviewNSView: NSView {
    let preview: AVCaptureVideoPreviewLayer
    init(layer shared: AVCaptureVideoPreviewLayer) {
        preview = shared
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.removeFromSuperlayer()
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false   // keep it unmirrored so the face box lines up
        }
    }
}

struct Preview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(layer: layer) }
    func updateNSView(_ v: PreviewNSView, context: Context) { v.needsLayout = true }
}

struct PressButton: View {
    let symbol: String
    let action: (Bool) -> Void   // true = pressed, false = released
    @State private var down = false
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 38, height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(down ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; action(true) } }
                .onEnded { _ in down = false; action(false) })
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct PanelView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let s = m.state {
                preview
                tracking
                Divider()
                gimbal(s)
                Divider()
                lens(s)
                Divider()
                presets(s)
            } else {
                Text(m.serverDown ? "Starting the panel server…" : (m.error ?? "Connecting…"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let e = m.error, m.state != nil {
                Text(e).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    var header: some View {
        HStack {
            Circle().fill(m.state != nil && m.error == nil ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text("Pocket 3").font(.headline)
            Spacer()
            if let s = m.state {
                Text(s.facing == "selfie" ? "Selfie" : "Front-facing").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PREVIEW").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $m.previewOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            if m.previewOn || m.trackMode != .off {
                ZStack(alignment: .topLeading) {
                    Color.black
                    Preview(layer: m.tracker.previewLayer)
                    GeometryReader { g in
                        if m.trackMode != .off {
                            let c: Color = m.trackMode == .on ? .green : .orange
                            // where the eyes are being placed: the portrait eye line
                            Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1)
                                .offset(y: 0.38 * g.size.height)
                            if let f = m.face {
                                Rectangle().stroke(c.opacity(0.6), lineWidth: 1.5)
                                    .frame(width: f.width * g.size.width, height: f.height * g.size.height)
                                    .offset(x: f.minX * g.size.width, y: f.minY * g.size.height)
                            }
                            if let e = m.eyes {
                                Circle().fill(c).frame(width: 8, height: 8)
                                    .offset(x: e.x * g.size.width - 4, y: e.y * g.size.height - 4)
                            }
                        }
                    }
                    if let p = m.videoProblem {
                        Text(p).font(.caption).foregroundStyle(.white).padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 288, height: 162)   // 16:9; popovers give flexible views no height
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    var tracking: some View {
        Section(title: "Face tracking") {
            Button(action: { m.toggleTracking() }) {
                Text(m.trackMode == .on ? "Tracking on" : m.trackMode == .paused ? "Tracking paused · resume" : "Tracking off")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(m.trackMode == .on ? .green : m.trackMode == .paused ? .orange : nil)
            .buttonStyle(.borderedProminent)
            if !m.trackStatus.isEmpty {
                Text(m.trackStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Pace").font(.caption)
                Slider(value: $m.pace, in: 1...5, step: 1)
                Text("\(Int(m.pace))").font(.caption.monospacedDigit()).frame(width: 18)
            }
        }
    }

    func gimbal(_ s: CamState) -> some View {
        Section(title: "Gimbal") {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 4) {
                    PressButton(symbol: "chevron.up") { $0 ? m.startMove(0, 1) : m.stopMove() }
                    HStack(spacing: 4) {
                        PressButton(symbol: "chevron.left") { $0 ? m.startMove(-1, 0) : m.stopMove() }
                        Button(action: { m.level() }) { Text("Level").font(.caption2) }
                            .buttonStyle(.plain).frame(width: 38, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
                        PressButton(symbol: "chevron.right") { $0 ? m.startMove(1, 0) : m.stopMove() }
                    }
                    PressButton(symbol: "chevron.down") { $0 ? m.startMove(0, -1) : m.stopMove() }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: { m.toggleHold() }) {
                        Text(s.hold ? "Holding" : "Released").frame(maxWidth: .infinity)
                    }
                    .tint(s.hold ? .accentColor : nil)
                    .buttonStyle(.borderedProminent)
                    Text(s.hold ? "Stays where you point it." : "Camera follows on its own.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Text("Step").font(.caption)
                        Slider(value: $m.speed, in: 1...10, step: 1)
                        Text("\(Int(m.speed))°").font(.caption.monospacedDigit()).frame(width: 24)
                    }
                    Text("Pan \(Int(s.pan.rounded()))°  ·  Tilt \(Int(s.tilt.rounded()))°")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    func lens(_ s: CamState) -> some View {
        Section(title: "Lens") {
            HStack {
                Text("Zoom").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(get: { m.zoomDraft ?? s.zoom },
                                      set: { m.zoomDraft = $0; m.post("api/zoom", ["zoom": $0]) }),
                       in: s.ranges.zoom[0]...max(s.ranges.zoom[1], s.ranges.zoom[0] + 0.1), step: 0.1,
                       onEditingChanged: { if !$0 { m.zoomDraft = nil } })
                Text(String(format: "%.1f×", m.zoomDraft ?? s.zoom)).font(.caption.monospacedDigit()).frame(width: 34)
                Button("1×") { m.post("api/zoom", ["zoom": 1]) }.controlSize(.small)
            }
            HStack {
                Text("Roll").font(.caption).frame(width: 34, alignment: .leading)
                Slider(value: Binding(get: { m.rollDraft ?? s.roll },
                                      set: { m.rollDraft = $0; m.post("api/roll", ["roll": Int($0)]) }),
                       in: s.ranges.roll[0]...max(s.ranges.roll[1], s.ranges.roll[0] + 1), step: 1,
                       onEditingChanged: { if !$0 { m.rollDraft = nil } })
                Text("\(Int(m.rollDraft ?? s.roll))°").font(.caption.monospacedDigit()).frame(width: 34)
                Button("0°") { m.post("api/roll", ["roll": 0]) }.controlSize(.small)
            }
        }
    }

    func presets(_ s: CamState) -> some View {
        Section(title: "Presets") {
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { i in
                    let p = s.presets[String(i)]
                    Button(action: { m.preset(i, save: NSEvent.modifierFlags.contains(.option)) }) {
                        Text(p != nil ? "\(i)" : "\(i) ·").frame(maxWidth: .infinity)
                    }
                    .help(p.map { "Pan \(Int($0.pan))°, tilt \(Int($0.tilt))°, \($0.zoom)× · ⌥-click to overwrite" }
                          ?? "Empty · ⌥-click to save the current view")
                    .opacity(p != nil ? 1 : 0.55)
                }
            }
            Text("Click to recall · ⌥-click to save").font(.caption2).foregroundStyle(.secondary)
        }
    }

    var footer: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open at login", isOn: Binding(get: { m.openAtLogin }, set: { m.setOpenAtLogin($0) }))
                Toggle("Open when a meeting starts", isOn: $m.autoOpen)
            }
            .toggleStyle(.checkbox).font(.caption)
            Spacer()
            Button("Web panel") { NSWorkspace.shared.open(BASE) }.controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }.controlSize(.small)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover = NSPopover()
    var model: Model!

    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            model = Model()
            model.onIconChange = { [weak self] in self?.updateIcon() }
            model.onMeetingStart = { [weak self] in self?.show() }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PanelView(m: model))
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.popoverOpen = false }
        }
        updateIcon()
    }

    func updateIcon() {
        MainActor.assumeIsolated {
            let name: String
            if model.state == nil || model.error != nil { name = "video.slash" }
            else if model.trackMode == .on { name = "person.crop.square.badge.video" }
            else { name = "video" }
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Pocket 3")
                ?? NSImage(systemSymbolName: "video", accessibilityDescription: "Pocket 3")
            img?.isTemplate = true
            item?.button?.image = img
            item?.button?.toolTip = model.trackMode == .on ? "Pocket 3 · tracking" : "Pocket 3"
        }
    }

    @objc func toggle() { popover.isShown ? popover.performClose(nil) : show() }

    func show() {
        guard let b = item.button, !popover.isShown else { return }
        MainActor.assumeIsolated { model.popoverOpen = true; model.refresh() }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    @objc func handleURL(_ e: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let url = e.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        if url.hasPrefix("pocket3bar://show") { DispatchQueue.main.async { self.show() } }
        if url.hasPrefix("pocket3bar://track") {
            let on = !url.hasSuffix("off")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.setTracking(on ? .on : .off) } }
        }
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
