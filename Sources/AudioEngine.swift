import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import AppKit
import Accelerate

enum ReferenceNote: String, CaseIterable {
    case C = "C"
    case A = "A"
}

@MainActor
final class AudioEngine: ObservableObject {
    private let qualityOverlap: Float = 32.0

    private static let udNoteKey = "referenceNote"
    private static let udFreqKey = "referenceFreq"
    private static let udBufferKey = "bufferSize"

    static let bufferSizes: [UInt32] = [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]

    @Published var isRunning = false
    @Published var referenceNote: ReferenceNote = .A {
        didSet {
            // Reset to default value when switching modes
            switch referenceNote {
            case .C: referenceFreq = 256
            case .A: referenceFreq = 432
            }
            UserDefaults.standard.set(referenceNote.rawValue, forKey: Self.udNoteKey)
        }
    }
    @Published var referenceFreq: Float = 432 {
        didSet {
            updateFromReference()
            UserDefaults.standard.set(referenceFreq, forKey: Self.udFreqKey)
        }
    }
    @Published private(set) var targetA: Float = 432
    private var outputDeviceID: AudioDeviceID = 0 {
        didSet {
            guard oldValue != outputDeviceID, oldValue != 0 else { return }
            if isRunning { restart() }
        }
    }
    @Published var bufferSize: UInt32 = 512 {
        didSet {
            UserDefaults.standard.set(Int(bufferSize), forKey: Self.udBufferKey)
            if isRunning { restart() }
        }
    }
    @Published var currentSampleRate: Float64?
    @Published private(set) var isLowPowerMode: Bool = false

    var bufferLatencyMs: String {
        let sr = currentSampleRate ?? 48000
        let ms = Double(bufferSize) / sr * 1000.0
        return String(format: "%.1f ms", ms)
    }

    var centsValue: Float {
        1200.0 * log2f(targetA / 440.0)
    }

    private func updateFromReference() {
        switch referenceNote {
        case .C:
            targetA = referenceFreq * powf(2.0, 9.0 / 12.0)
        case .A:
            targetA = referenceFreq
        }
        updatePitch()
    }

    var referenceLabel: String {
        switch referenceNote {
        case .C: return "C4"
        case .A: return "A4"
        }
    }

    var referenceRange: ClosedRange<Float> {
        switch referenceNote {
        case .C: return 240...270
        case .A: return 415...460
        }
    }

    var referencePresets: [(String, Float)] {
        switch referenceNote {
        case .C: return [("256", 256), ("261", 261)]
        case .A: return [("432", 432), ("440", 440)]
        }
    }

    // MARK: - Private State

    private var avEngine: AVAudioEngine?
    private var timePitch: AVAudioUnitTimePitch?
    private var sourceNode: AVAudioSourceNode?
    private var tapObjectID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateDeviceID: AudioObjectID = 0
    fileprivate nonisolated(unsafe) var ioProcID: AudioDeviceIOProcID?
    fileprivate nonisolated(unsafe) var ringBuffer = RingBuffer(capacity: 131072)
    private var statsTimer: DispatchSourceTimer?
    private let logger = RetuneLogger.shared
    private var startRetryCount: Int = 0
    private let maxStartRetries: Int = 3

    fileprivate nonisolated(unsafe) var ioProcCallCount: Int = 0
    fileprivate nonisolated(unsafe) var ioProcNonZeroCount: Int = 0
    fileprivate nonisolated(unsafe) var srcCallCount: Int = 0
    fileprivate nonisolated(unsafe) var srcNonZeroCount: Int = 0

    // Device change & wake handling
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var wakeObserver: Any?
    private var powerObserver: Any?
    private var isHandlingDeviceChange = false
    private var lastKnownDefaultOutput: AudioDeviceID = 0

    // MARK: - Init

    init() {
        loadPersistedSettings()
        refreshOutputDevice()
        lastKnownDefaultOutput = AudioDeviceManager.defaultOutputDeviceID()
        installDeviceListeners()
        registerForWakeNotification()
        setupPowerMonitoring()
        logger.log("[Retune] Log file: \(logger.logPath)")
    }

    private func loadPersistedSettings() {
        let ud = UserDefaults.standard
        if let noteRaw = ud.string(forKey: Self.udNoteKey),
           let note = ReferenceNote(rawValue: noteRaw) {
            // Set backing storage directly to avoid didSet resetting freq
            referenceNote = note
        }
        let freq = ud.float(forKey: Self.udFreqKey)
        if freq > 0 {
            referenceFreq = freq
        }
        let buf = ud.integer(forKey: Self.udBufferKey)
        if buf > 0, Self.bufferSizes.contains(UInt32(buf)) {
            bufferSize = UInt32(buf)
        }
    }

    // MARK: - Device Management

    private func refreshOutputDevice() {
        let def = AudioDeviceManager.defaultOutputDeviceID()
        if !isVirtualDevice(def) {
            outputDeviceID = def
        } else {
            // Fallback to first physical device
            let devices = AudioDeviceManager.allOutputDevices()
            if let physical = devices.first(where: { !isVirtualDevice($0.id) }) {
                outputDeviceID = physical.id
            }
        }
    }

    private func isVirtualDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let name = AudioDeviceManager.deviceName(for: deviceID)?.lowercased() else { return false }
        return name.contains("blackhole") || name.contains("multi") || name.contains("多重") || name.contains("retune")
    }

    private func updatePitch() {
        timePitch?.pitch = centsValue
    }

    // MARK: - Device Change Listener

    private func installDeviceListeners() {
        // Listen for default output device changes (headphone plug/unplug, bluetooth, etc.)
        var defaultOutputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleDefaultOutputChange()
            }
        }
        deviceListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddr,
            DispatchQueue.main,
            defaultBlock
        )

        // Listen for device list changes (devices added/removed)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshOutputDevice()
            }
        }
        devicesListenerBlock = devicesBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            DispatchQueue.main,
            devicesBlock
        )
    }

    private func removeDeviceListeners() {
        if let block = deviceListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
            )
            deviceListenerBlock = nil
        }
        if let block = devicesListenerBlock {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
            )
            devicesListenerBlock = nil
        }
    }

    private func handleDefaultOutputChange() {
        guard !isHandlingDeviceChange else { return }
        isHandlingDeviceChange = true

        let newDefault = AudioDeviceManager.defaultOutputDeviceID()
        lastKnownDefaultOutput = newDefault

        if !isVirtualDevice(newDefault) && newDefault != outputDeviceID {
            logger.log("[Retune] Following default output → \(AudioDeviceManager.deviceName(for: newDefault) ?? "?") (\(newDefault))")
            outputDeviceID = newDefault  // triggers restart via didSet
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isHandlingDeviceChange = false
        }
    }

    // MARK: - Sleep/Wake

    private func registerForWakeNotification() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.handleWake()
            }
        }
    }

    private func handleWake() {
        logger.log("[Retune] System wake detected")
        guard isRunning else { return }
        logger.log("[Retune] Restarting after wake")
        refreshOutputDevice()
        restart()
    }

    // MARK: - Power State

    private func setupPowerMonitoring() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        logger.log("[Retune] Power state: \(isLowPowerMode ? "low power" : "normal"), overlap=\(qualityOverlap)")

        powerObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard lowPower != self.isLowPowerMode else { return }
                self.isLowPowerMode = lowPower
                self.logger.log("[Retune] Power mode changed: \(lowPower ? "low power" : "normal")")
            }
        }
    }

    // MARK: - Start / Stop

    func start() {
        if isRunning { return }
        startRetryCount = 0
        attemptStart()
    }

    private func attemptStart() {
        do {
            try createTap()
            try createAggregateDevice()
            try setupAVEngine()
            try avEngine?.start()
            try startCapture()
            isRunning = true
            logger.log("[Retune] Started. Pitch: \(String(format: "%.1f", centsValue)) cents, output: \(AudioDeviceManager.deviceName(for: outputDeviceID) ?? "?")")
            startStatsTimer()
        } catch {
            logger.log("[Retune] ERROR: \(error)")
            tearDown()
            if startRetryCount < maxStartRetries {
                startRetryCount += 1
                let delay = 0.5 * Double(startRetryCount)
                logger.log("[Retune] Retrying (\(startRetryCount)/\(maxStartRetries)) in \(String(format: "%.1f", delay))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attemptStart()
                }
            }
        }
    }

    func stop() {
        logger.log("[Retune] Stopping...")
        tearDown()
        isRunning = false
        logger.log("[Retune] Stopped")
    }

    private func tearDown() {
        statsTimer?.cancel()
        statsTimer = nil
        stopCapture()
        avEngine?.stop()
        avEngine = nil
        timePitch = nil
        sourceNode = nil
        destroyAggregateDevice()
        destroyTap()
        ringBuffer.reset()
        ioProcCallCount = 0
        ioProcNonZeroCount = 0
        srcCallCount = 0
        srcNonZeroCount = 0
        currentSampleRate = nil
    }

    private func restart() {
        let wasRunning = isRunning
        tearDown()
        isRunning = false
        if wasRunning {
            startRetryCount = 0
            attemptStart()
        }
    }

    // MARK: - Own Process Object ID (to exclude from tap)

    private func getOwnProcessObjectID() throws -> AudioObjectID {
        let pid = getpid()
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propAddr,
            qualifierSize,
            &qualifier,
            &size,
            &processObjectID
        )
        guard status == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw NSError(domain: "Retune", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get process object ID: \(status)"])
        }
        return processObjectID
    }

    // MARK: - Core Audio Tap

    private func createTap() throws {
        if #available(macOS 14.2, *) {
            let selfObjID = try getOwnProcessObjectID()
            tapUUID = UUID()
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObjID])
            desc.uuid = tapUUID
            desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped

            var tid = AudioObjectID(kAudioObjectUnknown)
            let status = AudioHardwareCreateProcessTap(desc, &tid)
            guard status == noErr else {
                throw NSError(domain: "Retune", code: Int(status),
                             userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(status)"])
            }
            tapObjectID = tid
            logger.log("[Retune] Created process tap ID=\(tid)")
        } else {
            throw NSError(domain: "Retune", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "macOS 14.2+ required for system audio tap"])
        }
    }

    private func destroyTap() {
        guard tapObjectID != AudioObjectID(kAudioObjectUnknown) else { return }
        if #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapObjectID)
        }
        tapObjectID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Aggregate Device

    private func getDeviceUID(_ deviceID: AudioDeviceID) throws -> String {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &propAddr, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw NSError(domain: "Retune", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get device UID for \(deviceID): \(status)"])
        }
        return uid as String
    }

    private func createAggregateDevice() throws {
        let outputUID = try getDeviceUID(outputDeviceID)
        logger.log("[Retune] Output UID: \(outputUID)")

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Retune Tap",
            kAudioAggregateDeviceUIDKey as String: "com.retune.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUUID.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard status == noErr else {
            throw NSError(domain: "Retune", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(status)"])
        }
        aggregateDeviceID = aggID
        logger.log("[Retune] Created aggregate device ID=\(aggID)")

        // Explicitly match output device sample rate for best quality
        if let outputRate = AudioDeviceManager.deviceSampleRate(for: outputDeviceID), outputRate > 0 {
            AudioDeviceManager.setDeviceSampleRate(aggregateDeviceID, sampleRate: outputRate)
            logger.log("[Retune] Matched aggregate sample rate to output: \(Int(outputRate)) Hz")
        }

        // Set IO buffer size (user-configurable)
        var bufSize: UInt32 = bufferSize
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let bst = AudioObjectSetPropertyData(aggID, &propAddr, 0, nil,
                                              UInt32(MemoryLayout<UInt32>.size), &bufSize)
        logger.log("[Retune] Set IO buffer size=\(bufSize) status=\(bst)")
    }

    private func destroyAggregateDevice() {
        guard aggregateDeviceID != 0 else { return }
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = 0
    }

    // MARK: - IOProc Capture

    private func startCapture() throws {
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(aggregateDeviceID, { (_, _, inputData, _, _, _, clientData) -> OSStatus in
            guard let clientData = clientData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(clientData).takeUnretainedValue()
            let src = UnsafeMutablePointer(mutating: inputData)
            let bufList = UnsafeMutableAudioBufferListPointer(src)

            engine.ioProcCallCount += 1

            if bufList.count >= 2, let d0 = bufList[0].mData, let d1 = bufList[1].mData {
                let frames = Int(bufList[0].mDataByteSize) / MemoryLayout<Float>.size
                let p0 = d0.assumingMemoryBound(to: Float.self)
                let p1 = d1.assumingMemoryBound(to: Float.self)
                engine.ringBuffer.write(ch0: p0, ch1: p1, frames: frames)
                let check = min(4, frames)
                for i in 0..<check {
                    if abs(p0[i]) > 0 || abs(p1[i]) > 0 { engine.ioProcNonZeroCount += 1; break }
                }
            } else if bufList.count == 1, let data = bufList[0].mData {
                let count = Int(bufList[0].mDataByteSize) / MemoryLayout<Float>.size
                let ptr = data.assumingMemoryBound(to: Float.self)
                engine.ringBuffer.writeInterleaved(ptr, frames: count / 2)
                let check = min(4, count)
                for i in 0..<check {
                    if abs(ptr[i]) > 0 { engine.ioProcNonZeroCount += 1; break }
                }
            }

            return noErr
        }, refCon, &procID)

        guard status == noErr, let pid = procID else {
            throw NSError(domain: "Retune", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create IOProc: \(status)"])
        }
        ioProcID = pid

        let st = AudioDeviceStart(aggregateDeviceID, pid)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, pid)
            ioProcID = nil
            throw NSError(domain: "Retune", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start aggregate device: \(st)"])
        }
        logger.log("[Retune] IOProc started on aggregate device \(aggregateDeviceID)")
    }

    private func stopCapture() {
        if let pid = ioProcID {
            AudioDeviceStop(aggregateDeviceID, pid)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, pid)
        }
        ioProcID = nil
    }

    // MARK: - AVAudioEngine

    private func setupAVEngine() throws {
        let engine = AVAudioEngine()
        let tp = AVAudioUnitTimePitch()
        tp.pitch = centsValue
        tp.rate = 1.0
        tp.overlap = qualityOverlap

        // Max render quality for best pitch shifting
        let au = tp.audioUnit
        var quality: UInt32 = 127  // kRenderQuality_Max
        AudioUnitSetProperty(au, kAudioUnitProperty_RenderQuality,
                             kAudioUnitScope_Global, 0,
                             &quality, UInt32(MemoryLayout<UInt32>.size))

        // Match source format to aggregate device sample rate
        let sampleRate: Float64
        if let sr = AudioDeviceManager.deviceSampleRate(for: aggregateDeviceID), sr > 0 {
            sampleRate = sr
        } else if let sr = AudioDeviceManager.deviceSampleRate(for: outputDeviceID), sr > 0 {
            sampleRate = sr
        } else {
            sampleRate = 48000
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        currentSampleRate = sampleRate

        let rb = ringBuffer
        let refSelf = Unmanaged.passUnretained(self).toOpaque()
        let sn = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let eng = Unmanaged<AudioEngine>.fromOpaque(refSelf).takeUnretainedValue()
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            eng.srcCallCount += 1

            if abl.count >= 2,
               let leftData = abl[0].mData,
               let rightData = abl[1].mData {
                let left = leftData.assumingMemoryBound(to: Float.self)
                let right = rightData.assumingMemoryBound(to: Float.self)
                let read = rb.read(left: left, right: right, frames: Int(frameCount))
                if read > 0 { eng.srcNonZeroCount += 1 }
            }

            return noErr
        }

        engine.attach(tp)
        engine.attach(sn)
        engine.connect(sn, to: tp, format: format)
        engine.connect(tp, to: engine.mainMixerNode, format: format)

        if outputDeviceID != 0, let outputAU = engine.outputNode.audioUnit {
            var devID = outputDeviceID
            let st = AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            logger.log("[Retune] Output device=\(AudioDeviceManager.deviceName(for: devID) ?? "?") status=\(st)")
        }

        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        logger.log("[Retune] Format: source=\(Int(sampleRate))Hz output=\(Int(outFmt.sampleRate))Hz/\(outFmt.channelCount)ch")

        engine.prepare()
        self.avEngine = engine
        self.timePitch = tp
        self.sourceNode = sn
    }

    // MARK: - Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.logger.log("[Retune] STATS io=\(self.ioProcCallCount)/\(self.ioProcNonZeroCount) src=\(self.srcCallCount)/\(self.srcNonZeroCount) rb=\(self.ringBuffer.available)")
        }
        timer.resume()
        statsTimer = timer
    }
}
