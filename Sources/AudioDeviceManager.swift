import Foundation
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let sampleRate: Float64
    let channels: UInt32
}

final class AudioDeviceManager {
    static func allInputDevices() -> [AudioDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var results: [AudioDevice] = []
        for devID in deviceIDs {
            let channels = inputChannelCount(for: devID)
            guard channels > 0 else { continue }

            let name = deviceName(for: devID) ?? "Unknown"
            let sr = deviceSampleRate(for: devID) ?? 44100.0

            results.append(AudioDevice(id: devID, name: name, sampleRate: sr, channels: channels))
        }

        return results
    }
    static func allOutputDevices() -> [AudioDevice] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        var results: [AudioDevice] = []
        for devID in deviceIDs {
            // Check if this device has output channels
            let channels = outputChannelCount(for: devID)
            guard channels > 0 else { continue }

            let name = deviceName(for: devID) ?? "Unknown"
            let sr = deviceSampleRate(for: devID) ?? 44100.0

            results.append(AudioDevice(id: devID, name: name, sampleRate: sr, channels: channels))
        }

        return results
    }

    /// Find BlackHole 2ch device by name
    static func findBlackHole() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        )
        guard status == noErr else { return 0 }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return 0 }

        for devID in deviceIDs {
            if let name = deviceName(for: devID),
               name.lowercased().contains("blackhole") {
                // Verify it has input channels (we read from it)
                let inCh = inputChannelCount(for: devID)
                if inCh > 0 { return devID }
            }
        }
        return 0
    }

    static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propAddr, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let allocated = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocated.deallocate() }
        var size = dataSize
        let st = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, allocated)
        guard st == noErr else { return 0 }

        let bufferList = allocated.assumingMemoryBound(to: AudioBufferList.self).pointee
        var totalChannels: UInt32 = 0
        withUnsafePointer(to: bufferList.mBuffers) { ptr in
            for i in 0..<Int(bufferList.mNumberBuffers) {
                let buf = UnsafeRawPointer(ptr).advanced(by: i * MemoryLayout<AudioBuffer>.stride)
                    .assumingMemoryBound(to: AudioBuffer.self).pointee
                totalChannels += buf.mNumberChannels
            }
        }
        return totalChannels
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static func defaultSystemOutputDeviceID() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static func outputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propAddr, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        // Allocate enough space
        let allocated = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { allocated.deallocate() }
        var size = dataSize
        let st = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, allocated)
        guard st == noErr else { return 0 }

        let bufferList = allocated.assumingMemoryBound(to: AudioBufferList.self).pointee
        var totalChannels: UInt32 = 0
        withUnsafePointer(to: bufferList.mBuffers) { ptr in
            for i in 0..<Int(bufferList.mNumberBuffers) {
                let buf = UnsafeRawPointer(ptr).advanced(by: i * MemoryLayout<AudioBuffer>.stride)
                    .assumingMemoryBound(to: AudioBuffer.self).pointee
                totalChannels += buf.mNumberChannels
            }
        }
        return totalChannels
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, &name)
        guard status == noErr, let cfName = name else { return nil }
        return cfName.takeUnretainedValue() as String
    }

    static func deviceSampleRate(for deviceID: AudioDeviceID) -> Float64? {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, &sampleRate)
        guard status == noErr else { return nil }
        return sampleRate
    }

    @discardableResult
    static func setDeviceSampleRate(_ deviceID: AudioDeviceID, sampleRate: Float64) -> OSStatus {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        let size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(deviceID, &propAddr, 0, nil, size, &rate)
    }

    static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }

    static func allProcessObjectIDs() -> [AudioObjectID] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil, &dataSize, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    static func setProcessOutputDevice(processID: AudioObjectID, deviceID: AudioDeviceID) -> OSStatus {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(processID, &propAddr, 0, nil, size, &devID)
    }

    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID = deviceID
        let status1 = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devID
        )
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status2 = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &sysAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &devID
        )
        return status1 == noErr && status2 == noErr
    }
}
