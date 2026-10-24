import Foundation

public enum CostEstimate: Sendable, Equatable {
    case available(Decimal)
    case unavailable(String)
}

public struct ModelRate: Sendable, Equatable {
    public let inputPerMillion: Decimal
    public let cachedInputPerMillion: Decimal
    public let outputPerMillion: Decimal
    /// Above this input size, the model's long-context tier applies. The estimator declines
    /// rather than applying the wrong tier.
    public let standardInputCeiling: Int64?

    public init(
        inputPerMillion: Decimal,
        cachedInputPerMillion: Decimal,
        outputPerMillion: Decimal,
        standardInputCeiling: Int64? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
        self.standardInputCeiling = standardInputCeiling
    }
}

/// Estimates API-equivalent cost only for models with a verified, dated standard rate.
/// Unknown models and long-context or fast tiers stay unavailable; they are never zero.
public struct CostEstimator: Sendable {
    public static let priceTableDate = "2026-10-23"
    public static let priceTableSource = URL(string: "https://developers.openai.com/api/docs/pricing")!

    public static let standardRates: [String: ModelRate] = [
        "gpt-5.4": ModelRate(
            inputPerMillion: Decimal(string: "2.50")!,
            cachedInputPerMillion: Decimal(string: "0.25")!,
            outputPerMillion: Decimal(string: "15.00")!,
            standardInputCeiling: 272_000
        ),
        "gpt-5.3-codex": ModelRate(
            inputPerMillion: Decimal(string: "1.75")!,
            cachedInputPerMillion: Decimal(string: "0.175")!,
            outputPerMillion: Decimal(string: "14.00")!
        ),
        "gpt-5.2-codex": ModelRate(
            inputPerMillion: Decimal(string: "1.75")!,
            cachedInputPerMillion: Decimal(string: "0.175")!,
            outputPerMillion: Decimal(string: "14.00")!
        )
    ]

    private let rates: [String: ModelRate]

    public init(rates: [String: ModelRate] = CostEstimator.standardRates) {
        self.rates = rates
    }

    public func estimate(tokens: TokenTotals, model: String?) -> CostEstimate {
        guard let model = normalizedModel(model) else {
            return .unavailable("Model unknown; no verified rate.")
        }
        guard let rate = rates[model] else {
            return .unavailable("No verified rate for \(model).")
        }
        if let ceiling = rate.standardInputCeiling, tokens.input > ceiling {
            return .unavailable("Input exceeds the standard pricing tier for \(model).")
        }

        let cached = min(max(0, tokens.cacheRead), max(0, tokens.input))
        let nonCachedInput = max(0, tokens.input - cached)
        let million = Decimal(1_000_000)
        let cost = Decimal(nonCachedInput) / million * rate.inputPerMillion
            + Decimal(cached) / million * rate.cachedInputPerMillion
            + Decimal(max(0, tokens.output)) / million * rate.outputPerMillion
        return .available(cost)
    }

    private func normalizedModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let lower = model.lowercased()
        if rates[lower] != nil { return lower }
        // Snapshot ids such as gpt-5.4-2026-03-05 use the same standard rates.
        for key in rates.keys where lower.hasPrefix(key + "-") {
            return key
        }
        return lower
    }
}
