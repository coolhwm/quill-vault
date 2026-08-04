import Testing

@testable import Application

@Suite("Minutes markdown line parser")
struct MinutesMarkdownLineParserTests {
  @Test("Parses headings, lists, code fences, and GFM tables")
  func parsesRichMarkdown() {
    let input = """
      # 总结

      - 要点一
      - [ ] 待办

      ```swift
      let x = 1
      ```

      | 角色 | 结论 |
      | --- | --- |
      | 采销 | 二级单位 |
      | 运营 | 确认 |

      [04:40] 章节标题
      """
    let lines = MinutesMarkdownLineParser.lines(from: input)
    #expect(lines.contains { if case .heading(1, "总结") = $0 { true } else { false } })
    #expect(lines.contains { if case .bullet("要点一") = $0 { true } else { false } })
    #expect(lines.contains { if case .task(false, "待办") = $0 { true } else { false } })
    #expect(
      lines.contains {
        if case .code(let source) = $0 { source.contains("let x = 1") } else { false }
      }
    )
    #expect(
      lines.contains {
        if case .table(let rows) = $0 {
          rows.count == 3 && rows[0] == ["角色", "结论"] && rows[1][0] == "采销"
        } else {
          false
        }
      }
    )
    #expect(
      lines.contains {
        if case .chapterSeek(let seconds, let stamp, let title) = $0 {
          abs(seconds - 280) < 0.001 && stamp == "[04:40]" && title == "章节标题"
        } else {
          false
        }
      }
    )
  }
}
