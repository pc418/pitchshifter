import Foundation
import Accelerate

/// Dual-channel ring buffer for non-interleaved stereo audio.
/// Uses Accelerate-backed bulk copies for real-time performance.
/// Capacity (in frames) is rounded up to next power of 2 for bitmask optimization.
final class RingBuffer {
    private let bufferL: UnsafeMutablePointer<Float>
    private let bufferR: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private var readPos: Int = 0
    private var writePos: Int = 0
    private var _count: Int = 0
    private var lock = os_unfair_lock()

    /// Number of stereo frames available for reading.
    var available: Int {
        os_unfair_lock_lock(&lock)
        let c = _count
        os_unfair_lock_unlock(&lock)
        return c
    }

    init(capacity: Int) {
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.bufferL = .allocate(capacity: cap)
        self.bufferR = .allocate(capacity: cap)
        bufferL.initialize(repeating: 0, count: cap)
        bufferR.initialize(repeating: 0, count: cap)
    }

    deinit {
        bufferL.deinitialize(count: capacity)
        bufferL.deallocate()
        bufferR.deinitialize(count: capacity)
        bufferR.deallocate()
    }

    /// Write stereo frames from two separate channel pointers (non-interleaved).
    /// Uses memcpy for bulk copy. Zero heap allocation.
    func write(ch0: UnsafePointer<Float>, ch1: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        let pos = writePos & mask
        let first = min(frames, capacity - pos)
        let bytes = first * MemoryLayout<Float>.size

        memcpy(bufferL.advanced(by: pos), ch0, bytes)
        memcpy(bufferR.advanced(by: pos), ch1, bytes)

        let second = frames - first
        if second > 0 {
            let bytes2 = second * MemoryLayout<Float>.size
            memcpy(bufferL, ch0.advanced(by: first), bytes2)
            memcpy(bufferR, ch1.advanced(by: first), bytes2)
        }

        writePos &+= frames
        let newCount = _count + frames
        if newCount > capacity {
            // Overflow: discard oldest data so reader stays on contiguous audio
            readPos &+= (newCount - capacity)
            _count = capacity
        } else {
            _count = newCount
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Write interleaved stereo from a single buffer (L0 R0 L1 R1 ...).
    /// Deinterleaves into dual-channel storage using vDSP stride copy. Zero heap allocation.
    func writeInterleaved(_ src: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        let pos = writePos & mask
        let first = min(frames, capacity - pos)

        var zero: Float = 0
        // Copy every 2nd sample (stride 2 → 1) for L and R channels
        vDSP_vsadd(src,                    2, &zero, bufferL.advanced(by: pos), 1, vDSP_Length(first))
        vDSP_vsadd(src.advanced(by: 1),    2, &zero, bufferR.advanced(by: pos), 1, vDSP_Length(first))

        let second = frames - first
        if second > 0 {
            let offset = first * 2
            vDSP_vsadd(src.advanced(by: offset),     2, &zero, bufferL, 1, vDSP_Length(second))
            vDSP_vsadd(src.advanced(by: offset + 1), 2, &zero, bufferR, 1, vDSP_Length(second))
        }

        writePos &+= frames
        let newCount2 = _count + frames
        if newCount2 > capacity {
            readPos &+= (newCount2 - capacity)
            _count = capacity
        } else {
            _count = newCount2
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Read stereo frames into separate L/R output buffers.
    /// Returns number of frames read. Uses memcpy + vDSP_vclr. Zero heap allocation.
    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let avail = min(frames, _count)
        let pos = readPos & mask
        let first = min(avail, capacity - pos)
        let bytes = first * MemoryLayout<Float>.size

        memcpy(left, bufferL.advanced(by: pos), bytes)
        memcpy(right, bufferR.advanced(by: pos), bytes)

        let second = avail - first
        if second > 0 {
            let bytes2 = second * MemoryLayout<Float>.size
            memcpy(left.advanced(by: first), bufferL, bytes2)
            memcpy(right.advanced(by: first), bufferR, bytes2)
        }

        // Zero-fill remaining frames with Accelerate
        let silence = frames - avail
        if silence > 0 {
            vDSP_vclr(left.advanced(by: avail), 1, vDSP_Length(silence))
            vDSP_vclr(right.advanced(by: avail), 1, vDSP_Length(silence))
        }

        readPos &+= avail
        _count -= avail
        os_unfair_lock_unlock(&lock)
        return avail
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readPos = 0
        writePos = 0
        _count = 0
        os_unfair_lock_unlock(&lock)
    }
}
