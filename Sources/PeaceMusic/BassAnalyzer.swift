import AudioToolbox
import CoreAudio
import Foundation
import os

/// Finds low-end hits in a stream of samples. Tracks are mastered at very different
/// levels, so every threshold is relative to the recent signal instead of absolute.
final class BassDetector {
    private static let hopSeconds = 0.0116
    private static let minimumGap = 0.17
    private static let onsetRatio: Float = 1.45
    private static let silence: Float = 0.0006
    /// Below this share of total energy there is no real bass, so hits come from the full mix.
    private static let bassShare: Float = 0.22

    private(set) var level: Float = 0
    private(set) var onsetCount = 0

    private let hopLength: Int
    private let hopDuration: Double
    // One-pole cascade around 150 Hz, which is cheap enough for the audio thread.
    private let coefficient: Float
    private var lowA: Float = 0
    private var lowB: Float = 0
    private var lowSum: Float = 0
    private var fullSum: Float = 0
    private var hopFill = 0
    private var average: Float = 0
    private var previous: Float = 0
    private var peak: Float = 0.001
    private var sinceOnset = 1.0
    private var smoothLevel: Float = 0
    /// Hops left before the running average means anything and hits can count.
    private var warmupHops = 30

    init(sampleRate: Double) {
        hopLength = max(Int(sampleRate * Self.hopSeconds), 1)
        hopDuration = Double(hopLength) / sampleRate
        coefficient = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
    }

    /// Reads `frames` samples, taking every `stride`th value of an interleaved buffer.
    func consume(_ samples: UnsafePointer<Float>, frames: Int, stride: Int) {
        for frame in 0..<frames {
            let sample = samples[frame * stride]
            lowA += (sample - lowA) * coefficient
            lowB += (lowA - lowB) * coefficient
            lowSum += lowB * lowB
            fullSum += sample * sample
            hopFill += 1
            if hopFill == hopLength { finishHop() }
        }
    }

    private func finishHop() {
        let low = (lowSum / Float(hopLength)).squareRoot()
        let full = (fullSum / Float(hopLength)).squareRoot()
        lowSum = 0
        fullSum = 0
        hopFill = 0
        sinceOnset += hopDuration

        let feature = low >= full * Self.bassShare ? low : full
        peak = max(peak * 0.9995, feature)
        smoothLevel += ((feature >= smoothLevel ? 0.6 : 0.09) * (feature - smoothLevel))
        level = min(smoothLevel / max(peak, 0.001), 1)

        let isRising = feature > previous
        if warmupHops > 0 {
            warmupHops -= 1
            average += (feature - average) * 0.2
            previous = feature
            return
        }
        if feature > Self.silence,
           isRising,
           feature > average * Self.onsetRatio,
           sinceOnset >= Self.minimumGap {
            onsetCount += 1
            sinceOnset = 0
        }
        average += (feature - average) * 0.02
        previous = feature
    }
}

/// Listens to the Music app's audio only. Samples are measured and thrown away, never
/// stored or sent anywhere.
final class BassAnalyzer: @unchecked Sendable {
    struct Reading {
        var level: Double = 0
        var onsets: [Date] = []
    }

    private struct Shared {
        var level: Float = 0
        var onsets: [Date] = []
    }

    private static let keptOnsets = 6
    private static let logger = Logger(subsystem: "com.qwelpl.peacemusic", category: "bass")

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let ioQueue = DispatchQueue(label: "peace.bass-analyzer", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var tappedProcesses: [AudioObjectID] = []
    private var demoTimer: DispatchSourceTimer?
    private var hasLoggedSignal = false

    var reading: Reading {
        shared.withLock { Reading(level: Double($0.level), onsets: $0.onsets) }
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
        hasLoggedSignal = false
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

        let detector = BassDetector(sampleRate: format.mSampleRate)
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

    private func feed(_ detector: BassDetector, _ samples: UnsafePointer<Float>, frames: Int, stride: Int) {
        let before = detector.onsetCount
        detector.consume(samples, frames: frames, stride: stride)
        let hit = detector.onsetCount > before
        if hit, !hasLoggedSignal {
            hasLoggedSignal = true
            Self.logger.notice("First bass hit detected")
        }
        let level = detector.level
        shared.withLock { state in
            state.level = level
            if hit {
                state.onsets.append(Date())
                if state.onsets.count > Self.keptOnsets { state.onsets.removeFirst() }
            }
        }
    }

    /// Drives the real detector with a generated drum loop, for `--demo-instrumental`.
    func startDemo() {
        guard demoTimer == nil else { return }
        let sampleRate = 44100.0
        let detector = BassDetector(sampleRate: sampleRate)
        var position = 0
        var buffer = [Float](repeating: 0, count: 441)
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            for index in buffer.indices {
                let time = Double(position + index) / sampleRate
                let sinceKick = time.truncatingRemainder(dividingBy: 0.5)
                buffer[index] = Float(sin(2 * .pi * 58 * sinceKick) * exp(-sinceKick * 11) * 0.8)
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
