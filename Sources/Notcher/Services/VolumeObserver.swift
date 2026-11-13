import CoreAudio
import NotcherCore
import AudioToolbox
import Foundation

/// Pushes volume changes the moment they happen (keyboard keys, Control Centre, another app).
/// CoreAudio calls back on a private queue, so a stalled audio daemon can never block the interface.
final class VolumeObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.notcher.volume", qos: .userInteractive)
    private let onChange: @Sendable (Double, Bool) -> Void
    /// Name of the new default output and whether it is a Bluetooth device. Not called for the first one seen.
    private let onDevice: @Sendable (String, Bool) -> Void
    private var seenDevice = false
    private var device = AudioDeviceID(0)
    private var levelBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private static var defaultDevice = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    /// Devices differ in what they announce: the virtual main volume, or one scalar per channel.
    private static let watched: [AudioObjectPropertyAddress] = [
        .init(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
        .init(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain),
        .init(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: 1),
        .init(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: 2)
    ]
    init(onChange: @escaping @Sendable (Double, Bool) -> Void, onDevice: @escaping @Sendable (String, Bool) -> Void = { _, _ in }) {
        self.onChange = onChange; self.onDevice = onDevice
    }

    func start() {
        queue.async { [self] in
            guard deviceBlock == nil else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
            deviceBlock = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, queue, block)
            attach()
        }
    }
    func stop() {
        queue.async { [self] in
            detach()
            if let deviceBlock { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, queue, deviceBlock) }
            deviceBlock = nil
        }
    }
    private func attach() {
        let previous = device
        detach()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size), current = AudioDeviceID(0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, 0, nil, &size, &current) == noErr, current != 0 else { return }
        let changed = seenDevice && current != previous
        seenDevice = true
        device = current
        if changed { announce(current) }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publish() }
        levelBlock = block
        for var address in Self.watched where AudioObjectHasProperty(current, &address) {
            AudioObjectAddPropertyListenerBlock(current, &address, queue, block)
        }
    }
    private func detach() {
        if let levelBlock, device != 0 {
            for var address in Self.watched where AudioObjectHasProperty(device, &address) {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, levelBlock)
            }
        }
        levelBlock = nil; device = 0
    }
    private func announce(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        address.mSelector = kAudioObjectPropertyName
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return }
        onDevice(name.takeRetainedValue() as String, transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
    }
    private func publish() {
        guard device != 0 else { return }
        var address = Self.watched[0]
        var scalar: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &scalar) == noErr, scalar.isFinite else { return }
        var mute: UInt32 = 0
        address = Self.watched[1]; size = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) == noErr && mute != 0
        onChange(min(1, max(0, Double(scalar))), muted)
    }
}
