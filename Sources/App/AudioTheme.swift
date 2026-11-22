import SwiftUI
import UIKit

enum AudioTheme {
    private static func rgb(_ value: Int) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    private static func pair(_ day: Int, _ night: Int) -> Color {
        Color(uiColor: UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? night : day) })
    }
    static let canvas = pair(0xFFFFFF, 0x0E182B)
    static let text = pair(0x142641, 0xEEF4FF)
    static let secondary = pair(0x536680, 0xA9BCD7)
    static let separator = pair(0xDCE5F0, 0x32425E)
    static let surface = pair(0xF3F6FA, 0x19263B)
    static let blueWash = pair(0xEBF3FF, 0x172F53)
    static let accent = pair(0x1753C9, 0x92BCFF)
    static let highlight = pair(0xCFE1FF, 0x354E76)
    static let button = pair(0x1854D4, 0x2A60CC)
    static let meta = Font.caption.weight(.medium)
    static let headline = Font.title.weight(.bold)
}

/// The three sloping sound bars are also used in the launcher icon.
struct DialogueMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AudioTheme.button)
            HStack(spacing: 2.5) {
                Capsule().fill(Color.white).frame(width: 4, height: 10).offset(y: 2)
                Capsule().fill(Color.white).frame(width: 4, height: 20)
                Capsule().fill(Color.white.opacity(0.78)).frame(width: 4, height: 13).offset(y: -2)
            }.rotationEffect(.degrees(13))
        }
        .accessibilityHidden(true)
    }
}

struct InputMeter: View {
    let level: Float
    var body: some View {
        let count = level.isFinite ? Int(min(1, max(0, level)) * 16) : 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<16, id: \.self) { i in
                Rectangle()
                    .fill(i < count ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 2, height: CGFloat(5 + i / 2))
            }
        }.accessibilityHidden(true)
    }
}

struct AudioSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline.weight(.bold)).foregroundStyle(AudioTheme.secondary)
            .textCase(nil).accessibilityAddTraits(.isHeader)
    }
}

struct AudioActionLabel: View {
    let title: String
    let symbol: String
    var level: Float?
    var listening = false
    var trailingSymbol: String?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.body.weight(.semibold)).accessibilityHidden(true)
            Text(title).font(.headline.weight(.semibold))
            if let level, listening {
                InputMeter(level: level)
            } else if let trailingSymbol {
                Image(systemName: trailingSymbol).font(.caption.weight(.semibold)).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56)
        .foregroundStyle(Color.white)
        .background(AudioTheme.button, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct AudioPageTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(AudioTheme.headline).foregroundStyle(AudioTheme.text)
            .accessibilityAddTraits(.isHeader).padding(.vertical, 4)
    }
}

extension View {
    func audioPage() -> some View {
        self.foregroundStyle(AudioTheme.text).tint(AudioTheme.accent)
            .background(AudioTheme.canvas)
            .toolbarBackground(AudioTheme.canvas, for: .navigationBar)
    }
    func audioList() -> some View {
        self.listStyle(.insetGrouped).scrollContentBackground(.hidden).audioPage()
    }
    func surfaceRow() -> some View {
        self.listRowBackground(AudioTheme.surface)
            .listRowSeparatorTint(AudioTheme.separator)
    }
}
