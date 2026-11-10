import Testing
@testable import RecorderSummary

@Test func summaryLineClassifiesHeadingsParagraphsAndBlankLines() {
    #expect(SummaryLine.classify("## 概要") == .heading("概要"))
    #expect(SummaryLine.classify("## **振り返り**") == .heading("**振り返り**"))
    #expect(SummaryLine.classify("通常の **強調** を含む段落") == .paragraph("通常の **強調** を含む段落"))
    #expect(SummaryLine.classify("  段落の空白  ") == .paragraph("  段落の空白  "))
    for line in ["", "  ", "\t", "\r"] { #expect(SummaryLine.classify(line) == .blank) }
    #expect(SummaryLine.classify("## 概要\r") == .heading("概要"))
}

@Test func summaryLineClassifiesBothBulletMarkersAndTwoSpaceNesting() {
    for marker in ["- ", "* "] {
        for depth in 0...3 {
            let line = String(repeating: "  ", count: depth) + marker + "**項目**"
            #expect(SummaryLine.classify(line) == .bullet(text: "**項目**", depth: depth))
        }
    }
    #expect(SummaryLine.classify("   - 項目") == .bullet(text: "項目", depth: 1))
}

@Test func summaryLineDoesNotMisclassifyOtherPrefixes() {
    for line in ["### 見出し", "##見出し", "  ## 見出し", "-区切り", "*強調*", "1. 項目", "途中の - 記号"] {
        #expect(SummaryLine.classify(line) == .paragraph(line))
    }
}
