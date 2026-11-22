import CoreAudio
import SwiftUI

// Where Peace's sound plays: the Mac's output devices, with each AirPlay receiver listed on its own.
struct AudioOutput: Identifiable, Equatable {
    let device: AudioObjectID
    let source: UInt32?
    let name: String
    let symbol: String
    var isSelected: Bool

    var id: String { "\(device)-\(source.map(String.init) ?? "")" }
}

enum AudioOutputs {
    static func all() -> [AudioOutput] {
        let current = defaultOutput()
        var outputs: [AudioOutput] = []
        for device in devices() where hasOutput(device) && !isHidden(device) {
            let transport = transportType(device)
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { continue }
            let symbol = symbol(for: transport, name: name(of: device))
            // The AirPlay device carries every receiver as a data source.
            if transport == kAudioDeviceTransportTypeAirPlay {
                let selected = dataSource(device)
                for source in dataSources(device) {
                    outputs.append(AudioOutput(
                        device: device,
                        source: source,
                        name: sourceName(device, source) ?? "AirPlay",
                        symbol: symbol,
                        isSelected: device == current && source == selected
                    ))
                }
                continue
            }
            outputs.append(AudioOutput(device: device, source: nil, name: name(of: device), symbol: symbol, isSelected: device == current))
        }
        return outputs
    }

    static func select(_ output: AudioOutput) {
        if var source = output.source {
            var property = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectSetPropertyData(output.device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &source)
        }
        var device = output.device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var property = address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, size, &device)
        }
    }

    // MARK: Core Audio

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func devices() -> [AudioObjectID] {
        var property = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func defaultOutput() -> AudioObjectID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device)
        return device
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var property = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ device: AudioObjectID) -> Bool {
        var property = address(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &property, 0, nil, &size, &hidden)
        return hidden != 0
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32 {
        var property = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &property, 0, nil, &size, &type)
        return type
    }

    private static func name(of device: AudioObjectID) -> String {
        var property = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &name) == noErr else { return "Output" }
        return name?.takeRetainedValue() as String? ?? "Output"
    }

    private static func dataSource(_ device: AudioObjectID) -> UInt32? {
        var property = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &property, 0, nil, &size, &source) == noErr ? source : nil
    }

    private static func dataSources(_ device: AudioObjectID) -> [UInt32] {
        var property = address(kAudioDevicePropertyDataSources, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var sources = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &sources) == noErr else { return [] }
        return sources
    }

    private static func sourceName(_ device: AudioObjectID, _ source: UInt32) -> String? {
        var property = address(kAudioDevicePropertyDataSourceNameForIDCFString, scope: kAudioObjectPropertyScopeOutput)
        var input = source
        var name: Unmanaged<CFString>?
        return withUnsafeMutablePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &name) { namePointer in
                var translation = AudioValueTranslation(
                    mInputData: inputPointer,
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: namePointer,
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &translation) == noErr else { return nil }
                return namePointer.pointee?.takeRetainedValue() as String?
            }
        }
    }

    private static func symbol(for transport: UInt32, name: String) -> String {
        let lowered = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lowered.contains("airpods max") { return "airpodsmax" }
            if lowered.contains("airpods pro") { return "airpodspro" }
            if lowered.contains("airpods") { return "airpods" }
            if lowered.contains("beats") { return "beats.headphones" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        case kAudioDeviceTransportTypeBuiltIn:
            return lowered.contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "speaker.wave.2"
        }
    }
}

// The dock's output button and the glass list that opens above it.
struct OutputPicker: View {
    @Environment(\.songTheme) private var theme
    @State private var isOpen = false
    @State private var outputs: [AudioOutput] = []

    var body: some View {
        Button {
            outputs = AudioOutputs.all()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { isOpen.toggle() }
        } label: {
            Image(systemName: currentSymbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.ink.opacity(0.95))
                .frame(width: 38, height: 38)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.pointer)
        .help("Play Sound On")
        .overlay(alignment: .bottomTrailing) {
            if isOpen {
                panel
                    .fixedSize()
                    .offset(y: -52)
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .background {
            if isOpen {
                Button("") { close() }.keyboardShortcut(.cancelAction).hidden()
            }
        }
        .task(id: isOpen) {
            // Receivers come and go; keep the list fresh while it's open.
            while isOpen, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                outputs = AudioOutputs.all()
            }
        }
        .onAppear { outputs = AudioOutputs.all() }
    }

    private var currentSymbol: String {
        let current = outputs.first(where: \.isSelected)
        return current?.symbol == "airplayaudio" ? "airplayaudio" : "hifispeaker.fill"
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Play Sound On")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.ink.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if outputs.isEmpty {
                Text("No outputs found")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink.opacity(0.6))
                    .padding(10)
            }
            ForEach(outputs) { output in
                OutputRow(output: output) {
                    AudioOutputs.select(output)
                    outputs = AudioOutputs.all()
                    close()
                }
            }
        }
        .padding(6)
        .frame(width: 260)
        .songGlass(in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.14)) { isOpen = false }
    }
}

private struct OutputRow: View {
    let output: AudioOutput
    let action: () -> Void

    @Environment(\.songTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: output.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22)
                Text(output.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if output.isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(isHovered ? theme.onAccent : .ink)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isHovered ? theme.accent.opacity(0.9) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.pointer)
        .onHover { isHovered = $0 }
    }
}
