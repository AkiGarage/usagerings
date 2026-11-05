import XCTest
import os
@testable import CodexUsageWidget

final class SourcePolicyTests: XCTestCase {
    private static let cliOnly: Set<ProviderID> = [.antigravity, .grok, .claude]

    func testEveryProviderHasAnExplicitSourcePolicy() {
        for provider in ProviderID.allCases {
            let expected = Self.cliOnly.contains(provider) ? ["--source", "cli"] : []
            XCTAssertEqual(MultiUsageService.sourceArguments(provider), expected, provider.rawValue)
        }
    }

    func testEveryDisabledSubsetFetchesOnlyEnabledProvidersThroughCLISources() async {
        let providers = ProviderID.allCases
        for mask in 0..<(1 << providers.count) {
            let disabled = Set(providers.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
            let service = MultiUsageService(commandRunner: { arguments in
                calls.withLock { $0.append(arguments) }
                return .init(terminationStatus: 1, stdout: Data(), stderr: Data())
            }, retryDelay: 0)
            let snapshot = await service.fetchAll(disabled: disabled)
            let recorded = calls.withLock { $0 }
            for arguments in recorded {
                let provider = try? XCTUnwrap(ProviderID(rawValue: arguments[2]))
                guard let provider else { XCTFail("unknown provider \(arguments)"); continue }
                XCTAssertFalse(disabled.contains(provider), "disabled \(provider) was fetched")
                if Self.cliOnly.contains(provider) {
                    let source = arguments.firstIndex(of: "--source").map { arguments[$0 + 1] }
                    XCTAssertEqual(source, "cli", "\(provider) must use --source cli")
                }
                XCTAssertFalse(arguments.contains { $0.lowercased().contains("cookie") || $0 == "web" })
            }
            let hasClaude = snapshot.sections.contains { $0.provider == .claude }
            XCTAssertEqual(hasClaude, !disabled.contains(.claude), "mask \(mask)")
        }
    }
}
