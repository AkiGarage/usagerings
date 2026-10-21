import Foundation

public struct StableSemanticVersion: Hashable, Comparable, Codable, Sendable {
    public let major: UInt
    public let minor: UInt
    public let patch: UInt

    public init?(tag: String) {
        guard tag.first == "v" else { return nil }
        let components = tag.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }

        var numbers: [UInt] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  component == "0" || component.first != "0",
                  let number = UInt(component)
            else { return nil }
            numbers.append(number)
        }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
    }

    public var tag: String {
        "v\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let tag = try container.decode(String.self)
        guard let value = Self(tag: tag) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a strict stable semantic version"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tag)
    }
}
