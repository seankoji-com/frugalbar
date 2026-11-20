import Testing
import Foundation
@testable import QuotaBarCore

/// Counts fetches without touching a wall clock, so a test can prove a
/// configured figure was read without another poll.
private final class CreditCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// Holds the current configured credit between reads, so a test can change it
/// without building a second manager.
private final class CreditLookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: GeminiAPICredit?

    init(_ value: GeminiAPICredit?) { stored = value }

    var value: GeminiAPICredit? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct GeminiCreditProvider: QuotaProvider {
    var vendorId: VendorIdentifier = .gemini
    var displayName = "Gemini"
    var category: MetricCategory = .aiSubscriptions
    /// When true, the first fetch succeeds and every later one fails, which is
    /// the retention path.
    var failsAfterFirst = false
    var alwaysFails = false
    var counter: CreditCallCounter?

    func fetchSnapshot() async throws -> QuotaSnapshot {
        let attempt = (counter?.value ?? 0) + 1
        counter?.increment()
        if alwaysFails || (failsAfterFirst && attempt > 1) { throw ProviderError(.offline) }
        return QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category,
            metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil, lastUpdated: Date(timeIntervalSince1970: 1_800_000_000),
            auxiliaryInfo: nil,
            row1: DualBarMetrics(primaryFraction: 0.25, label: "5H", windowLength: QuotaWindow.fiveHours))
    }
}

private struct FixedVendorProvider: QuotaProvider {
    let vendorId: VendorIdentifier
    var displayName: String { vendorId.displayName }
    let category: MetricCategory = .aiSubscriptions

    func fetchSnapshot() async throws -> QuotaSnapshot {
        QuotaSnapshot(
            id: vendorId.rawValue, vendorId: vendorId, displayName: displayName,
            category: category, metric: .subscription(tierName: "Google AI Pro", renewalDate: nil),
            status: .measured(.none), resetsAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 1_800_000_000), auxiliaryInfo: nil)
    }
}

@Suite("Configured Gemini API credit in the engine")
struct GeminiAPICreditManagerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func credit(_ balance: String = "12") throws -> GeminiAPICredit {
        try #require(GeminiAPICredit(
            currencyCode: "AUD",
            prepaidBalance: Decimal(string: balance),
            monthlyCredit: Decimal(string: "7.50"),
            monthlySpendCap: Decimal(string: "25"),
            configuredAt: now))
    }

    @Test("the configured credit rides Gemini's row and no other Antigravity pool")
    func attachesToGeminiOnly() async throws {
        let configured = try credit()
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider(), FixedVendorProvider(vendorId: .antigravityArgon)] },
            geminiCreditLookup: { configured })

        let snapshots = await manager.refresh()
        #expect(snapshots["gemini"]?.geminiAPICredit == configured)
        #expect(snapshots["antigravity_argon"]?.geminiAPICredit == nil)
        #expect(await manager.cachedSnapshots()["gemini"]?.geminiAPICredit == configured)
        let sorted = await manager.sortedSnapshots()
        #expect(sorted.first { $0.vendorId == .gemini }?.geminiAPICredit == configured)
        #expect(sorted.first { $0.vendorId == .antigravityArgon }?.geminiAPICredit == nil)
    }

    @Test("a changed configured credit is read without polling the vendor again")
    func updatesWithoutPolling() async throws {
        let counter = CreditCallCounter()
        let box = CreditLookupBox(try credit("12"))
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider(counter: counter)] },
            geminiCreditLookup: { box.value })

        #expect(await manager.refresh()["gemini"]?.geminiAPICredit == (try credit("12")))
        #expect(counter.value == 1)

        box.value = try credit("5")
        #expect(await manager.cachedSnapshots()["gemini"]?.geminiAPICredit == (try credit("5")))
        #expect(await manager.sortedSnapshots().first?.geminiAPICredit == (try credit("5")))
        #expect(counter.value == 1)
    }

    @Test("a configured credit shows while quota is unavailable, without making it measured")
    func survivesAnUnavailableReading() async throws {
        let configured = try credit()
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider(alwaysFails: true)] },
            geminiCreditLookup: { configured })

        let snapshots = await manager.refresh()
        let gemini = try #require(snapshots["gemini"])
        #expect(gemini.status.unavailableReason != nil)
        #expect(gemini.geminiAPICredit == configured)
        #expect(gemini.quotaBars.isEmpty)
    }

    @Test("a retained reading after a failed poll keeps the configured credit")
    func retentionKeepsIt() async throws {
        let configured = try credit()
        let counter = CreditCallCounter()
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider(failsAfterFirst: true, counter: counter)] },
            geminiCreditLookup: { configured })

        let first = await manager.refresh()
        #expect(first["gemini"]?.status.confidence == .measured)
        let retained = await manager.forceRefresh()
        #expect(retained["gemini"]?.staleReading?.reason == .offline)
        #expect(retained["gemini"]?.geminiAPICredit == configured)
        #expect(counter.value == 2)
    }

    @Test("the attached credit adds no API-credit entry and no balance-history point")
    func attachedCreditStaysOutOfApiCredits() async throws {
        let configured = try credit()
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider()] },
            geminiCreditLookup: { configured })

        let gemini = try #require(await manager.refresh()["gemini"])
        #expect(gemini.geminiAPICredit == configured)
        // The configured figure must not ride `apiCredits`: that array is what
        // `BalanceSeries` charts, so carrying it there would record a typed
        // number as a vendor reading.
        #expect(gemini.apiCredits.isEmpty)
        #expect(BalanceSeries.all(of: gemini).isEmpty)
    }

    @Test("the configured credit leaves Antigravity's block order alone")
    func antigravityOrderingUnchanged() async throws {
        let configured = try credit()
        let providers: @Sendable () -> [any QuotaProvider] = {
            [GeminiCreditProvider(),
             FixedVendorProvider(vendorId: .antigravityClaude),
             FixedVendorProvider(vendorId: .antigravityArgon)]
        }
        let withCredit = QuotaManager(providerFactory: providers,
                                      geminiCreditLookup: { configured })
        let without = QuotaManager(providerFactory: providers)

        _ = await withCredit.refresh()
        _ = await without.refresh()
        let a = await withCredit.sortedSnapshots().map(\.vendorId)
        let b = await without.sortedSnapshots().map(\.vendorId)
        #expect(a == b)
        #expect(a == [.gemini, .antigravityClaude, .antigravityArgon])
        #expect(await withCredit.sortedSnapshots().first?.geminiAPICredit == configured)
    }

    @Test("hiding Gemini hides its configured credit with it")
    func hiddenGeminiDrawsNoCredit() async throws {
        let configured = try credit()
        let manager = QuotaManager(
            providerFactory: { [GeminiCreditProvider()] },
            displayPreferences: { ProviderDisplayPreferences(hidden: [.gemini]) },
            geminiCreditLookup: { configured })

        #expect(await manager.refresh()["gemini"] == nil)
    }

    @Test("nothing is attached when no credit was configured")
    func noLookupDrawsNothing() async throws {
        let manager = QuotaManager(providerFactory: { [GeminiCreditProvider()] })
        #expect(await manager.refresh()["gemini"]?.geminiAPICredit == nil)
    }
}
