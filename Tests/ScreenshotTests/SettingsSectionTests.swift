import SwiftUI
import XCTest
import PanelumiKit
@testable import PanelumiCore

private final class SectionProvider: SettingsSectionProvider, @unchecked Sendable {
    let identifier: String
    private let make: @MainActor () -> [SettingsSection]
    private(set) var reads = 0

    init(_ identifier: String, make: @escaping @MainActor () -> [SettingsSection] = {
        [SettingsSection(id: "page", title: "Extra", symbolName: "square") { AnyView(EmptyView()) }]
    }) {
        self.identifier = identifier
        self.make = make
    }

    @MainActor var sections: [SettingsSection] {
        reads += 1
        return make()
    }
}

@MainActor
final class SettingsSectionTests: XCTestCase {
    func testLaunchOptionsCompareSectionProvidersByIdentifierAndOrder() {
        let first = LaunchOptions(settingsSectionProviders: [SectionProvider("one"), SectionProvider("two")])
        let same = LaunchOptions(settingsSectionProviders: [SectionProvider("one"), SectionProvider("two")])
        let reversed = LaunchOptions(settingsSectionProviders: [SectionProvider("two"), SectionProvider("one")])
        let fewer = LaunchOptions(settingsSectionProviders: [SectionProvider("one")])

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, reversed)
        XCTAssertNotEqual(first, fewer)
        XCTAssertNotEqual(first, LaunchOptions())
    }

    func testSectionsCarryTheirOwnTitleAndSymbol() {
        let section = SettingsSection(id: "pro.x", title: "Pro X", symbolName: "star") { AnyView(EmptyView()) }
        XCTAssertEqual(section.id, "pro.x")
        XCTAssertEqual(section.title, "Pro X")
        XCTAssertEqual(section.symbolName, "star")
    }

    func testSectionsAreBuiltOnlyWhenRead() {
        let provider = SectionProvider("one")
        let options = LaunchOptions(settingsSectionProviders: [provider])
        XCTAssertEqual(provider.reads, 0)
        XCTAssertEqual(options.settingsSectionProviders.count, 1)
        XCTAssertEqual(provider.reads, 0)
        _ = options.settingsSectionProviders[0].sections
        XCTAssertEqual(provider.reads, 1)
    }
}
