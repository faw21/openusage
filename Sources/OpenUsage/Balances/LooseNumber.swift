import Foundation

/// A JSON money field whose *type* the billing APIs keep changing: OpenAI's Costs API ships
/// `amount.value` as a high-precision number today and shipped it as a decimal string before; Anthropic's
/// cost report ships `amount` as a decimal string today. A decoder that insists on one form turns a
/// perfectly good 200 into a decode failure — which is exactly how the OpenAI card came to read
/// "HTTP 200" instead of the month's spend. Accept both forms and let each feed apply its own unit
/// (OpenAI bills in dollars, Anthropic in cents).
struct LooseNumber: Decodable, Sendable, Equatable {
    let double: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            double = number
            return
        }
        let text = try container.decode(String.self)
        guard let parsed = Double(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a decimal number: \(text)")
        }
        double = parsed
    }
}
