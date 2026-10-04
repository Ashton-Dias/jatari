import Foundation
import AVFoundation

struct BuiltInSound: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { "builtin:\(key)" }
    var fileName: String { "\(key).caf" }
}

enum SoundImportError: LocalizedError {
    case unreadable, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: "That file couldn't be read as audio."
        case .empty: "That audio file is empty."
        }
    }
}

/// Built-in tones live in the app bundle; imported ones are converted to CAF and stored in
/// `Library/Sounds`, the folder the system searches for custom alarm/notification sounds.
enum SoundLibrary {
    /// Alarm/notification sounds must be 30 seconds or shorter.
    static let maxDuration: Double = 30

    static let builtIns: [BuiltInSound] = [
        .init(key: "Radar", name: "Radar"), .init(key: "Chimes", name: "Chimes"),
        .init(key: "Beacon", name: "Beacon"), .init(key: "Digital", name: "Digital"),
        .init(key: "GentleRise", name: "Gentle Rise"), .init(key: "Rooster", name: "Rooster"),
        .init(key: "Siren", name: "Siren"),
    ]
    static var defaultSoundID: String { builtIns[0].id }

    static var customDirectory: URL {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func builtIn(for id: String) -> BuiltInSound? { builtIns.first { $0.id == id } }

    /// File name usable with `AlertSound.named` / `UNNotificationSound(named:)`, or nil for the system default.
    static func fileName(for soundID: String, customSounds: [CustomSound]) -> String? {
        if let b = builtIn(for: soundID) { return b.fileName }
        return customSounds.first { $0.soundID == soundID }?.fileName
    }

    static func url(for soundID: String, customSounds: [CustomSound]) -> URL? {
        if let b = builtIn(for: soundID) {
            return Bundle.main.url(forResource: b.key, withExtension: "caf")
                ?? Bundle.main.url(forResource: b.key, withExtension: "caf", subdirectory: "Sounds")
        }
        guard let c = customSounds.first(where: { $0.soundID == soundID }) else { return nil }
        return customDirectory.appending(path: c.fileName)
    }

    static func displayName(for soundID: String, customSounds: [CustomSound]) -> String {
        builtIn(for: soundID)?.name ?? customSounds.first { $0.soundID == soundID }?.name ?? "Default"
    }

    /// Reads any supported audio file, trims it to `maxDuration`, and writes a CAF into `Library/Sounds`.
    static func importSound(from source: URL, name: String) throws -> CustomSound {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let input = try? AVAudioFile(forReading: source) else { throw SoundImportError.unreadable }
        let format = input.processingFormat
        let total = input.length
        guard total > 0 else { throw SoundImportError.empty }
        let sampleRate = format.sampleRate
        let maxFrames = AVAudioFramePosition(maxDuration * sampleRate)
        let framesToCopy = min(total, maxFrames)

        let fileName = "\(UUID().uuidString).caf"
        let dest = customDirectory.appending(path: fileName)
        let output = try AVAudioFile(forWriting: dest, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)

        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw SoundImportError.unreadable }
        var copied: AVAudioFramePosition = 0
        while copied < framesToCopy {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), framesToCopy - copied))
            try input.read(into: buffer, frameCount: n)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            copied += AVAudioFramePosition(buffer.frameLength)
        }
        let trimmed = total > maxFrames
        let duration = Double(copied) / sampleRate
        return CustomSound(name: name, fileName: fileName, duration: duration, wasTrimmed: trimmed)
    }

    static func delete(_ sound: CustomSound) {
        try? FileManager.default.removeItem(at: customDirectory.appending(path: sound.fileName))
    }
}
