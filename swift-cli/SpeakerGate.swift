import Foundation
import AVFoundation

// The user's voice against everyone else's (see Config.speakerThreshold): sherpa-onnx's C library running the CAM++
// zh+en speaker embedding, loaded with dlopen so the app still builds with plain swiftc. install.sh puts the library
// and model in Config.speakerDir; `voice-agent enroll` writes the voiceprint. Without any of them there is no gate
// and Whisper hears everything, as before.
final class SpeakerGate {
    static let shared = SpeakerGate(enrolled: true)
    static var problem = "" // why shared is nil, for the log

    private typealias Create = @convention(c) (UnsafeRawPointer) -> OpaquePointer?
    private typealias Dim = @convention(c) (OpaquePointer) -> Int32
    private typealias CreateStream = @convention(c) (OpaquePointer) -> OpaquePointer?
    private typealias Accept = @convention(c) (OpaquePointer, Int32, UnsafePointer<Float>, Int32) -> Void
    private typealias Finish = @convention(c) (OpaquePointer) -> Void
    private typealias IsReady = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
    private typealias Compute = @convention(c) (OpaquePointer, OpaquePointer) -> UnsafePointer<Float>?
    private typealias FreeEmbedding = @convention(c) (UnsafePointer<Float>) -> Void
    private let createStream: CreateStream, accept: Accept, finish: Finish, isReady: IsReady
    private let compute: Compute, freeEmbedding: FreeEmbedding, destroyStream: Finish
    private let extractor: OpaquePointer
    private let dim: Int
    private let voiceprint: [Float]
    let microphone: String // any part of the name of the input the voiceprint was recorded with, any case

    static var voiceprintURL: URL { URL(fileURLWithPath: Config.speakerDir + "/voiceprint.f32") }
    static var microphoneURL: URL { URL(fileURLWithPath: Config.speakerDir + "/voiceprint.mic") }

    // enrolled: also read the voiceprint (`enroll` makes one, so it does not need it).
    init?(enrolled: Bool) {
        let model = Config.speakerDir + "/campplus.onnx"
        guard FileManager.default.fileExists(atPath: model) else { Self.problem = "no \(model)"; return nil }
        guard let lib = dlopen(Config.speakerDir + "/libsherpa-onnx-c-api.dylib", RTLD_NOW) else {
            Self.problem = String(cString: dlerror()); return nil
        }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("SherpaOnnxCreateSpeakerEmbeddingExtractor", Create.self),
              let dimOf = symbol("SherpaOnnxSpeakerEmbeddingExtractorDim", Dim.self),
              let createStream = symbol("SherpaOnnxSpeakerEmbeddingExtractorCreateStream", CreateStream.self),
              let accept = symbol("SherpaOnnxOnlineStreamAcceptWaveform", Accept.self),
              let finish = symbol("SherpaOnnxOnlineStreamInputFinished", Finish.self),
              let isReady = symbol("SherpaOnnxSpeakerEmbeddingExtractorIsReady", IsReady.self),
              let compute = symbol("SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding", Compute.self),
              let freeEmbedding = symbol("SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding", FreeEmbedding.self),
              let destroyStream = symbol("SherpaOnnxDestroyOnlineStream", Finish.self)
        else { Self.problem = "a function is missing from the library"; return nil }
        // SherpaOnnxSpeakerEmbeddingExtractorConfig: const char *model; int32_t num_threads; int32_t debug;
        // const char *provider (c-api.h, v2.0.1). Two threads: whisper-server holds the GPU, not the CPU.
        let config = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        let modelPath = strdup(model), provider = strdup("cpu")
        defer { config.deallocate(); free(modelPath); free(provider) }
        config.storeBytes(of: UnsafePointer(modelPath), toByteOffset: 0, as: UnsafePointer<CChar>?.self)
        config.storeBytes(of: 2, toByteOffset: 8, as: Int32.self)
        config.storeBytes(of: 0, toByteOffset: 12, as: Int32.self)
        config.storeBytes(of: UnsafePointer(provider), toByteOffset: 16, as: UnsafePointer<CChar>?.self)
        guard let extractor = create(UnsafeRawPointer(config)) else {
            Self.problem = "the model did not load"; return nil
        }
        self.extractor = extractor
        dim = Int(dimOf(extractor))
        (self.createStream, self.accept, self.finish, self.isReady) = (createStream, accept, finish, isReady)
        (self.compute, self.freeEmbedding, self.destroyStream) = (compute, freeEmbedding, destroyStream)
        guard enrolled else { voiceprint = []; microphone = ""; return }
        let saved = (try? Data(contentsOf: Self.voiceprintURL)) ?? Data()
        guard saved.count == dim * MemoryLayout<Float>.size else {
            Self.problem = "no voiceprint for this model: run voice-agent enroll"; return nil
        }
        voiceprint = saved.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        microphone = ((try? String(contentsOf: Self.microphoneURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !microphone.isEmpty else {
            Self.problem = "no microphone for the voiceprint: run voice-agent enroll --mic"; return nil
        }
    }

    // Whether this input is the one the voiceprint was recorded with: on another the user's voice scores lower
    // (a headset recording at 0.06), and the gate would silence them.
    func hears(_ input: String) -> Bool { input.localizedCaseInsensitiveContains(microphone) }

    // The unit-length embedding of these samples (16 kHz), nil when the model could not make one.
    func embedding(_ samples: ArraySlice<Float>) -> [Float]? {
        guard !samples.isEmpty, let stream = createStream(extractor) else { return nil }
        defer { destroyStream(stream) }
        samples.withUnsafeBufferPointer { accept(stream, 16000, $0.baseAddress!, Int32($0.count)) }
        finish(stream)
        guard isReady(extractor, stream) != 0, let values = compute(extractor, stream) else { return nil }
        defer { freeEmbedding(values) }
        let vector = Array(UnsafeBufferPointer(start: values, count: dim))
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : nil
    }

    // The run with the parts only other voices fill silenced (nil: nothing silenced), and what decided it. known: the
    // scores of windows an earlier run of the same recording took, by first frame from `offset` (the run's start):
    // the same audio, so not embedded again.
    func gate(_ samples: [Float], known: [Int: Float?] = [:], offset: Int = 0)
        -> (kept: [Float]?, scores: [Float?], silenced: [Range<Int>]) {
        let starts = Config.speakerWindows(count: samples.count)
        let scores = starts.map { start -> Float? in
            if let score = known[offset + start] { return score }
            let window = samples[start..<start + Config.speakerWindow]
            guard Config.isVoiced(window), let vector = embedding(window) else { return nil }
            return zip(vector, voiceprint).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let silenced = Config.silencedRanges(count: samples.count, starts: starts, scores: scores)
        guard !silenced.isEmpty else { return (nil, scores, []) }
        var kept = samples
        for range in silenced { kept.replaceSubrange(range, with: repeatElement(0, count: range.count)) }
        return (kept, scores, silenced)
    }

    // `voice-agent enroll --mic <name> <wav>…`: the mean of these recordings' embeddings, written as the voiceprint,
    // and the microphone they were recorded with (any part of its name). Recordings of the user alone.
    static func enroll(_ paths: [String], microphone: String) -> (ok: Bool, message: String) {
        guard let gate = SpeakerGate(enrolled: false) else { return (false, "speaker gate unavailable: \(problem)") }
        let vectors = paths.compactMap { readWAV($0).flatMap { gate.embedding($0[...]) } }
        guard vectors.count == paths.count else {
            return (false, "\(paths.count - vectors.count) of \(paths.count) recordings gave no voiceprint "
                + "(not a 16 kHz mono WAV, or too short)")
        }
        let sum = vectors.dropFirst().reduce(vectors[0]) { zip($0, $1).map(+) }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        let voiceprint = sum.map { $0 / norm }
        let data = voiceprint.withUnsafeBufferPointer { Data(buffer: $0) }
        // The old voiceprint goes first: a write failing halfway leaves the gate off, never the new microphone's name
        // gated against the old voiceprint (or the reverse).
        try? FileManager.default.removeItem(at: voiceprintURL)
        guard (try? microphone.write(to: microphoneURL, atomically: true, encoding: .utf8)) != nil,
              (try? data.write(to: voiceprintURL, options: .atomic)) != nil else {
            return (false, "could not write the voiceprint in \(Config.speakerDir)")
        }
        let scores = vectors.map { zip($0, voiceprint).reduce(0) { $0 + $1.0 * $1.1 } }
        return (true, "voiceprint from \(vectors.count) recordings, each scoring "
            + String(format: "%.2f-%.2f", scores.min()!, scores.max()!) + " against it, gating \"\(microphone)\"")
    }

    static func readWAV(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0]
        else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
