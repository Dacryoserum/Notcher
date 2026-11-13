import CoreAudio
import NotcherCore
import AudioToolbox
import Foundation

/// Pushes volume changes the moment they happen (keyboard keys, Control Centre, another app).
/// CoreAudio calls back on a private queue, so a stalled audio daemon can never block the interface.
final class VolumeObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.notcher.volume", qos: .userInteractive)
    private let onChange: @Sendable (Double, Bool) -> Void
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
    init(onChange: @escaping @Sendable (Double, Bool) -> Void) { self.onChange = onChange }

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
        detach()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size), current = AudioDeviceID(0)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDevice, 0, nil, &size, &current) == noErr, current != 0 else { return }
        device = current
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
