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
    /// Outstanding `start()` calls. The source runs while at least one is held, so calibration
    /// and control can hand over without stopping and restarting the stream in between.
    private var holders = 0
    /// Blocks are queued here by the source's thread and drained by one task, so they reach the
    /// processor in arrival order. (A `Task` per block would not guarantee that: the rectify →
    /// average → FIR chain is order-dependent.)
    private var inbox: AsyncStream<EMGBlock>.Continuation?
    private var drain: Task<Void, Never>?

    public init(source: EMGSource, outputRate: Double = 200) {
        self.source = source
        processor = QuasiTensionProcessor(inputRate: source.sampleRate, channelCount: source.channelCount, outputRate: outputRate)
        self.outputRate = processor.outputRate
    }

    public nonisolated var channelCount: Int { source.channelCount }

    public func addRawSink(_ sink: @escaping @Sendable (EMGBlock) -> Void) { rawSinks.append(sink) }
    public func addQuasiTensionSink(_ sink: @escaping @Sendable (QuasiTensionSample) -> Void) { qtSinks.append(sink) }
    public func removeAllSinks() { rawSinks.removeAll(); qtSinks.removeAll() }

    /// Start the source, or join it if it is already running. Balance every call with `stop()`.
    public func start() async throws {
        holders += 1
        // Claim the running state before suspending, so a second start that arrives while the
        // source is still connecting does not start the source twice.
        guard !isRunning else { return }
        isRunning = true
        processor.reset()
        latest = nil
        let (stream, continuation) = AsyncStream.makeStream(of: EMGBlock.self, bufferingPolicy: .unbounded)
        inbox = continuation
        drain = Task { [weak self] in
            for await block in stream {
                guard let self else { return }
                await self.ingest(block)
            }
        }
        do {
            try await source.start { block in
                continuation.yield(block)
            }
        } catch {
            isRunning = false
            holders = 0
            closeInbox()
            throw error
        }
    }

    private func closeInbox() {
        inbox?.finish()
        inbox = nil
        drain = nil
    }

    /// Release one `start()`. The source stops when the last holder releases it.
    public func stop() async {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, isRunning else { return }
        isRunning = false
        await source.stop()
        closeInbox()
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
        calibration = MinMaxCalibration(channelCount: pipeline.channelCount, sampleRate: pipeline.outputRate)
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
        calibration = MinMaxCalibration(channelCount: pipeline.channelCount, sampleRate: pipeline.outputRate)
        isRunning = true
        do {
            try await pipeline.start()
        } catch {
            isRunning = false
            throw error
        }
    }

    /// Releases the pipeline and returns the calibrated range.
    public func stop() async -> ActivationRange {
        if isRunning {
            isRunning = false
            await pipeline.stop()
        }
        return calibration.finish()
    }

    public var progress: (elapsed: Double, range: ActivationRange?) {
        (calibration.elapsedSeconds, calibration.range)
    }
}
