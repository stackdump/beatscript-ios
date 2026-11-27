import BeatScriptEngine
import SwiftUI

/// Colours of the editor, the site's dark theme.
enum Palette {
  static let background = Color(red: 0.07, green: 0.08, blue: 0.10)
  static let panel = Color(red: 0.11, green: 0.12, blue: 0.15)
  static let text = Color(red: 0.86, green: 0.88, blue: 0.90)
  static let dim = Color(red: 0.55, green: 0.58, blue: 0.62)
  static let accent = Color(red: 0.98, green: 0.73, blue: 0.20)
  static let error = Color(red: 0.95, green: 0.38, blue: 0.36)
  static let ok = Color(red: 0.45, green: 0.82, blue: 0.50)

  #if canImport(UIKit)
    static func ui(_ c: Color) -> UIColor { UIColor(c) }
    /// btw_highlight's classes.
    static func token(_ cls: String) -> UIColor {
      switch cls {
      case "comment": return UIColor(white: 0.45, alpha: 1)
      case "keyword": return UIColor(red: 0.78, green: 0.55, blue: 0.95, alpha: 1)
      case "role": return UIColor(red: 0.45, green: 0.75, blue: 0.98, alpha: 1)
      case "action": return UIColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1)
      case "deck": return UIColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1)
      case "number": return UIColor(red: 0.60, green: 0.90, blue: 0.70, alpha: 1)
      case "step": return UIColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
      case "rest": return UIColor(white: 0.40, alpha: 1)
      case "generator": return UIColor(red: 0.40, green: 0.85, blue: 0.85, alpha: 1)
      case "param": return UIColor(red: 0.70, green: 0.78, blue: 0.95, alpha: 1)
      case "operator": return UIColor(white: 0.65, alpha: 1)
      default: return UIColor(white: 0.86, alpha: 1)
      }
    }
  #endif
}

#if canImport(UIKit)
  import UIKit

  /// The program text: highlighted by the engine (`btw_highlight`), its running lines lit from the engine's
  /// marks, and, with Follow on, scrolled to keep the line that plays in view.
  struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var marks: BeatscriptMarks?
    var follow: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
      let v = UITextView()
      v.backgroundColor = UIColor(Palette.background)
      v.textColor = UIColor(Palette.text)
      v.font = Coordinator.font
      v.autocapitalizationType = .none
      v.autocorrectionType = .no
      v.smartQuotesType = .no
      v.smartDashesType = .no
      v.spellCheckingType = .no
      v.keyboardType = .asciiCapable
      v.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
      v.delegate = context.coordinator
      v.accessibilityIdentifier = "editor"
      return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
      let c = context.coordinator
      c.parent = self
      if v.text != text {
        let sel = v.selectedRange
        v.text = text
        v.selectedRange = NSRange(location: min(sel.location, (text as NSString).length), length: 0)
        c.highlightedFor = nil
      }
      c.paint(v, marks: marks)
      if follow, let line = marks?.activeLines.first {
        c.follow(v, to: line)
      }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: CodeEditor
      var highlightedFor: String?
      var highlights: [BeatscriptHighlight] = []
      var litKey = ""
      var followedLine: UInt32 = 0
      static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

      init(_ p: CodeEditor) { parent = p }

      func textViewDidChange(_ v: UITextView) {
        parent.text = v.text
      }

      /// Token colours (recomputed when the text changes) and the marks over them.
      func paint(_ v: UITextView, marks: BeatscriptMarks?) {
        let text = v.text ?? ""
        let n = (text as NSString).length
        if highlightedFor != text {
          highlights = beatscriptHighlight(text: text)
          highlightedFor = text
          litKey = "\u{0}"  // repaint: the colours are new even when nothing is lit
        }
        let lit = marks.map { m in m.activeLines.map { "\($0.start)" }.joined(separator: ",") + "|" + m.fires.filter { $0.ageBeats < 0.5 }.map { "\($0.token?.start ?? 0)" }.joined(separator: ",") } ?? ""
        guard lit != litKey else { return }
        litKey = lit
        let s = v.textStorage
        let sel = v.selectedRange
        s.beginEditing()
        s.setAttributes([.font: Coordinator.font, .foregroundColor: UIColor(Palette.text)], range: NSRange(location: 0, length: n))
        for h in highlights where Int(h.end) <= n && h.end > h.start {
          s.addAttribute(.foregroundColor, value: Palette.token(h.class), range: NSRange(location: Int(h.start), length: Int(h.end - h.start)))
        }
        if let m = marks {
          for l in m.activeLines where Int(l.end) <= n && l.end > l.start {
            s.addAttribute(.backgroundColor, value: UIColor(Palette.accent).withAlphaComponent(0.13), range: NSRange(location: Int(l.start), length: Int(l.end - l.start)))
          }
          for f in m.fires where f.ageBeats < 0.5 {
            guard let t = f.token, Int(t.end) <= n, t.end > t.start else { continue }
            s.addAttribute(.backgroundColor, value: UIColor(Palette.accent).withAlphaComponent(0.55), range: NSRange(location: Int(t.start), length: Int(t.end - t.start)))
          }
        }
        s.endEditing()
        v.selectedRange = sel
      }

      /// Keep the playing line a third of the way down (once per line, not every frame).
      func follow(_ v: UITextView, to line: BeatscriptSpan) {
        guard line.line != followedLine, !v.isFirstResponder || !v.isDragging else { return }
        followedLine = line.line
        let n = (v.text as NSString).length
        guard Int(line.start) <= n, let start = v.position(from: v.beginningOfDocument, offset: Int(line.start)) else { return }
        let r = v.caretRect(for: start)
        let target = max(0, min(r.minY - v.bounds.height / 3, v.contentSize.height - v.bounds.height))
        v.setContentOffset(CGPoint(x: 0, y: target), animated: true)
      }
    }
  }
#else
  /// macOS (tests and previews only): a plain editor.
  struct CodeEditor: View {
    @Binding var text: String
    var marks: BeatscriptMarks?
    var follow: Bool
    var body: some View { TextEditor(text: $text).font(.system(.body, design: .monospaced)) }
  }
#endif
