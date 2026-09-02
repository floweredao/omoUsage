import Foundation
import Testing
@testable import OmoUsage
@testable import OmoUsageCore

@Suite
struct PhonePairingPresentationTests {
    @Test
    func pairButtonAtomicallyCreatesPresentedItem() throws {
        var state = PhonePairingPresentationState()
        let url = try #require(URL(string: "https://example.com/pair/one-use"))

        #expect(state.presentedItem == nil)
        let failureKey = state.pairButtonAtomicallyCreatesPresentedItem {
            url
        }

        #expect(state.presentedItem?.url == url)
        #expect(failureKey == nil)
    }

    @Test
    func pairButtonLeavesItemNilAndReturnsFailureKeyWhenURLCreationFails() {
        var state = PhonePairingPresentationState()

        #expect(state.presentedItem == nil)
        let failureKey = state.pairButtonAtomicallyCreatesPresentedItem {
            nil as URL?
        }

        #expect(state.presentedItem == nil)
        #expect(failureKey == .phonePairingFailed)
    }
}
