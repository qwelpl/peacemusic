import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

private struct BandTracker {
    private var smooth: Float = 0
    private var average: Float = 0
    private var previous: Float = 0
    private var peak: Float = 0.001
    private var sinceOnset = 1.0

    private(set) var level: Float = 0

    mutating func update(
        _ value: Float, hop: Double, isWarmingUp: Bool, ratio: Float, minimumGap: Double, silence: Float
    ) -> Bool {
        sinceOnset += hop
        peak = max(peak * 0.9995, value)
        smooth += (value >= smooth ? 0.6 : 0.1) * (value - smooth)
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

final class SpectrumAnalyzer {
    static let bandCount = 24
    private static let log2Size: vDSP_Length = 10
    private static let size = 1 << 10

    private(set) var bands = [Float](repeating: 0, count: bandCount)

    private let setup: FFTSetup
    private let window: [Float]
    private let binRanges: [Range<Int>]
    private var history = [Float](repeating: 0, count: size)
    private var ordered = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var peaks = [Float](repeating: 0.001, count: bandCount)
    private var writeIndex = 0
    private var sinceLast = 0

    init(sampleRate: Double) {
        setup = vDSP_create_fftsetup(Self.log2Size, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        let binWidth = sampleRate / Double(Self.size)
        let (low, high) = (45.0, min(14000.0, sampleRate / 2 - binWidth))
        binRanges = (0..<Self.bandCount).map { band in
            let start = low * pow(high / low, Double(band) / Double(Self.bandCount))
            let end = low * pow(high / low, Double(band + 1) / Double(Self.bandCount))
            let first = max(Int(start / binWidth), 1)
            return first..<max(Int(end / binWidth), first + 1)
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func add(_ sample: Float) {
        history[writeIndex] = sample
        writeIndex = (writeIndex + 1) % Self.size
        sinceLast += 1
        if sinceLast == Self.size / 2 {
            sinceLast = 0
            transform()
        }
    }

    private func transform() {
        for index in 0..<Self.size {
            ordered[index] = history[(writeIndex + index) % Self.size] * window[index]
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                ordered.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Size, FFTDirection(kFFTDirection_Forward))
            }
        }
        for (band, bins) in binRanges.enumerated() {
            var sum: Float = 0
            for bin in bins where bin < Self.size / 2 {
                sum += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
            }
            let magnitude = (sum / Float(bins.count)).squareRoot()
            peaks[band] = max(peaks[band] * 0.9985, magnitude)
            let target = magnitude < 0.002 ? 0 : pow(magnitude / peaks[band], 1.5)
            bands[band] += (target > bands[band] ? 0.65 : 0.16) * (target - bands[band])
        }
    }
}

final class MusicDetector {
    private static let hopSeconds = 0.0116
    private static let silence: Float = 0.0006
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
    private var warmupHops = 30

    let spectrum: SpectrumAnalyzer

    init(sampleRate: Double) {
        spectrum = SpectrumAnalyzer(sampleRate: sampleRate)
        hopLength = max(Int(sampleRate * Self.hopSeconds), 1)
        hopDuration = Double(hopLength) / sampleRate
        lowCoefficient = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        midCoefficient = Float(1 - exp(-2 * Double.pi * 2200 / sampleRate))
    }

    func consume(_ samples: UnsafePointer<Float>, frames: Int, stride: Int) {
        for frame in 0..<frames {
            let sample = samples[frame * stride]
            spectrum.add(sample)
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

    func resetLoudest() { loudest = 0 }
}

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
        var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        var hasSignal = false
    }

    private struct Shared {
        var bass: Float = 0
        var mid: Float = 0
        var high: Float = 0
        var onsets: [Onset] = []
        var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
        var lastSignal = Date.distantPast
    }

    private static let keptOnsets = 10
    private static let logger = Logger(subsystem: "com.qwelpl.peacemusic", category: "audio")
    // Debug: log signal levels to this path.
    private static let diagnosticPath = ProcessInfo.processInfo.environment["PEACE_AUDIO_LOG"]

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
                spectrum: state.spectrum,
                hasSignal: Date().timeIntervalSince(state.lastSignal) < 1.5
            )
        }
    }

    deinit { stop() }

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
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, newAggregate, ioQueue) { [weak self] _, input, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let stride = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            let lag = Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime() &- inputTime.pointee.mHostTime)) / 1e9
            self?.feed(detector, data.assumingMemoryBound(to: Float.self), frames: frames, stride: stride, lag: lag)
        }
        guard status == noErr, let newProc else { return false }
        procID = newProc
        tappedProcesses = processes
        outputDevice = device
        return AudioDeviceStart(newAggregate, newProc) == noErr
    }

    private func feed(_ detector: MusicDetector, _ samples: UnsafePointer<Float>, frames: Int, stride: Int, lag: Double = 0) {
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
            // No allocation on the audio thread.
            for band in state.spectrum.indices { state.spectrum[band] = detector.spectrum.bands[band] }
            if !detector.isSilent { state.lastSignal = now }
            if bassHit { state.onsets.append(Onset(date: now, isBass: true)) }
            if midHit { state.onsets.append(Onset(date: now, isBass: false)) }
            if state.onsets.count > Self.keptOnsets {
                state.onsets.removeFirst(state.onsets.count - Self.keptOnsets)
            }
        }
        if let path = Self.diagnosticPath, now.timeIntervalSince(lastDiagnostic) >= 1 {
            lastDiagnostic = now
            let line = String(
                format: "peak=%.4f bass=%.2f mid=%.2f high=%.2f bassHits=%d midHits=%d frames=%d lag=%.3f\n",
                detector.loudest, detector.bassLevel, detector.midLevel, detector.highLevel,
                detector.onsetCount, detector.midOnsetCount, frames, lag
            )
            detector.resetLoudest()
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
            }
        }
    }

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
