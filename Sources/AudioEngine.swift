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
    private static let udAutoBufferKey = "autoBuffer"
    private static let udBufferPerRateKey = "bufferSizePerRate"

    static let bufferSizes: [UInt32] = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]

    @Published var isRunning = false
    @Published var referenceNote: ReferenceNote = .A {
        didSet {
            referenceFreq = switch referenceNote { case .C: 256; case .A: 432 }
            UserDefaults.standard.set(referenceNote.rawValue, forKey: Self.udNoteKey)
        }
    }

    // Store user's actual choice
    private var storedReferenceFreq: Float = 432

    @Published var referenceFreq: Float = 432 {
        didSet {
            // Only store if running (user's actual choice)
            if isRunning || isRestarting {
                storedReferenceFreq = referenceFreq
                UserDefaults.standard.set(referenceFreq, forKey: Self.udFreqKey)
            }
            updateFromReference()
        }
    }
    @Published private(set) var targetA: Float = 432
    private var outputDeviceID: AudioDeviceID = 0 {
        didSet {
            guard oldValue != outputDeviceID, oldValue != 0 else { return }
            if isRunning || isRestarting { restart() }
        }
    }
    private var suppressBufferRestart = false
    @Published var bufferSize: UInt32 = 512 {
        didSet {
            UserDefaults.standard.set(Int(bufferSize), forKey: Self.udBufferKey)
            if !suppressBufferRestart && (isRunning || isRestarting) { restart() }
        }
    }
    @Published var isAutoBuffer: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoBuffer, forKey: Self.udAutoBufferKey)
        }
    }
    /// Per-sample-rate manual buffer sizes: [sampleRateInt: bufferFrames]
    private var bufferSizePerRate: [Int: UInt32] = [:]
    @Published var currentSampleRate: Float64?
    @Published private(set) var isLowPowerMode: Bool = false

    var bufferLatencyMs: Double {
        let sr = currentSampleRate ?? 48000
        return Double(bufferSize) / sr * 1000.0
    }

    var bufferLatencyLabel: String {
        String(format: "%.1f ms", bufferLatencyMs)
    }

    /// Smallest power-of-2 buffer that gives >= 20ms latency at the given rate.
    static func autoBufferSize(forRate sampleRate: Float64) -> UInt32 {
        let minFrames = sampleRate * 20.0 / 1000.0
        var buf: UInt32 = 16
        while Double(buf) < minFrames { buf <<= 1 }
        return min(buf, 16384)
    }

    /// Called by UI when user manually drags the buffer slider.
    func setManualBuffer(_ size: UInt32) {
        isAutoBuffer = false
        bufferSize = size
        if let rate = currentSampleRate {
            let rateKey = Int(rate)
            bufferSizePerRate[rateKey] = size
            persistBufferPerRate()
        }
    }

    /// Re-enable auto buffer and immediately apply.
    func enableAutoBuffer() {
        isAutoBuffer = true
        let rate = currentSampleRate ?? 48000
        let auto = Self.autoBufferSize(forRate: rate)
        bufferSize = auto
    }

    /// Apply the correct buffer size for a given sample rate (called during start).
    private func applyBufferForRate(_ sampleRate: Float64) {
        let rateKey = Int(sampleRate)
        let newSize: UInt32
        if isAutoBuffer {
            newSize = Self.autoBufferSize(forRate: sampleRate)
        } else if let stored = bufferSizePerRate[rateKey] {
            newSize = stored
        } else {
            // No stored value for this rate → switch to auto
            isAutoBuffer = true
            newSize = Self.autoBufferSize(forRate: sampleRate)
        }
        suppressBufferRestart = true
        bufferSize = newSize
        suppressBufferRestart = false
    }

    private func persistBufferPerRate() {
        let dict = Dictionary(uniqueKeysWithValues: bufferSizePerRate.map { (String($0.key), Int($0.value)) })
        UserDefaults.standard.set(dict, forKey: Self.udBufferPerRateKey)
    }

    var centsValue: Float {
        1200.0 * log2f(targetA / 440.0)
    }

    private func updateFromReference() {
        targetA = switch referenceNote {
        case .C: referenceFreq * powf(2.0, 9.0 / 12.0)
        case .A: referenceFreq
        }
        updatePitch()
    }

    var referenceLabel: String {
        switch referenceNote { case .C: "C4"; case .A: "A4" }
    }

    var referenceRange: ClosedRange<Float> {
        switch referenceNote { case .C: 240...270; case .A: 410...460 }
    }

    var referencePresets: [(String, Float)] {
        switch referenceNote {
        case .C: [("256", 256), ("261", 261)]
        case .A: [("415", 415), ("432", 432), ("440", 440), ("443", 443)]
        }
    }

    /// Named tuning standards for display.
    static let tuningReferences: [(name: String, a4: Float, note: String)] = [
        ("Baroque", 415, "A4 = 415 Hz"),
        ("Verdi", 432, "A4 = 432 Hz"),
        ("European", 443, "A4 = 443 Hz"),
        ("Scientific", 430.54, "C4 = 256 Hz"),
    ]

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
    private let logger = PitchShiftLogger.shared
    private var startRetryCount: Int = 0
    private let maxStartRetries: Int = 5

    fileprivate let ioProcCallCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    fileprivate let ioProcNonZeroCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    fileprivate let srcCallCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    fileprivate let srcNonZeroCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)

    // Device change & wake handling
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredDeviceForRate: AudioDeviceID = 0
    private var wakeObserver: Any?
    private var willSleepObserver: Any?
    private var screenSleepObserver: Any?
    private var screenWakeObserver: Any?
    private var powerObserver: Any?
    private var isHandlingDeviceChange = false
    private var wasRunningBeforeSleep = false
    private var isScreenAsleep = false
    private var lastKnownDefaultOutput: AudioDeviceID = 0
    private var restartWorkItem: DispatchWorkItem?
    @Published private(set) var isRestarting = false

    // MARK: - Init

    init() {
        ioProcCallCount.initialize(to: 0)
        ioProcNonZeroCount.initialize(to: 0)
        srcCallCount.initialize(to: 0)
        srcNonZeroCount.initialize(to: 0)
        loadPersistedSettings()
        // Start with A=440 displayed (disabled state)
        referenceNote = .A
        referenceFreq = 440
        refreshOutputDevice()
        lastKnownDefaultOutput = AudioDeviceManager.defaultOutputDeviceID()
        installDeviceListeners()
        registerForWakeNotification()
        setupPowerMonitoring()
        logger.log("[PitchShift] Log file: \(logger.logPath)")
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
            storedReferenceFreq = freq
            referenceFreq = freq
        }
        // Load auto buffer preference (default true)
        if ud.object(forKey: Self.udAutoBufferKey) != nil {
            isAutoBuffer = ud.bool(forKey: Self.udAutoBufferKey)
        }
        // Load per-rate buffer sizes
        if let dict = ud.dictionary(forKey: Self.udBufferPerRateKey) as? [String: Int] {
            for (key, val) in dict {
                if let rateKey = Int(key) {
                    bufferSizePerRate[rateKey] = UInt32(val)
                }
            }
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
        return name.contains("blackhole") || name.contains("multi") || name.contains("多重") || name.contains("pitchshift")
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
            logger.log("[PitchShift] Following default output → \(AudioDeviceManager.deviceName(for: newDefault) ?? "?") (\(newDefault))")
            outputDeviceID = newDefault  // triggers restart via didSet
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isHandlingDeviceChange = false
        }
    }

    // MARK: - Sample Rate Change Listener

    private func installSampleRateListener(for deviceID: AudioDeviceID) {
        removeSampleRateListener()
        monitoredDeviceForRate = deviceID

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.handleSampleRateChange()
            }
        }
        sampleRateListenerBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block)
    }

    private func removeSampleRateListener() {
        if let block = sampleRateListenerBlock, monitoredDeviceForRate != 0 {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(monitoredDeviceForRate, &addr, DispatchQueue.main, block)
            sampleRateListenerBlock = nil
            monitoredDeviceForRate = 0
        }
    }

    private func handleSampleRateChange() {
        guard isRunning || isRestarting else { return }
        if let newRate = AudioDeviceManager.deviceSampleRate(for: outputDeviceID) {
            logger.log("[PitchShift] Output sample rate changed → \(Int(newRate)) Hz")
            restart()
        }
    }

    // MARK: - Sleep/Wake

    private func registerForWakeNotification() {
        // Stop engine cleanly before system sleeps to prevent CoreAudio corruption
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleWillSleep()
            }
        }

        // Restart engine after system wakes
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.handleWake()
            }
        }

        // Track screen sleep/wake for diagnostics
        screenSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleScreenSleep()
            }
        }

        // Track screen wake for diagnostics
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleScreenWake()
            }
        }
    }

    private func handleWillSleep() {
        logger.log("[PitchShift] System will sleep")
        wasRunningBeforeSleep = isRunning || isRestarting
        if wasRunningBeforeSleep {
            logger.log("[PitchShift] Stopping engine before sleep")
            restartWorkItem?.cancel()
            restartWorkItem = nil
            isRestarting = false
            tearDown()
            // Keep isRunning true so UI doesn't flicker
        }
    }

    private func handleWake() {
        logger.log("[PitchShift] System wake detected")
        isScreenAsleep = false
        if wasRunningBeforeSleep {
            wasRunningBeforeSleep = false
            logger.log("[PitchShift] Restarting engine after wake")
            refreshOutputDevice()
            startRetryCount = 0
            attemptStart()
        }
    }

    private func handleScreenSleep() {
        guard !isScreenAsleep else { return }
        isScreenAsleep = true
        logger.log("[PitchShift] Screen asleep")
    }

    private func handleScreenWake() {
        guard isScreenAsleep else { return }
        isScreenAsleep = false
        logger.log("[PitchShift] Screen awake")
    }

    // MARK: - Power State

    private func setupPowerMonitoring() {
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        logger.log("[PitchShift] Power state: \(isLowPowerMode ? "low power" : "normal"), overlap=\(qualityOverlap)")

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
                self.logger.log("[PitchShift] Power mode changed: \(lowPower ? "low power" : "normal")")
            }
        }
    }

    // MARK: - Start / Stop

    func start() {
        if isRunning { return }
        startRetryCount = 0
        // Restore user's stored frequency
        referenceFreq = storedReferenceFreq
        attemptStart()
    }

    private func attemptStart() {
        do {
            try createTap()

            // Determine sample rate before creating aggregate so buffer can be sized correctly
            let sampleRate: Float64
            if let sr = AudioDeviceManager.deviceSampleRate(for: outputDeviceID), sr > 0 {
                sampleRate = sr
            } else {
                sampleRate = 48000
            }
            applyBufferForRate(sampleRate)

            try createAggregateDevice()
            try setupAVEngine()
            try avEngine?.start()
            try startCapture()
            installSampleRateListener(for: outputDeviceID)
            isRunning = true
            logger.log("[PitchShift] Started. Pitch: \(String(format: "%.1f", centsValue)) cents, buffer=\(bufferSize), output: \(AudioDeviceManager.deviceName(for: outputDeviceID) ?? "?")")
            startStatsTimer()
        } catch {
            logger.log("[PitchShift] ERROR: \(error)")
            tearDown()
            if startRetryCount < maxStartRetries {
                startRetryCount += 1
                let delay = 0.5 * Double(startRetryCount)
                logger.log("[PitchShift] Retrying (\(startRetryCount)/\(maxStartRetries)) in \(String(format: "%.1f", delay))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attemptStart()
                }
            } else {
                logger.log("[PitchShift] Failed to start after \(maxStartRetries) retries")
                isRunning = false
                isRestarting = false
            }
        }
    }

    func stop() {
        wasRunningBeforeSleep = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        isRestarting = false
        logger.log("[PitchShift] Stopping...")
        tearDown()
        isRunning = false
        // Reset to A=440 when stopped
        referenceNote = .A
        referenceFreq = 440
        logger.log("[PitchShift] Stopped")
    }

    func toggle() {
        if isRunning || isRestarting {
            stop()
        } else {
            start()
        }
    }

    private func tearDown() {
        statsTimer?.cancel()
        statsTimer = nil
        removeSampleRateListener()
        stopCapture()
        avEngine?.stop()
        avEngine = nil
        timePitch = nil
        sourceNode = nil
        destroyAggregateDevice()
        destroyTap()
        ringBuffer.reset()
        ioProcCallCount.pointee = 0
        ioProcNonZeroCount.pointee = 0
        srcCallCount.pointee = 0
        srcNonZeroCount.pointee = 0
        currentSampleRate = nil
    }

    /// Coalesced restart: tears down immediately, then re-starts after a short
    /// delay so Core Audio can fully release the old aggregate device and tap.
    /// Multiple calls within the delay window are coalesced into one restart.
    /// isRunning stays true so the UI toggle doesn't flicker.
    private func restart() {
        let shouldRestart = isRunning || isRestarting

        // Cancel any previously scheduled restart
        restartWorkItem?.cancel()
        restartWorkItem = nil

        tearDown()
        // Do NOT set isRunning = false — the user didn't stop it

        guard shouldRestart else { return }

        isRestarting = true
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.isRestarting = false
            self.restartWorkItem = nil
            self.startRetryCount = 0
            self.attemptStart()
        }
        restartWorkItem = work
        // 0.4s gives Core Audio enough time to release the old resources
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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
            throw NSError(domain: "PitchShift", code: Int(status),
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
                throw NSError(domain: "PitchShift", code: Int(status),
                             userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(status)"])
            }
            tapObjectID = tid
            logger.log("[PitchShift] Created process tap ID=\(tid)")
        } else {
            throw NSError(domain: "PitchShift", code: -1,
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
            throw NSError(domain: "PitchShift", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to get device UID for \(deviceID): \(status)"])
        }
        return uid as String
    }

    private func createAggregateDevice() throws {
        let outputUID = try getDeviceUID(outputDeviceID)
        logger.log("[PitchShift] Output UID: \(outputUID)")

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "PitchShift Tap",
            kAudioAggregateDeviceUIDKey as String: "com.pitchshift.tap.\(UUID().uuidString)",
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
            throw NSError(domain: "PitchShift", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(status)"])
        }
        aggregateDeviceID = aggID
        logger.log("[PitchShift] Created aggregate device ID=\(aggID)")

        // Explicitly match output device sample rate for best quality
        if let outputRate = AudioDeviceManager.deviceSampleRate(for: outputDeviceID), outputRate > 0 {
            AudioDeviceManager.setDeviceSampleRate(aggregateDeviceID, sampleRate: outputRate)
            logger.log("[PitchShift] Matched aggregate sample rate to output: \(Int(outputRate)) Hz")
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
        logger.log("[PitchShift] Set IO buffer size=\(bufSize) status=\(bst)")
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

            engine.ioProcCallCount.pointee &+= 1

            if bufList.count >= 2, let d0 = bufList[0].mData, let d1 = bufList[1].mData {
                let frames = Int(bufList[0].mDataByteSize) / MemoryLayout<Float>.size
                let p0 = d0.assumingMemoryBound(to: Float.self)
                let p1 = d1.assumingMemoryBound(to: Float.self)
                engine.ringBuffer.write(ch0: p0, ch1: p1, frames: frames)
                let check = min(4, frames)
                for i in 0..<check {
                    if abs(p0[i]) > 0 || abs(p1[i]) > 0 { engine.ioProcNonZeroCount.pointee &+= 1; break }
                }
            } else if bufList.count == 1, let data = bufList[0].mData {
                let count = Int(bufList[0].mDataByteSize) / MemoryLayout<Float>.size
                let ptr = data.assumingMemoryBound(to: Float.self)
                engine.ringBuffer.writeInterleaved(ptr, frames: count / 2)
                let check = min(4, count)
                for i in 0..<check {
                    if abs(ptr[i]) > 0 { engine.ioProcNonZeroCount.pointee &+= 1; break }
                }
            }

            return noErr
        }, refCon, &procID)

        guard status == noErr, let pid = procID else {
            throw NSError(domain: "PitchShift", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create IOProc: \(status)"])
        }
        ioProcID = pid

        let st = AudioDeviceStart(aggregateDeviceID, pid)
        guard st == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, pid)
            ioProcID = nil
            throw NSError(domain: "PitchShift", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to start aggregate device: \(st)"])
        }
        logger.log("[PitchShift] IOProc started on aggregate device \(aggregateDeviceID)")
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
            eng.srcCallCount.pointee &+= 1

            if abl.count >= 2,
               let leftData = abl[0].mData,
               let rightData = abl[1].mData {
                let left = leftData.assumingMemoryBound(to: Float.self)
                let right = rightData.assumingMemoryBound(to: Float.self)
                let read = rb.read(left: left, right: right, frames: Int(frameCount))
                if read > 0 { eng.srcNonZeroCount.pointee &+= 1 }
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
            logger.log("[PitchShift] Output device=\(AudioDeviceManager.deviceName(for: devID) ?? "?") status=\(st)")
        }

        let outFmt = engine.outputNode.outputFormat(forBus: 0)
        logger.log("[PitchShift] Format: source=\(Int(sampleRate))Hz output=\(Int(outFmt.sampleRate))Hz/\(outFmt.channelCount)ch")

        engine.prepare()
        self.avEngine = engine
        self.timePitch = tp
        self.sourceNode = sn
    }

    // MARK: - Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10, repeating: 60.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.logger.log("[PitchShift] STATS io=\(self.ioProcCallCount.pointee)/\(self.ioProcNonZeroCount.pointee) src=\(self.srcCallCount.pointee)/\(self.srcNonZeroCount.pointee) rb=\(self.ringBuffer.available)")
        }
        timer.resume()
        statsTimer = timer
    }
}
