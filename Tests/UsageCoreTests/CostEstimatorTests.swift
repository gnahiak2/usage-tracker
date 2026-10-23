import Foundation
import XCTest
@testable import UsageCore

final class CostEstimatorTests: XCTestCase {
    private let estimator = CostEstimator()

    private func estimate(
        model: String?,
        input: Int64,
        cached: Int64 = 0,
        output: Int64 = 0
    ) -> CostEstimate {
        estimator.estimate(
            tokens: TokenTotals(input: input, output: output, cacheRead: cached),
            model: model
        )
    }

    func testKnownModelUsesStandardRate() {
        let result = estimate(model: "gpt-5.3-codex", input: 1_000_000)
        XCTAssertEqual(result, .available(Decimal(string: "1.75")!))
    }

    func testCachedInputUsesDiscountedRate() {
        let result = estimate(model: "gpt-5.4", input: 200_000, cached: 200_000)
        XCTAssertEqual(result, .available(Decimal(string: "0.05")!))
    }

    func testOutputUsesOutputRate() {
        let result = estimate(model: "gpt-5.3-codex", input: 0, output: 1_000_000)
        XCTAssertEqual(result, .available(Decimal(string: "14.00")!))
    }

    func testSnapshotModelIDsReuseBaseRate() {
        let result = estimate(model: "gpt-5.4-2026-03-05", input: 200_000)
        XCTAssertEqual(result, .available(Decimal(string: "0.50")!))
    }

    func testUnknownModelStaysUnavailable() {
        guard case .unavailable(let reason) = estimate(model: "some-new-model", input: 1_000) else {
            return XCTFail("Expected an unavailable estimate")
        }
        XCTAssertTrue(reason.contains("some-new-model"))
    }

    func testMissingModelStaysUnavailable() {
        guard case .unavailable = estimate(model: nil, input: 1_000) else {
            return XCTFail("Expected an unavailable estimate")
        }
    }

    func testLongContextTierIsDeclined() {
        guard case .unavailable(let reason) = estimate(model: "gpt-5.4", input: 300_000) else {
            return XCTFail("Expected the long-context tier to be declined")
        }
        XCTAssertTrue(reason.contains("standard pricing tier"))
    }

    func testCachedTokensAboveInputAreClamped() {
        let result = estimate(model: "gpt-5.4", input: 1_000, cached: 5_000)
        XCTAssertEqual(result, .available(Decimal(string: "0.00025")!))
    }
}
