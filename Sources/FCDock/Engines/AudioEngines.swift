import AVFoundation
import Foundation

/// Audio through macOS's built-in `afconvert` (Core Audio). It can't encode MP3, OGG, Opus or WMA.
struct AfconvertEngine: Engine {
    let name = "afconvert"

    private static let inputs: Set<FileFormat> = [.mp3, .m4a, .aac, .wav, .aiff, .flac, .caf, .amr, .ac3]
    private static let outputs: Set<FileFormat> = [.m4a, .aac, .wav, .aiff, .flac, .alac]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        Self.inputs.contains(from) && Self.outputs.contains(to) && from != to ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        // Keep 24-bit when going lossless → lossless; lossy sources gain nothing past 16-bit.
        let bits = [.wav, .aiff, .flac, .caf].contains(from) ? 24 : 16

        // High-quality VBR AAC isn't available at every sample rate (e.g. 22 kHz), so fall back to
        // 128 kbps, then to whatever the encoder picks (very low sample rates cap the bitrate).
        let aacQualities = [["-s", "3", "-u", "vbrq", "100"], ["-s", "0", "-b", "128000"], []]
        let attempts: [[String]]
        switch to {
        case .m4a: attempts = aacQualities.map { ["-f", "m4af", "-d", "aac"] + $0 }
        case .aac: attempts = aacQualities.map { ["-f", "adts", "-d", "aac"] + $0 }
        case .wav: attempts = [["-f", "WAVE", "-d", "LEI\(bits)"]]
        case .aiff: attempts = [["-f", "AIFF", "-d", "BEI\(bits)"]]
        case .flac: attempts = [["-f", "flac", "-d", "flac"]]
        case .alac: attempts = [["-f", "m4af", "-d", "alac"]]
        default: throw ConversionError.unsupported(input.lastPathComponent)
        }

        var lastError: Error?
        for options in attempts {
            do {
                try await ProcessRunner.run("/usr/bin/afconvert", options + [input.path, output.path])
                return
            } catch {
                try? FileManager.default.removeItem(at: output)
                lastError = error
            }
        }
        throw lastError ?? ConversionError.exportFailed("afconvert failed")
    }
}

/// Everything else audio, plus animated images → video.
struct FFmpegEngine: Engine {
    let name = "FFmpeg"
    var tool: Tool? { .ffmpeg }

    private static let audioInputs: Set<FileFormat> = [
        .mp3, .wav, .flac, .aac, .m4a, .ogg, .opus, .wma, .aiff, .ape, .amr, .caf, .ac3, .dts, .dsd,
    ]
    private static let audioOutputs: [FileFormat: [String]] = [
        .mp3: ["-c:a", "libmp3lame", "-q:a", "2"],
        .wav: ["-c:a", "pcm_s16le"],
        .flac: ["-c:a", "flac"],
        .aac: ["-c:a", "aac", "-b:a", "192k", "-f", "adts"],
        .m4a: ["-c:a", "aac", "-b:a", "192k"],
        .ogg: hasEncoder("libvorbis")
            ? ["-c:a", "libvorbis", "-q:a", "5"]
            // Homebrew's FFmpeg ships without libvorbis; its own encoder is experimental and stereo-only.
            : ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2", "-q:a", "5"],
        .opus: ["-c:a", "libopus", "-b:a", "160k"],
        .wma: ["-c:a", "wmav2", "-b:a", "192k"],
        .aiff: ["-c:a", "pcm_s16be"],
        .alac: ["-c:a", "alac"],
    ]
    /// Asks the installed FFmpeg which encoders it was built with.
    private static func hasEncoder(_ name: String) -> Bool {
        guard Tool.ffmpeg.isInstalled else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Tool.ffmpeg.path)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.contains(" \(name) ")
    }

    private static let animatedInputs: Set<FileFormat> = [.gif, .apng]
    private static let videoOutputs: Set<FileFormat> = [.mp4, .webm, .gif, .apng]

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        guard from != to else { return nil }
        if Self.audioInputs.contains(from), Self.audioOutputs[to] != nil {
            // afconvert does its formats just as well without a download.
            return 15
        }
        if Self.animatedInputs.contains(from), Self.videoOutputs.contains(to) {
            return to.isImage ? 20 : 10
        }
        return nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path]
        if var codec = Self.audioOutputs[to] {
            // Keep 24-bit from lossless and DSD sources rather than squeezing them to 16-bit.
            if [.dsd, .flac, .wav, .aiff, .ape].contains(from) {
                if to == .wav { codec = ["-c:a", "pcm_s24le"] }
                if to == .aiff { codec = ["-c:a", "pcm_s24be"] }
            }
            // -vn drops embedded cover art, which most of these containers can't hold.
            arguments += ["-vn", "-map_metadata", "0"] + codec
        } else {
            // Video encoders need even dimensions.
            let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
            switch to {
            case .mp4: arguments += ["-vf", even, "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
            case .webm: arguments += ["-vf", even, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-pix_fmt", "yuva420p"]
            case .apng: arguments += ["-f", "apng", "-plays", "0"]
            case .gif: arguments += ["-vf", "split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
            default: throw ConversionError.unsupported(input.lastPathComponent)
            }
        }
        try await ProcessRunner.run(Tool.ffmpeg.path, arguments + [output.path])
    }
}

/// MIDI → WAV with macOS's built-in General MIDI synthesiser, rendered faster than real time.
struct MIDIEngine: Engine {
    let name = "MIDI synth"

    func rank(_ from: FileFormat, _ to: FileFormat) -> Int? {
        from == .midi && to == .wav ? 10 : nil
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: URL) async throws {
        try await MainActor.run { try Self.render(input, to: output) }
    }

    @MainActor
    private static func render(_ input: URL, to output: URL) throws {
        let engine = AVAudioEngine()
        // The multi-timbral GM synth, so every channel keeps its own instrument.
        let synth = AVAudioUnitMIDIInstrument(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: kAudioUnitSubType_MIDISynth,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        engine.attach(synth)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(synth, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: input, options: [])
        for track in sequencer.tracks { track.destinationAudioUnit = synth }
        let length = sequencer.tracks.map { $0.lengthInSeconds }.max() ?? 0
        guard length > 0 else { throw ConversionError.unreadable(input.lastPathComponent) }

        try engine.start()
        sequencer.prepareToPlay()
        try sequencer.start()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        // Two seconds past the last note lets reverb and long notes ring out.
        let totalFrames = AVAudioFramePosition((length + 2) * format.sampleRate)
        while engine.manualRenderingSampleTime < totalFrames {
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(totalFrames - engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try file.write(from: buffer)
        }
        sequencer.stop()
        engine.stop()
    }
}
