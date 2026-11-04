import Foundation
import OmoUsageCore
import Testing
@testable import OmoUsage

@Suite
struct ClaudeAPIBalanceTests {
    @Test(arguments: [
        (#"{"amount":25000,"currency":"USD","promo_tranches":[{"remaining_amount_minor_units":20000}]}"#, 250.0),
        (#"{"amount":0,"currency":"USD"}"#, 0.0),
        (#"{"amount":2599,"promo_tranches":[]}"#, 25.99),
        (#"{"amount":0,"promo_tranches":[]}"#, 0.0),
        (#"{"amount":1250,"balance":{"money":{"currency":"USD","exponent":3}}}"#, 1.25),
        (#"{"amount":1250,"currency":"usd","balance":{"credits":{"exponent":3}}}"#, 1.25),
        (#"{"amount":125,"currency":"USD","balance":{"money":{"exponent":0}}}"#, 125.0)
    ])
    func totalUsesBalanceWithoutAddingPromotionalTranches(
        payload: String,
        expected: Double
    ) throws {
        let meter = try #require(
            ClaudeUsageParser.apiBalanceMeter([Data(payload.utf8)])
        )
        #expect(meter.metric == .credit(balance: expected, unit: .usd))
        #expect(meter.resetText == nil)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"amount":null,"currency":"USD"}"#,
        #"{"amount":true,"currency":"USD"}"#,
        #"{"amount":-1,"currency":"USD"}"#,
        #"{"amount":100,"currency":"EUR"}"#,
        #"{"amount":100,"currency":true}"#,
        #"{"amount":100,"balance":{"money":{"currency":"EUR","exponent":2}}}"#,
        #"{"amount":100,"currency":"USD","balance":{"credits":{"exponent":1.5}}}"#,
        #"{"amount":100,"currency":"USD","balance":{"credits":{"exponent":5}}}"#,
        #"{"amount":1e20,"currency":"USD"}"#
    ])
    func invalidOrganizationPreventsMisleadingPartialTotal(payload: String) {
        let valid = Data(#"{"amount":100,"currency":"USD"}"#.utf8)
        #expect(ClaudeUsageParser.apiBalanceMeter(
            [valid, Data(payload.utf8)]
        ) == nil)
    }

    @Test
    func totalCombinesOrganizationsButNotAccounts() async throws {
        let now = Date(timeIntervalSince1970: 1_785_675_000)
        let first = AccountProviderID(accountID: AccountID(), providerID: .claude)
        let second = AccountProviderID(accountID: AccountID(), providerID: .claude)
        let cache = ClaudeAPICreditCache()
        await cache.record([
            Data(#"{"amount":12500,"currency":"USD"}"#.utf8),
            Data(#"{"amount":2500,"currency":"USD"}"#.utf8)
        ], for: first, at: now)
        await cache.record([
            Data(#"{"amount":700,"currency":"USD"}"#.utf8)
        ], for: second, at: now)

        let firstPayloads = try #require(await cache.payloads(for: first, at: now))
        let secondPayloads = try #require(await cache.payloads(for: second, at: now))
        #expect(ClaudeUsageParser.apiBalanceMeter(firstPayloads)?.metric
            == .credit(balance: 150, unit: .usd))
        #expect(ClaudeUsageParser.apiBalanceMeter(secondPayloads)?.metric
            == .credit(balance: 7, unit: .usd))
        #expect(ClaudeUsageParser.apiBalanceMeter([]) == nil)
    }
}
