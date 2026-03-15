//
//  TermplexTitleUITests.swift
//  TermplexUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class TermplexTitleUITests: TermplexCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(#"title = "TermplexUITestsLaunchTests""#)
    }

    @MainActor
    func testTitle() throws {
        let app = try termplexApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "TermplexUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
