import Foundation

/// Runs an `EMGSource` through a `QuasiTensionProcessor` and fans out both the raw blocks
/// and the 200 Hz quasi-tension samples. Shared by calibration and control.
public actor QuasiTensionPipeline {
    public nonisolated let source: EMGSource
    public nonisolated let outputRate: Double
    private var processor: QuasiTensionProcessor
    private var rawSinks: [@Sendable (EMGBlock) -> Void] = []
    private var qtSinks: [@Sendable (QuasiTensionSample) -> Void] = []
    public private(set) var isRunning = false
    public private(set) var latest: QuasiTensionSample?

    public init(source: EMGSource, outputRate: Double = 200) {
        self.source = source
        processor = QuasiTensionProcessor(inputRate: source.sampleRate, channelCount: source.channelCount, outputRate: outputRate)
        self.outputRate = processor.outputRate
    }

    public nonisolated var channelCount: Int { source.channelCount }

    public func addRawSink(_ sink: @escaping @Sendable (EMGBlock) -> Void) { rawSinks.append(sink) }
    public func addQuasiTensionSink(_ sink: @escaping @Sendable (QuasiTensionSample) -> Void) { qtSinks.append(sink) }
    public func removeAllSinks() { rawSinks.removeAll(); qtSinks.removeAll() }

    public func start() async throws {
        guard !isRunning else { return }
        processor.reset()
        latest = nil
        try await source.start { [weak self] block in
            guard let self else { return }
            Task { await self.ingest(block) }
        }
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        await source.stop()
    }

    private func ingest(_ block: EMGBlock) {
        guard isRunning else { return }
        for sink in rawSinks { sink(block) }
        for sample in processor.process(block) {
            latest = sample
            for sink in qtSinks { sink(sample) }
        }
    }
}

/// Min/max calibration driven by a pipeline: start, have the user relax and contract, stop.
public actor ActivationCalibrator {
    public let pipeline: QuasiTensionPipeline
    private var calibration: MinMaxCalibration
    public private(set) var isRunning = false

    public init(pipeline: QuasiTensionPipeline) async {
        self.pipeline = pipeline
        calibration = MinMaxCalibration(channelCount: await pipeline.channelCount, sampleRate: pipeline.outputRate)
        await pipeline.addQuasiTensionSink { [weak self] sample in
            guard let self else { return }
            Task { await self.add(sample) }
        }
    }

    private func add(_ sample: QuasiTensionSample) {
        guard isRunning else { return }
        calibration.add(sample)
    }

    public func start() async throws {
        calibration = MinMaxCalibration(channelCount: await pipeline.channelCount, sampleRate: pipeline.outputRate)
        isRunning = true
        try await pipeline.start()
    }

    /// Stops the source and returns the calibrated range.
    public func stop() async -> ActivationRange {
        isRunning = false
        await pipeline.stop()
        return calibration.finish()
    }

    public var progress: (elapsed: Double, range: ActivationRange?) {
        (calibration.elapsedSeconds, calibration.range)
    }
}
