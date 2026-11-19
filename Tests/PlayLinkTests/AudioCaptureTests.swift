import XCTest
import AVFoundation
import Darwin
@testable import PlayLink

final class AudioCaptureTests: XCTestCase {
    func testPlanarFloatCaptureBecomesStereoSignedPCM() throws {
        let pipe = Pipe()
        let capture = AudioCapture()
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        let sample = try makeSample(left: 0.25, right: -0.5)
        let copied = try XCTUnwrap(SystemAudioTap.copyBufferList(sample.audioBufferList, format: sample.format))
        capture.process(copied)
        let data = pipe.fileHandleForReading.readData(ofLength: 3840)
        XCTAssertEqual(data.count, 3840)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            XCTAssertEqual(Int(samples[0]), 8192, accuracy: 1)
            XCTAssertEqual(Int(samples[1]), -16384, accuracy: 1)
            XCTAssertEqual(Int(samples[1918]), 8192, accuracy: 1)
        }
    }

    func testInterleavedTapBufferReachesTheDiscordPCMPipe() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 2, interleaved: true)!
        let sample = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        sample.frameLength = 960
        for index in 0..<960 {
            sample.floatChannelData![0][index * 2] = 0.25
            sample.floatChannelData![0][index * 2 + 1] = -0.5
        }
        let copied = try XCTUnwrap(SystemAudioTap.copyBufferList(sample.audioBufferList, format: format))
        XCTAssertEqual(copied.frameLength, 960)
        let pipe = Pipe()
        let capture = AudioCapture()
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        capture.process(copied)
        let data = pipe.fileHandleForReading.readData(ofLength: 3840)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            XCTAssertEqual(Int(samples[0]), 8192, accuracy: 1)
            XCTAssertEqual(Int(samples[1]), -16384, accuracy: 1)
        }
    }

    func testVolumeIsAppliedBeforeSending() throws {
        let pipe = Pipe()
        let capture = AudioCapture()
        capture.setGain(0.5)
        // attachPipe synchronizes the audio queue after the gain update.
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        capture.process(try makeSample(left: 0.5, right: -0.5))
        let data = pipe.fileHandleForReading.readData(ofLength: 3840)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            XCTAssertEqual(Int(samples[0]), 8192, accuracy: 1)
            XCTAssertEqual(Int(samples[1]), -8192, accuracy: 1)
        }
    }

    func testFullPipeDropsFramesWithoutBlockingCapture() throws {
        let pipe = Pipe()
        let capture = AudioCapture()
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        let sample = try makeSample(left: 0.25, right: -0.25)
        let start = Date()
        for _ in 0..<300 { capture.process(sample) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let reader = pipe.fileHandleForReading.fileDescriptor
        XCTAssertEqual(fcntl(reader, F_SETFL, O_NONBLOCK), 0)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(reader, &bytes, bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        // Resume after pressure; the unfinished frame must precede new samples.
        capture.process(sample)
        try pipe.fileHandleForWriting.close()
        data.append(pipe.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(data.count % 3840, 0)
        XCTAssertLessThan(data.count, 300 * 3840)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            for index in stride(from: 0, to: samples.count, by: 2) {
                XCTAssertEqual(Int(samples[index]), 8192, accuracy: 1)
                XCTAssertEqual(Int(samples[index + 1]), -8192, accuracy: 1)
            }
        }
    }

    func testMacVolumeMultipliesTheAppLevelBeforeSending() throws {
        let pipe = Pipe()
        let capture = AudioCapture()
        capture.setGain(0.5)
        capture.setOutputGain(0.5)
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        capture.process(try makeSample(left: 0.5, right: -0.5))
        let data = pipe.fileHandleForReading.readData(ofLength: 3840)
        data.withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            XCTAssertEqual(Int(samples[0]), 4096, accuracy: 1)
            XCTAssertEqual(Int(samples[1]), -4096, accuracy: 1)
        }
    }

    func testMacMuteAndUnmuteApplyWithoutRestartingCapture() throws {
        let pipe = Pipe()
        let capture = AudioCapture()
        capture.setOutputGain(0)
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        let sample = try makeSample(left: 0.5, right: -0.5)
        capture.process(sample)
        XCTAssertTrue(pipe.fileHandleForReading.readData(ofLength: 3840).allSatisfy { $0 == 0 })
        capture.setOutputGain(0.5)
        try capture.attachPipe(pipe.fileHandleForWriting.fileDescriptor)
        capture.process(sample)
        pipe.fileHandleForReading.readData(ofLength: 3840).withUnsafeBytes { bytes in
            let samples = bytes.bindMemory(to: Int16.self)
            XCTAssertEqual(Int(samples[0]), 8192, accuracy: 1)
            XCTAssertEqual(Int(samples[1]), -8192, accuracy: 1)
        }
    }

    private func makeSample(left: Float, right: Float) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                   channels: 2, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        pcm.frameLength = 960
        for index in 0..<960 {
            pcm.floatChannelData![0][index] = left
            pcm.floatChannelData![1][index] = right
        }
        return pcm
    }
}
