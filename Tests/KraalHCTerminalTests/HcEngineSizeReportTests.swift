// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHCTerminal

@Suite("Engine size report filter")
struct HcEngineSizeReportTests {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    @Test("recognises the engine's own report")
    func recognises() {
        #expect(HcEngineSizeReport.isReport(data("\u{1B}[48;24;80;444;680t")))
        #expect(HcEngineSizeReport.isReport(data("\u{1B}[48;1;1;0;0t")))
    }

    @Test("a keystroke is not a report")
    func keystroke() {
        #expect(HcEngineSizeReport.isReport(data("a")) == false)
        #expect(HcEngineSizeReport.isReport(data("\u{1B}")) == false)
    }

    @Test("a paste that merely starts like a report is left alone")
    func paste() {
        #expect(HcEngineSizeReport.isReport(data("\u{1B}[48;24;80;444;680t and text")) == false)
        #expect(HcEngineSizeReport.isReport(data("\u{1B}[48;24;80;444t")) == false)
        #expect(HcEngineSizeReport.isReport(data("\u{1B}[48;24;;80;444t")) == false)
    }
}
