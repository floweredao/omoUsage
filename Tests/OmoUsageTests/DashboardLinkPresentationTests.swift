import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct DashboardLinkPresentationTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func qrLoadingTransitionsToReadyAfterGenerationSignal() async throws {
        let gate = QRGenerationEventGate()
        let sampleData = Data([0x01, 0x02, 0x03])
        let loader = WebDashboardQRCodeLoader { url in
            #expect(url.scheme == "https")
            await gate.signalStarted()
            return await gate.waitForData()
        }
        let url = try #require(
            URL(string: "https://example.com/bootstrap?token=test")
        )

        await gate.subscribeToStartedEvent()
        let loadTask = Task { await loader.load(url: url) }
        await gate.waitForStartedEvent()
        #expect(loader.phase == .loading)

        await gate.release(data: sampleData)
        await loadTask.value
        #expect(loader.phase == .ready(sampleData))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func cancelledQRLoadingDoesNotPublishReady() async throws {
        let gate = QRGenerationEventGate()
        let sampleData = Data([0x01, 0x02, 0x03])
        let loader = WebDashboardQRCodeLoader { url in
            #expect(url.scheme == "https")
            await gate.signalStarted()
            return await gate.waitForData()
        }
        let url = try #require(
            URL(string: "https://example.com/bootstrap?token=test")
        )

        await gate.subscribeToStartedEvent()
        let loadTask = Task { await loader.load(url: url) }
        await gate.waitForStartedEvent()
        #expect(loader.phase == .loading)

        loadTask.cancel()
        await gate.release(data: sampleData)
        await loadTask.value
        #expect(loader.phase == .loading)
    }

    @Test
    func qrButtonAtomicallyCreatesPresentedItem() throws {
        var state = WebDashboardLinkPresentationState()
        let url = try #require(
            URL(string: "https://example.com/bootstrap?token=qr")
        )

        #expect(state.presentedItem == nil)
        let failureKey = state.openQRCode {
            url
        }

        #expect(state.presentedItem?.url == url)
        #expect(failureKey == nil)
    }

    @Test
    func qrButtonLeavesItemNilAndReturnsFailureKeyWhenURLCreationFails() {
        var state = WebDashboardLinkPresentationState()

        #expect(state.presentedItem == nil)
        let failureKey = state.openQRCode {
            nil as URL?
        }

        #expect(state.presentedItem == nil)
        #expect(failureKey == .webDashboardLinkCreationFailed)
    }

    @Test
    func shareButtonMintsAndPresentsExactlyOneFreshURL() throws {
        let state = WebDashboardLinkPresentationState()
        let url = try #require(
            URL(string: "https://example.com/bootstrap?token=share")
        )
        var generationCount = 0
        var sharedURLs: [URL] = []

        let failureKey = state.shareLink(
            makeURL: {
                generationCount += 1
                return url
            },
            present: {
                sharedURLs.append($0)
                return true
            }
        )

        #expect(generationCount == 1)
        #expect(sharedURLs == [url])
        #expect(state.presentedItem == nil)
        #expect(failureKey == nil)
    }

    @Test
    func shareButtonReportsFailureWithoutPresentingStaleURL() throws {
        var state = WebDashboardLinkPresentationState()
        let staleURL = try #require(
            URL(string: "https://example.com/bootstrap?token=stale")
        )
        _ = state.openQRCode { staleURL }
        var sharedURLs: [URL] = []

        let failureKey = state.shareLink(
            makeURL: { nil },
            present: {
                sharedURLs.append($0)
                return true
            }
        )

        #expect(sharedURLs.isEmpty)
        #expect(state.presentedItem?.url == staleURL)
        #expect(failureKey == .webDashboardLinkCreationFailed)
    }
}

private actor QRGenerationEventGate {
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let startedEvents: AsyncStream<Void>
    private let dataContinuation: AsyncStream<Data>.Continuation
    private let dataEvents: AsyncStream<Data>
    private var startedSubscribed = false

    init() {
        (startedEvents, startedContinuation) =
            AsyncStream.makeStream(of: Void.self)
        (dataEvents, dataContinuation) =
            AsyncStream.makeStream(of: Data.self)
    }

    func subscribeToStartedEvent() {
        startedSubscribed = true
    }

    func signalStarted() {
        precondition(startedSubscribed)
        startedContinuation.yield(())
    }

    func waitForStartedEvent() async {
        for await _ in startedEvents {
            return
        }
    }

    func release(data: Data) {
        dataContinuation.yield(data)
    }

    func waitForData() async -> Data? {
        for await data in dataEvents {
            return data
        }
        return nil
    }
}
