import SwiftUI

/// Formatting is separate from replay and never changes the text passed to TTS.
struct HighlightedCaptionText: View, Equatable {
    let text: String
    var enabled = true

    var body: some View {
        Text(formatted)
    }

    private var formatted: AttributedString {
        var value = AttributedString(text)
        guard enabled else { return value }
        for item in KeyInformationHighlighter.highlights(in: text) {
            guard let stringRange = Range(item.range, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: value),
                  let upper = AttributedString.Index(stringRange.upperBound, within: value) else { continue }
            value[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            value[lower..<upper].backgroundColor = Color.orange.opacity(0.16)
        }
        return value
    }
}
