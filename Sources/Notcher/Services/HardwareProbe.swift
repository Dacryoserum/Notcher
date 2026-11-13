import Foundation
import NotcherCore
import CoreAudio
import AudioToolbox
import CoreGraphics
import IOKit.ps
import IOBluetooth

struct AudioOutput: Codable, Identifiable, Equatable, Sendable { let id: AudioDeviceID; let name: String }
struct AudioSnapshot: Codable, Sendable {
    var volume: Double = 0
    var muted = false
    var canSetVolume = false
    var canMute = false
    var outputName = "Sortie audio"
    var battery: Int?
    var charging = false
}
struct BrightnessSnapshot: Codable, Sendable { var value: Double; var supported: Bool }

/// Only executed in a disposable child, before NSApplication initialization.
/// A stalled hardware daemon cannot block the UI and is killed after the deadline.
enum HardwareProbe {
    static func run(_ arguments: [String]) throws -> Data {
        guard let operation = arguments.first else { throw CommandError.unavailable }
        switch operation {
        case "audio": return try JSONEncoder().encode(audio())
        case "outputs": return try JSONEncoder().encode(outputs())
        case "volume":
            var value = Float32(try scalar(arguments))
            try setAudio(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, value: &value)
        case "mute":
            var value: UInt32 = try scalar(arguments) > 0 ? 1 : 0
            try setAudio(kAudioDevicePropertyMute, value: &value)
        case "output":
            guard arguments.count == 2, var device = AudioDeviceID(arguments[1]) else { throw CommandError.unavailable }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device) == noErr else { throw CommandError.unavailable }
        case "brightness": return try JSONEncoder().encode(brightness(set: nil))
        case "set-brightness":
            guard try brightness(set: Float(scalar(arguments))).supported else { throw CommandError.unavailable }
        case "bluetooth":
            let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }.compactMap(\.name)
            return try JSONEncoder().encode(Array(Set(devices)).sorted())
        default: throw CommandError.unavailable
        }
        return Data("{}".utf8)
    }
    private static func scalar(_ arguments: [String]) throws -> Double {
        guard arguments.count == 2, let value = Double(arguments[1]), value.isFinite, (0...1).contains(value) else { throw CommandError.unavailable }
        return value
    }
    private static func defaultOutput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size), device = AudioDeviceID(0)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }
    private static func audio() -> AudioSnapshot {
        var result = AudioSnapshot()
        let device = defaultOutput()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var scalar: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        var settable: DarwinBoolean = false
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr, scalar.isFinite {
            result.volume = min(1, max(0, Double(scalar)))
            AudioObjectIsPropertySettable(device, &address, &settable)
            result.canSetVolume = settable.boolValue
        }
        address.mSelector = kAudioDevicePropertyMute
        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size); settable = false
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr {
            result.muted = mute != 0
            AudioObjectIsPropertySettable(device, &address, &settable); result.canMute = settable.boolValue
        }
        result.outputName = name(for: device)
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      let current = info[kIOPSCurrentCapacityKey] as? Int, let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                result.battery = min(100, max(0, Int(Double(current) / Double(maximum) * 100)))
                result.charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                break
            }
        }
        return result
    }
    private static func setAudio<T>(_ selector: AudioObjectPropertySelector, value: inout T) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(defaultOutput(), &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        guard status == noErr else { throw CommandError.unavailable }
    }
    private static func outputs() -> [AudioOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0, size < 65536 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { candidate in
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(candidate, &property, 0, nil, &bytes) == noErr && bytes > 0
        }.map { AudioOutput(id: $0, name: name(for: $0)) }
    }
    private static func name(for id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "Sortie audio" }
        return value.takeRetainedValue() as String
    }
    private static func brightness(set value: Float?) -> BrightnessSnapshot {
        typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else { return .init(value: 0, supported: false) }
        defer { dlclose(handle) }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return .init(value: 0, supported: false) }
        if let value {
            guard let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return .init(value: 0, supported: false) }
            let setter = unsafeBitCast(symbol, to: Set.self)
            return .init(value: Double(value), supported: setter(display, value) == 0)
        }
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return .init(value: 0, supported: false) }
        let getter = unsafeBitCast(symbol, to: Get.self)
        var scalar: Float = 0
        let available = getter(display, &scalar) == 0 && scalar.isFinite
        return .init(value: available ? min(1, max(0, Double(scalar))) : 0, supported: available)
    }
}

struct HardwareClient: Sendable {
    var request: @Sendable ([String]) async throws -> Data
    static let live = HardwareClient { arguments in
        guard let executable = Bundle.main.executableURL else { throw CommandError.unavailable }
        let result = try await Command.run(executable.path, ["--hardware"] + arguments, timeout: 3)
        guard result.status == 0 else { throw CommandError.unavailable }
        return result.data
    }
}
