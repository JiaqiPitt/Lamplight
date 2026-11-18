import CoreAudio
import Combine
import Foundation

/// Small questions put to the system about its sound devices.
enum AudioDevices {
    struct Device {
        let id: AudioDeviceID
        let name: String
        /// Output channels; 0 for a microphone.
        let outputs: Int
        /// kAudioDeviceTransportType…: built-in, Bluetooth, virtual and so on.
        let transport: UInt32

        var isWireless: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// The device the Mac currently sends sound to.
    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func transport(of id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    static func outputChannels(of id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func device(_ id: AudioDeviceID) -> Device {
        Device(id: id, name: name(of: id) ?? "Device \(id)", outputs: outputChannels(of: id), transport: transport(of: id))
    }

    static func all() -> [Device] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(device)
    }

    /// Calls back on the main thread whenever the Mac's sound output changes to another device.
    static func onDefaultOutputChange(_ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
    }
}

/// Which device the sound is going to, for showing in Settings. The app always plays through the
/// Mac's own choice of output; when nothing can be heard, this is the first thing worth looking at.
final class OutputMonitor: ObservableObject {
    @Published private(set) var name = ""
    @Published private(set) var wireless = false

    init() {
        refresh()
        AudioDevices.onDefaultOutputChange { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard let id = AudioDevices.defaultOutput() else {
            name = ""
            wireless = false
            return
        }
        let device = AudioDevices.device(id)
        name = device.name
        wireless = device.isWireless
    }
}
