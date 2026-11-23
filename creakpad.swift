// creakpad
//
// Move your MacBook's lid and the trackpad creaks like an old door. Close it and it begs. Open it again and
// it sulks. No speaker involved: every sound comes from the trackpad's haptic motor, driven through
// MultitouchSupport (a private macOS framework).
//
//   creakpad              start it here, mute your Mac, move the lid. Ctrl-C to stop.
//   creakpad setup        choose its voice and what it says
//   creakpad on           run it in the background, now and at every login
//   creakpad off          stop it, and stop starting at login
//   creakpad --selftest   check the hinge maths without any hardware
//
// The motor and the voice are nospeaker's, by Cody Collier (MIT, github.com/os6/nospeaker).
// Where the lid angle lives comes from LidAngleSensor by Sam Henri Gold (github.com/samhenrigold/LidAngleSensor).
//
// Private API: MultitouchSupport is undocumented and may change with any macOS update. The motor is never
// driven past its normal maximum.

import AVFoundation
import Darwin
import Foundation
import IOKit
import IOKit.hid

// MARK: - Knobs

let creakMinSpeed = 4.0      // °/s below which the hinge stays silent (the sensor's flicker at rest stays under 3.2)
let creakLoudSpeed = 12.0    // °/s at which the creak reaches full strength
let creakLowHz = 45.0        // creak pitch when the lid moves slowly
let creakHighHz = 170.0      // creak pitch at 90°/s and faster
// The voice and the lines are options (--voice, --lines, --sulk): see the Main section.

// MARK: - The hinge

/// The lid's angle and speed. The sensor reports whole degrees and flickers between two neighbours at rest,
/// so the speed is the slope of a line fitted to the last 0.4 s of readings: the flicker averages out, and
/// slow movement still shows.
struct Hinge {
    static let window = 0.4
    private var samples: [(t: Double, angle: Double)] = []
    private(set) var angle = 0.0
    private(set) var velocity = 0.0    // °/s, negative while closing

    /// Adds a reading.
    /// @param angle - the lid angle in degrees
    /// @param t - when it was read, in seconds
    mutating func add(_ angle: Double, at t: Double) {
        self.angle = angle
        samples.append((t, angle))
        samples.removeAll { t - $0.t > Self.window }
        // Too short a history and a single one-degree flicker looks like a fast move.
        guard t - samples[0].t >= Self.window * 0.75 else { velocity = 0; return }
        let n = Double(samples.count)
        let meanT = samples.reduce(0) { $0 + $1.t } / n
        let meanA = samples.reduce(0) { $0 + $1.angle } / n
        let cov = samples.reduce(0) { $0 + ($1.t - meanT) * ($1.angle - meanA) }
        let spread = samples.reduce(0) { $0 + ($1.t - meanT) * ($1.t - meanT) }
        velocity = spread > 0 ? cov / spread : 0
    }
}

/// Checks the hinge on made-up readings: silent at rest despite flicker, right speed when moving.
func selfTest() -> Never {
    /// The speeds read while feeding `angle(t)`, rounded like the sensor, 50 times a second for 3 s.
    func speeds(_ angle: (Double) -> Double) -> [Double] {
        var hinge = Hinge()
        return (0..<150).map { i in
            let t = Double(i) * 0.02
            hinge.add(angle(t).rounded(), at: t)
            return abs(hinge.velocity)
        }
    }
    // At rest between 103° and 104°, flipping every 60 ms: worse than the real sensor (about every 150 ms).
    let rest = speeds { t in 103 + Double(Int(t / 0.06) % 2) }.max()!
    guard rest < creakMinSpeed else { fail("selftest: flicker at rest reads as \(rest)°/s") }
    for speed in [8.0, 20, 60, 150] {
        let settled = speeds { t in 20 + speed * t }.filter { $0 > 0 }    // once the history is long enough
        guard !settled.isEmpty, settled.allSatisfy({ $0 > speed * 0.75 && $0 < speed * 1.25 }) else {
            fail("selftest: \(speed)°/s reads as \(settled.min() ?? 0) to \(settled.max() ?? 0)°/s")
        }
    }
    print("selftest: ok (rest peaks at \(String(format: "%.1f", rest))°/s)")
    exit(0)
}

// MARK: - The lid angle sensor (Apple HID 0x8104, Sensor page 0x20, Orientation usage 0x8A)

// Kept for the whole run: releasing the manager closes the devices opened through it.
let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

/// Finds and opens the lid angle sensor.
/// @returns the open HID device
func openLid() -> IOHIDDevice {
    let none = IOOptionBits(kIOHIDOptionsTypeNone)
    IOHIDManagerSetDeviceMatching(hidManager, [
        kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104, "UsagePage": 0x0020, "Usage": 0x008A,
    ] as CFDictionary)
    _ = IOHIDManagerOpen(hidManager, none)
    // The matching also returns the accelerometer and gyroscope: the lid is the one that answers report 1.
    for device in (IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice>) ?? []
    where IOHIDDeviceOpen(device, none) == kIOReturnSuccess {
        if readAngle(device) != nil { return device }
        IOHIDDeviceClose(device, none)
    }
    fail("This Mac has no lid angle sensor it can read. It needs a MacBook Pro 16\" (2019) or later, or most Apple silicon MacBooks.")
}

/// Reads the lid angle.
/// @param device - the open sensor
/// @returns the angle in whole degrees (0 is shut), or nil when the read fails
func readAngle(_ device: IOHIDDevice) -> Double? {
    var report = [UInt8](repeating: 0, count: 8)
    var length = CFIndex(report.count)
    guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
          length >= 3 else { return nil }
    return Double(UInt16(report[2]) << 8 | UInt16(report[1]))
}

// MARK: - Clock and exit

var stopRequested = false

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
let t0 = mach_absolute_time()
func now() -> Double { Double(mach_absolute_time() - t0) / ticksPerSecond }

/// Waits for a moment on the clock: sleeps, and spins only for the last ~1.5 ms.
/// @param t - the moment, in mach ticks
func waitUntil(_ t: UInt64) {
    let margin = UInt64(0.0015 * ticksPerSecond)
    while !stopRequested {
        let n = mach_absolute_time()
        if n >= t { return }
        if t - n > margin { usleep(useconds_t(Double(t - n - margin) / ticksPerSecond * 1e6)) }
    }
}

/// Stops with a plain explanation.
/// @param message - what went wrong and what to do
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\n  creakpad: \(message)\n\n".utf8))
    exit(1)
}

// MARK: - The haptic motor (from nospeaker)

let mt = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
func sym<T>(_ name: String, _: T.Type) -> T? {
    guard let mt, let p = dlsym(mt, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
typealias GetID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
typealias ActuatorCreate = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
typealias ActuatorOpen = @convention(c) (CFTypeRef) -> Int32
typealias ActuatorClose = @convention(c) (CFTypeRef) -> Int32
typealias ActuationCreate = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
typealias ActuationPlay = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

let createList = sym("MTDeviceCreateList", CreateList.self)
let getID = sym("MTDeviceGetDeviceID", GetID.self)
let isBuiltIn = sym("MTDeviceIsBuiltIn", IsBuiltIn.self)
let actuatorCreate = sym("MTActuatorCreateFromDeviceID", ActuatorCreate.self)
let actuatorOpen = sym("MTActuatorOpen", ActuatorOpen.self)
let actuatorClose = sym("MTActuatorClose", ActuatorClose.self)
let actuationCreate = sym("MTActuationCreateFromDictionary", ActuationCreate.self)
let actuationPlay = sym("MTActuationActuate", ActuationPlay.self)

/// Opens the haptic motor of the built-in trackpad (or a Force Touch Magic Trackpad).
/// @returns the open actuator
func openMotor() -> CFTypeRef {
    guard let createList, let getID, let actuatorCreate, let actuatorOpen, actuationCreate != nil, actuationPlay != nil else {
        fail("This version of macOS doesn't have the trackpad functions this needs.")
    }
    guard let list = createList()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { fail("No trackpad was found.") }
    var ids: [(id: UInt64, builtIn: Bool)] = []
    for i in 0..<CFArrayGetCount(list) {
        guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
        let dev = UnsafeMutableRawPointer(mutating: raw)
        var id: UInt64 = 0
        if getID(dev, &id) == 0 { ids.append((id, isBuiltIn?(dev) ?? false)) }
    }
    for d in ids.sorted(by: { $0.builtIn && !$1.builtIn }) {
        if let ref = actuatorCreate(d.id)?.takeRetainedValue(), actuatorOpen(ref) == 0 { return ref }
    }
    fail("Found a trackpad, but it has no haptic motor (Force Touch), so it can't make sound.")
}

var motorPointer: UnsafeMutableRawPointer?

/// Plays tones together on the motor.
/// @param tones - frequencies in Hz with their relative strength (scaled to add up to 1)
/// @param ms - how long, in milliseconds
/// @param level - overall strength, 0 to 1
func play(_ tones: [(hz: Double, amp: Double)], ms: Double, level: Float) {
    guard let motorPointer, !tones.isEmpty else { return }
    let sum = max(tones.reduce(0) { $0 + $1.amp }, 0.0001)
    let shape: [String: Any] = [
        "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": ms],
        "Tones": tones.map { ["Type": "Sine", "Amplitude": $0.amp / sum, "DurationMS": ms, "DelayMS": 0.0, "FrequencykHz": $0.hz / 1000] },
    ]
    guard let act = actuationCreate!(shape as CFDictionary, 0) else { return }
    _ = actuationPlay!(act, motorPointer, 0, min(1, max(0, level)), 0)
    Unmanaged<AnyObject>.fromOpaque(act).release()
}

// MARK: - The voice (from nospeaker): `say` into memory, then two formants retriggered on every pitch beat

struct Frame {
    var formants: [Double] = [500, 1500, 2500]
    var amps: [Double] = [1, 0.5, 0.25]
    var level: Float = 0
    var voiced = false
    var f0 = 110.0
}
let hop = 0.010
let sampleRate = 16000.0

/// Speaks a line with macOS's voice and turns it into motor frames.
/// @param text - the line
/// @returns its frames, 10 ms apart
func render(_ text: String) -> [Frame] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("creakpad-\(getpid()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", "-v", voice, text]
    do { try p.run() } catch { fail("It couldn't run macOS's voice (/usr/bin/say).") }
    p.waitUntilExit()
    guard p.terminationStatus == 0, let file = try? AVAudioFile(forReading: url),
          let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData?[0] else {
        fail("macOS's voice (say) couldn't speak \"\(text)\".")
    }
    var f = analyse(Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))))
    while let first = f.first, first.level == 0 { f.removeFirst() }
    while let last = f.last, last.level == 0 { f.removeLast() }
    return f
}

func lpc(_ x: [Double], order p: Int) -> ([Double], Double) {
    var r = [Double](repeating: 0, count: p + 1)
    for k in 0...p { var s = 0.0; for i in k..<x.count { s += x[i] * x[i - k] }; r[k] = s }
    var a = [Double](repeating: 0, count: p + 1); a[0] = 1
    guard r[0] > 1e-12 else { return (a, 0) }
    r[0] *= 1.0001
    var e = r[0]
    for i in 1...p {
        var acc = r[i]
        for j in 1..<i { acc += a[j] * r[i - j] }
        let k = -acc / e
        var na = a
        for j in 1..<i { na[j] = a[j] + k * a[i - j] }
        na[i] = k
        a = na
        e *= 1 - k * k
    }
    return (a, e)
}

struct C {
    var re: Double, im: Double
    static func + (l: C, r: C) -> C { C(re: l.re + r.re, im: l.im + r.im) }
    static func - (l: C, r: C) -> C { C(re: l.re - r.re, im: l.im - r.im) }
    static func * (l: C, r: C) -> C { C(re: l.re * r.re - l.im * r.im, im: l.re * r.im + l.im * r.re) }
    static func / (l: C, r: C) -> C {
        let d = r.re * r.re + r.im * r.im
        return C(re: (l.re * r.re + l.im * r.im) / d, im: (l.im * r.re - l.re * r.im) / d)
    }
}

func roots(_ a: [Double]) -> [C] {
    let p = a.count - 1
    var z = (0..<p).map { k -> C in
        let ang = 2 * Double.pi * Double(k) / Double(p) + 0.4
        return C(re: 0.9 * cos(ang), im: 0.9 * sin(ang))
    }
    func poly(_ x: C) -> C { var s = C(re: 1, im: 0); for k in 1...p { s = s * x + C(re: a[k], im: 0) }; return s }
    for _ in 0..<300 {
        var moved = 0.0
        for i in 0..<p {
            var d = C(re: 1, im: 0)
            for j in 0..<p where j != i { d = d * (z[i] - z[j]) }
            if d.re == 0 && d.im == 0 { d = C(re: 1e-12, im: 0) }
            let step = poly(z[i]) / d
            z[i] = z[i] - step
            moved = max(moved, abs(step.re) + abs(step.im))
        }
        if moved < 1e-10 { break }
    }
    return z
}

func analyse(_ x: [Float]) -> [Frame] {
    let win = Int(0.025 * sampleRate), hopN = Int(hop * sampleRate), order = 18
    let hamming = (0..<win).map { 0.54 - 0.46 * cos(2 * .pi * Double($0) / Double(win - 1)) }
    var frames: [Frame] = [], rmsList: [Double] = []
    var prev = Frame()
    var i = 0
    while i + win <= x.count {
        let seg = (0..<win).map { Double(x[i + $0]) }
        rmsList.append(sqrt(seg.reduce(0) { $0 + $1 * $1 } / Double(win)))
        var f = prev
        var zc = 0
        for k in 1..<win where (seg[k] >= 0) != (seg[k - 1] >= 0) { zc += 1 }
        var bestLag = 0, bestR = 0.0
        for lag in Int(sampleRate / 300)...Int(sampleRate / 70) where lag < win - 40 {
            var s = 0.0, ea = 0.0, eb = 0.0
            for k in 0..<(win - lag) { s += seg[k] * seg[k + lag]; ea += seg[k] * seg[k]; eb += seg[k + lag] * seg[k + lag] }
            let r = s / max(sqrt(ea * eb), 1e-12)
            if r > bestR { bestR = r; bestLag = lag }
        }
        f.voiced = bestR > 0.35 && Double(zc) / Double(win) < 0.22
        if f.voiced, bestLag > 0 { f.f0 = sampleRate / Double(bestLag) }
        var pe = [Double](repeating: 0, count: win)
        for k in 0..<win { pe[k] = (seg[k] - 0.97 * (k > 0 ? seg[k - 1] : 0)) * hamming[k] }
        let (a, err) = lpc(pe, order: order)
        var cands: [Double] = []
        if err > 0 {
            for z in roots(a) where z.im > 0 {
                let hz = atan2(z.im, z.re) * sampleRate / (2 * .pi)
                let bw = -log(max(1e-9, sqrt(z.re * z.re + z.im * z.im))) * sampleRate / .pi
                if hz > 150, hz < 4200, bw < 500 { cands.append(hz) }
            }
        }
        func pick(_ lo: Double, _ hi: Double, near: Double) -> Double? {
            cands.filter { $0 >= lo && $0 <= hi }.min { abs($0 - near) < abs($1 - near) }
        }
        if let f1 = pick(200, 1000, near: prev.formants[0]) { f.formants[0] = f1 }
        if let f2 = pick(max(f.formants[0] + 200, 650), 2700, near: prev.formants[1]) { f.formants[1] = f2 }
        if let f3 = pick(max(f.formants[1] + 300, 1700), 3900, near: prev.formants[2]) { f.formants[2] = f3 }
        if err > 0 {
            f.amps = f.formants.map { hz in
                let w = 2 * Double.pi * hz / sampleRate
                var re = 0.0, im = 0.0
                for k in 0...order { re += a[k] * cos(w * Double(k)); im -= a[k] * sin(w * Double(k)) }
                return 1 / max(sqrt(re * re + im * im), 1e-6)
            }
        }
        frames.append(f)
        prev = f
        i += hopN
    }
    let peak = rmsList.max() ?? 1
    for k in frames.indices {
        let rel = rmsList[k] / max(peak, 1e-9)
        frames[k].level = rel < 0.02 ? 0 : Float(min(1, pow(rel, 0.45)))
        if frames[k].level == 0 { frames[k].voiced = false }
    }
    func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
    let raw = frames
    for k in frames.indices {
        let lo = max(0, k - 2), hi = min(frames.count - 1, k + 2)
        for j in 0..<3 { frames[k].formants[j] = median((lo...hi).map { raw[$0].formants[j] }) }
        frames[k].f0 = min(250, max(70, median((lo...hi).map { raw[$0].f0 })))
    }
    return frames
}

/// A voiced frame as two tones, F1 and F2.
func voiceTones(_ f: Frame) -> [(hz: Double, amp: Double)] {
    let w = [f.amps[0], f.amps[1] * 1.8]
    let sum = max(w[0] + w[1], 1e-9)
    return [(f.formants[0], w[0] / sum), (f.formants[1], w[1] / sum)]
}

/// Says a rendered line on the motor. Blocks until it's done.
/// @param frames - the line, from render()
func talk(_ frames: [Frame]) {
    let start = mach_absolute_time()
    let total = Double(frames.count) * hop
    var t = 0.0
    while t < total && !stopRequested {
        let f = frames[min(frames.count - 1, Int(t / hop))]
        var step = 0.005
        if f.level > 0 {
            if f.voiced {
                step = 1 / f.f0
                play(voiceTones(f), ms: step * 1000, level: f.level)
            } else {
                step = 0.004
                play((0..<3).map { _ in (Double.random(in: 2700...4300), 1.0) }, ms: step * 1000, level: f.level * 0.7)
            }
        }
        t += step
        waitUntil(start + UInt64(t * ticksPerSecond))
    }
}

// MARK: - The creak

var grain = 1.0    // the wood's colour, drifting slowly so no two creaks sound the same

/// Plays one beat of the creak. A creaky hinge is stick-slip: the wood grips and slips, an irregular buzz
/// whose pitch climbs with speed and whose colour shifts along the hinge.
/// @param speed - how fast the lid moves, in °/s
/// @param angle - where the lid is, in degrees
/// @returns seconds until the next beat
func creak(speed: Double, angle: Double) -> Double {
    let fast = min(1, speed / 90)
    let hz = (creakLowHz + (creakHighHz - creakLowHz) * fast) * Double.random(in: 0.75...1.25)
    grain = min(1.3, max(0.7, grain + Double.random(in: -0.04...0.04)))
    let body = (300 + angle * 2) * grain
    let level = min(1, speed / creakLoudSpeed) * (1 - 0.4 * fast) * Double.random(in: 0.5...1)
    if Double.random(in: 0...1) > 0.12 {    // now and then the wood sticks and skips a beat
        play([(body, 1), (body * 2.6, 0.5)], ms: 600 / hz, level: Float(level))
    }
    return 1 / hz
}

// MARK: - Settings (asked by `creakpad setup`, kept in ~/Library/Preferences)

let appID = "com.github.benoitded.creakpad"
let settings = UserDefaults(suiteName: appID)!
let voice = settings.string(forKey: "voice") ?? "Fred"
let lines = settings.stringArray(forKey: "lines") ?? ["wait", "no no no", "nooo!"]
let sulk = settings.string(forKey: "sulk") ?? "rude."
// The closing lines, spread from 50° down to 16°, each said once per closing.
let begging = lines.enumerated().map { i, line in
    (below: lines.count == 1 ? 50 : 50 - 34 * Double(i) / Double(lines.count - 1), line: line)
}

/// True if macOS has a voice by this name (`say` quietly falls back to the default voice otherwise).
/// @param name - the voice, like "Fred"
func voiceExists(_ name: String) -> Bool {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-v", "?"]
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return true }    // can't check: let `say` decide
    let list = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
    p.waitUntilExit()
    return list.split(separator: "\n").contains { $0.hasPrefix(name.lowercased() + " ") }
}

/// Asks a question in the terminal.
/// @param question - the question
/// @param current - the answer kept when they just press Enter
/// @returns the answer
func ask(_ question: String, _ current: String) -> String {
    print("\n\(question)\n  [\(current)] › ", terminator: "")
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
    return answer.isEmpty ? current : answer
}

/// Asks for the voice, the lines and whether to start at login, saves them, then exits.
func setup() -> Never {
    print("creakpad setup. Press Enter to keep what's in brackets.")
    var newVoice = ask("Which voice? Try Fred, Daniel or Samantha, or Thomas and Amélie for French.", voice)
    while !voiceExists(newVoice) {
        print("  There's no voice called \"\(newVoice)\" on this Mac.")
        newVoice = ask("Which voice?", voice)
    }
    let newLines = ask("What does it say while you close the lid? Separate the lines with commas.", lines.joined(separator: ", "))
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let newSulk = ask("And when you open it again?", sulk)
    settings.set(newVoice, forKey: "voice")
    settings.set(newLines.isEmpty ? lines : newLines, forKey: "lines")
    settings.set(newSulk, forKey: "sulk")
    settings.synchronize()

    let isOn = FileManager.default.fileExists(atPath: agentPath)
    let always = ask("Keep it running, even after a restart? (yes or no)", isOn ? "yes" : "no").lowercased()
    let on = always.hasPrefix("y") || always.hasPrefix("o")    // yes, oui
    if on || isOn { switchBackground(on: on) }    // restarts the background copy with the new lines
    print("\nSaved. Start it with: \(meShort)")
    exit(0)
}

// MARK: - On and off (a LaunchAgent, so it also starts at every login)

let agentPath = NSHomeDirectory() + "/Library/LaunchAgents/\(appID).plist"
let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
let meShort = me.replacingOccurrences(of: NSHomeDirectory(), with: "~")

/// Runs launchctl quietly.
/// @param args - its arguments
/// @returns true when it succeeded
@discardableResult
func launchctl(_ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// Turns the background creak on (now and at every login) or off, then exits.
/// @param on - true to turn it on
func switchBackground(on: Bool) -> Never {
    let domain = "gui/\(getuid())"
    launchctl(["bootout", "\(domain)/\(appID)"])    // stop any copy already running
    guard on else {
        try? FileManager.default.removeItem(atPath: agentPath)
        print("\ncreakpad: off. It won't start by itself any more.")
        exit(0)
    }
    _ = openLid()    // fail here, in the terminal, rather than silently in the background
    let agent: [String: Any] = ["Label": appID, "ProgramArguments": [me], "RunAtLoad": true]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0),
          (try? FileManager.default.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)) != nil,
          FileManager.default.createFile(atPath: agentPath, contents: data),
          launchctl(["bootstrap", domain, agentPath]) else {
        fail("It couldn't set itself up to run in the background (\(agentPath)).")
    }
    print("\ncreakpad: on. It creaks in the background now, and starts by itself every time you log in.\nTo stop it: \(meShort) off")
    exit(0)
}

// MARK: - The terminal

let gaugeWidth = 39    // one character per 130/39 ≈ 3.3°, wide open at the right

/// The lid as a bar, with the begging thresholds marked on it.
/// @param angle - the lid angle
/// @returns e.g. `▕██████████████████:::·····▏`
func gauge(_ angle: Double) -> String {
    let filled = Int(min(130, max(0, angle)) / 130 * Double(gaugeWidth))
    let marks = Set(begging.map { Int($0.below / 130 * Double(gaugeWidth)) })
    let cells = (0..<gaugeWidth).map { i in i < filled ? "█" : marks.contains(i) ? "┊" : "·" }
    return "▕" + cells.joined() + "▏"
}

/// Redraws the live line.
/// @param angle - the lid angle
/// @param state - what is happening, in a few words
func status(_ angle: Double, _ state: String) {
    print("\r  \(gauge(angle)) \(String(format: "%3d", Int(angle)))°  \(state.padding(toLength: 20, withPad: " ", startingAt: 0))", terminator: "")
}

/// Says a line, and keeps it in the terminal above the live line.
/// @param line - the words
/// @param frames - the line, from render()
/// @param angle - the lid angle when it's said
func say(_ line: String, _ frames: [Frame], at angle: Double) {
    status(angle, "\"\(line)\"")
    print("")
    talk(frames)
}

// MARK: - Main

let usage = """
creakpad: your MacBook's lid creaks through the trackpad.

  creakpad          start it here (Ctrl-C to stop)
  creakpad setup    choose its voice and what it says
  creakpad on       keep it running, even after a restart
  creakpad off      stop it for good
"""

switch CommandLine.arguments.dropFirst().first {
case nil: break
case "setup": setup()
case "on": switchBackground(on: true)
case "off": switchBackground(on: false)
case "--selftest": selfTest()
case "help", "--help", "-h": print(usage); exit(0)
case let other?: fail("it doesn't know \"\(other)\".\n\n\(usage)")
}

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGINT) { _ in stopRequested = true }
signal(SIGTERM) { _ in stopRequested = true }    // `creakpad off` stops the background copy this way

let lid = openLid()
let motor = openMotor()
motorPointer = Unmanaged.passUnretained(motor as AnyObject).toOpaque()

print("\n  creakpad: warming up its voice…")
let beggingFrames = begging.map { render($0.line) }
let sulkFrames = render(sulk)
print("""
  creakpad: ready. Mute your Mac, then move the lid slowly.

            stop it                    Ctrl-C
            choose what it says        \(meShort) setup
            keep it running always     \(meShort) on

""")

var hinge = Hinge()
var lastRead = now(), lastPrint = 0.0
var said = Set<Int>()       // begging lines already said during this closing
var wasShut = false

while !stopRequested {
    let t = now()
    if t - lastRead >= 0.02, let angle = readAngle(lid) {
        if t - lastRead > 3, hinge.angle < 30 { wasShut = true }    // the Mac slept, so the lid was shut
        lastRead = t
        hinge.add(angle, at: t)
        if angle < 8 { wasShut = true }
        if angle > 60 { said.removeAll() }

        if wasShut, angle > 25 {
            wasShut = false
            say(sulk, sulkFrames, at: angle)
            continue
        }
        if hinge.velocity < -creakMinSpeed,
           let i = begging.indices.first(where: { angle < begging[$0].below && !said.contains($0) }) {
            said.formUnion(0...i)    // skip the lines the lid already went past
            say(begging[i].line, beggingFrames[i], at: angle)
            continue
        }
        if t - lastPrint > 0.1 {
            lastPrint = t
            status(angle, abs(hinge.velocity) < creakMinSpeed ? "quiet" : hinge.velocity < 0 ? "▼ creeeak" : "▲ creeeak")
        }
    }
    let speed = abs(hinge.velocity)
    if speed < creakMinSpeed { usleep(5000); continue }
    waitUntil(mach_absolute_time() + UInt64(creak(speed: speed, angle: hinge.angle) * ticksPerSecond))
}

print("\n")
_ = actuatorClose?(motor)
