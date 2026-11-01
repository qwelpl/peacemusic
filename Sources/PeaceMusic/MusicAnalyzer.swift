import AudioToolbox
import CoreAudio
import Foundation
import os

/// Follows one frequency band, always relative to the recent signal because tracks are
/// mastered at very different levels.
private struct BandTracker {
    private var smooth: Float = 0
    private var average: Float = 0
    private var previous: Float = 0
    private var peak: Float = 0.001
    private var sinceOnset = 1.0

    private(set) var level: Float = 0

    /// Returns whether this hop is a new hit.
    mutating func update(
        _ value: Float, hop: Double, isWarmingUp: Bool, ratio: Float, minimumGap: Double, silence: Float
    ) -> Bool {
        sinceOnset += hop
        peak = max(peak * 0.9995, value)
        smooth += (value >= smooth ? 0.6 : 0.1) * (value - smooth)
        // Measured from the running average, so a dense mix still pumps and doesn't just sit high.
        let floor = average * 0.6
        level = min(max((smooth - floor) / max(peak - floor, 0.001), 0), 1)

        var isHit = false
        if isWarmingUp {
            average += (value - average) * 0.2
        } else {
            isHit = value > silence && value > previous && value > average * ratio && sinceOnset >= minimumGap
            if isHit { sinceOnset = 0 }
            average += (value - average) * 0.02
        }
        previous = value
        return isHit
    }
}

/// Splits samples into bass, mids and highs and finds hits in them.
final class MusicDetector {
    private static let hopSeconds = 0.0116
    private static let silence: Float = 0.0006
    /// Below this share of total energy there is no real bass, so hits come from the full mix.
    private static let bassShare: Float = 0.22

    private(set) var onsetCount = 0
    private(set) var midOnsetCount = 0
    private(set) var isSilent = true
    private(set) var loudest: Float = 0

    var bassLevel: Float { kick.level }
    var midLevel: Float { mid.level }
    var highLevel: Float { high.level }

    private let hopLength: Int
    private let hopDuration: Double
    private let lowCoefficient: Float
    private let midCoefficient: Float
    private var lowA: Float = 0
    private var lowB: Float = 0
    private var upper: Float = 0
    private var lowSum: Float = 0
    private var midSum: Float = 0
    private var highSum: Float = 0
    private var fullSum: Float = 0
    private var hopFill = 0
    private var kick = BandTracker()
    private var mid = BandTracker()
    private var high = BandTracker()
    /// Hops left before running averages mean anything and hits can count.
    private var warmupHops = 30

    init(sampleRate: Double) {
        hopLength = max(Int(sampleRate * Self.hopSeconds), 1)
        hopDuration = Double(hopLength) / sampleRate
        lowCoefficient = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        midCoefficient = Float(1 - exp(-2 * Double.pi * 2200 / sampleRate))
    }

    /// Reads `frames` samples, taking every `stride`th value of an interleaved buffer.
    func consume(_ samples: UnsafePointer<Float>, frames: Int, stride: Int) {
        for frame in 0..<frames {
            let sample = samples[frame * stride]
            // One-pole filters are cheap enough for the audio thread.
            lowA += (sample - lowA) * lowCoefficient
            lowB += (lowA - lowB) * lowCoefficient
            upper += (sample - upper) * midCoefficient
            let midSample = upper - lowB
            let highSample = sample - upper
            lowSum += lowB * lowB
            midSum += midSample * midSample
            highSum += highSample * highSample
            fullSum += sample * sample
            loudest = max(loudest, abs(sample))
            hopFill += 1
            if hopFill == hopLength { finishHop() }
        }
    }

    private func finishHop() {
        let count = Float(hopLength)
        let lowValue = (lowSum / count).squareRoot()
        let midValue = (midSum / count).squareRoot()
        let highValue = (highSum / count).squareRoot()
        let full = (fullSum / count).squareRoot()
        lowSum = 0
        midSum = 0
        highSum = 0
        fullSum = 0
        hopFill = 0
        isSilent = full <= Self.silence

        let isWarmingUp = warmupHops > 0
        if isWarmingUp { warmupHops -= 1 }
        let kickValue = lowValue >= full * Self.bassShare ? lowValue : full
        if kick.update(kickValue, hop: hopDuration, isWarmingUp: isWarmingUp, ratio: 1.45, minimumGap: 0.17, silence: Self.silence) {
            onsetCount += 1
        }
        if mid.update(midValue, hop: hopDuration, isWarmingUp: isWarmingUp, ratio: 1.6, minimumGap: 0.14, silence: Self.silence) {
            midOnsetCount += 1
        }
        _ = high.update(highValue, hop: hopDuration, isWarmingUp: isWarmingUp, ratio: 2, minimumGap: 0.1, silence: Self.silence)
    }

    /// Clears the peak reading for the diagnostic log.
    func resetLoudest() { loudest = 0 }
}

/// Listens to the Music app's audio only. Samples are measured and thrown away, never
/// stored or sent anywhere.
final class MusicAnalyzer: @unchecked Sendable {
    struct Onset {
        let date: Date
        let isBass: Bool
    }

    struct Reading {
        var bass = 0.0
        var mid = 0.0
        var high = 0.0
        var onsets: [Onset] = []
        /// False when nothing is reaching the app, as when permission was declined.
        var hasSignal = false
    }

    private struct Shared {
        var bass: Float = 0
        var mid: Float = 0
        var high: Float = 0
        var onsets: [Onset] = []
        var lastSignal = Date.distantPast
    }

    private static let keptOnsets = 10
    private static let logger = Logger(subsystem: "com.qwelpl.peacemusic", category: "audio")

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let ioQueue = DispatchQueue(label: "peace.bass-analyzer", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var tappedProcesses: [AudioObjectID] = []
    private var demoTimer: DispatchSourceTimer?
    private var lastDiagnostic = Date.distantPast

    var reading: Reading {
        shared.withLock { state in
            Reading(
                bass: Double(state.bass),
                mid: Double(state.mid),
                high: Double(state.high),
                onsets: state.onsets,
                hasSignal: Date().timeIntervalSince(state.lastSignal) < 1.5
            )
        }
    }

    deinit { stop() }

    /// Safe to call repeatedly. Reconnects if Music restarted or the output device changed.
    func start() {
        let processes = Self.musicProcesses()
        let device = Self.defaultOutputDevice()
        if procID != nil, processes == tappedProcesses, device == outputDevice { return }
        stop()
        guard !processes.isEmpty, device != kAudioObjectUnknown else { return }
        if connect(processes: processes, device: device) {
            Self.logger.notice("Connected to \(processes.count) Music audio process(es)")
        } else {
            Self.logger.error("Could not connect to Music's audio")
            stop()
        }
    }

    func stop() {
        demoTimer?.cancel()
        demoTimer = nil
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
        outputDevice = AudioObjectID(kAudioObjectUnknown)
        shared.withLock { $0 = Shared() }
    }

    private func connect(processes: [AudioObjectID], device: AudioObjectID) -> Bool {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Peace bass"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &newTap) == noErr else { return false }
        tapID = newTap

        guard let outputUID = Self.deviceUID(device),
              let format = Self.tapFormat(newTap),
              format.mSampleRate > 0,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return false }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Peace Bass Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &newAggregate) == noErr else { return false }
        aggregateID = newAggregate

        let detector = MusicDetector(sampleRate: format.mSampleRate)
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let stride = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            self?.feed(detector, data.assumingMemoryBound(to: Float.self), frames: frames, stride: stride)
        }
        guard status == noErr, let newProc else { return false }
        procID = newProc
        tappedProcesses = processes
        outputDevice = device
        return AudioDeviceStart(newAggregate, newProc) == noErr
    }

    private func feed(_ detector: MusicDetector, _ samples: UnsafePointer<Float>, frames: Int, stride: Int) {
        let bassBefore = detector.onsetCount
        let midBefore = detector.midOnsetCount
        detector.consume(samples, frames: frames, stride: stride)
        let bassHit = detector.onsetCount > bassBefore
        let midHit = detector.midOnsetCount > midBefore
        let now = Date()
        shared.withLock { state in
            state.bass = detector.bassLevel
            state.mid = detector.midLevel
            state.high = detector.highLevel
            if !detector.isSilent { state.lastSignal = now }
            if bassHit { state.onsets.append(Onset(date: now, isBass: true)) }
            if midHit { state.onsets.append(Onset(date: now, isBass: false)) }
            if state.onsets.count > Self.keptOnsets {
                state.onsets.removeFirst(state.onsets.count - Self.keptOnsets)
            }
        }
        if now.timeIntervalSince(lastDiagnostic) >= 2 {
            lastDiagnostic = now
            let loudest = detector.loudest
            let hits = detector.onsetCount
            Self.logger.debug("peak=\(loudest, privacy: .public) bassHits=\(hits, privacy: .public)")
            detector.resetLoudest()
        }
    }

    /// Drives the real detector with a generated drum loop, for demo runs.
    func startDemo() {
        guard demoTimer == nil else { return }
        let sampleRate = 44100.0
        let detector = MusicDetector(sampleRate: sampleRate)
        var position = 0
        var buffer = [Float](repeating: 0, count: 441)
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            for index in buffer.indices {
                let time = Double(position + index) / sampleRate
                let sinceKick = time.truncatingRemainder(dividingBy: 0.5)
                let sinceSnare = (time + 0.25).truncatingRemainder(dividingBy: 1)
                let sinceHat = time.truncatingRemainder(dividingBy: 0.125)
                let kick = sin(2 * .pi * 58 * sinceKick) * exp(-sinceKick * 11) * 0.7
                let snare = sin(2 * .pi * 720 * sinceSnare) * exp(-sinceSnare * 20) * 0.35
                let hat = Double.random(in: -1...1) * exp(-sinceHat * 60) * 0.12
                buffer[index] = Float(kick + snare + hat)
            }
            position += buffer.count
            buffer.withUnsafeBufferPointer {
                self?.feed(detector, $0.baseAddress!, frames: $0.count, stride: 1)
            }
        }
        timer.resume()
        demoTimer = timer
    }

    // MARK: Core Audio lookups

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        return device
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var property = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    /// Audio processes belonging to Music, which can include helpers as well as the app.
    private static func musicProcesses() -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &processes) == noErr else { return [] }

        return processes.filter { process in
            var bundleProperty = address(kAudioProcessPropertyBundleID)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(process, &bundleProperty, 0, nil, &bundleSize, &bundle) == noErr,
                  let identifier = bundle?.takeRetainedValue() as String? else { return false }
            return identifier == "com.apple.Music" || identifier.hasPrefix("com.apple.Music.")
        }
    }
}
