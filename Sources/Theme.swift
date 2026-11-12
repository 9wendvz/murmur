import SwiftUI
import AppKit

/// Warm, analog palette and one monospace typeface.
enum Theme {
    // warm beige "putty" plastic, cream paper, desk-lamp light
    static let paper     = Color(red: 0.894, green: 0.863, blue: 0.788)   // #E4DCC9 putty (window)
    static let paperDeep = Color(red: 0.894, green: 0.863, blue: 0.788)
    static let card      = Color(red: 0.973, green: 0.953, blue: 0.898)   // #F8F3E5 notebook sheet
    static let rule      = Color(red: 0.890, green: 0.855, blue: 0.776)   // #E3DAC6 ruled lines
    static let ink       = Color(red: 0.169, green: 0.149, blue: 0.125)   // #2B2620
    static let sub       = Color(red: 0.486, green: 0.447, blue: 0.376)   // #7C7260
    static let faint     = Color(red: 0.663, green: 0.620, blue: 0.533)   // #A99E88
    static let line      = Color(red: 0.808, green: 0.765, blue: 0.667)   // #CEC3AA
    static let green     = Color(red: 0.420, green: 0.620, blue: 0.330)   // phosphor green
    static let amber     = Color(red: 0.890, green: 0.600, blue: 0.180)   // amber LED
    static let red       = Color(red: 0.784, green: 0.192, blue: 0.169)   // #C8312B trackpoint red

    static let nsPaper = NSColor(srgbRed: 0.894, green: 0.863, blue: 0.788, alpha: 1)

    /// The one typeface: a plain Japanese monospace, like a text file.
    static func font(_ size: CGFloat = 12) -> Font { .custom("Osaka-Mono", size: size) }
}

/// Plain text that darkens on hover. No outlines, no fills.
struct TextButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration, active: active)
    }

    private struct TextButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let active: Bool
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Theme.font(12))
                .foregroundStyle(active || hover ? Theme.ink : Theme.sub)
                .opacity(configuration.isPressed ? 0.5 : 1)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        }
    }
}

/// 12-hour times in the app's lowercase style: "2:40 am", "11:05:09 pm".
enum Clock {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }
    private static let hm = formatter("h:mm a")
    private static let hms = formatter("h:mm:ss a")

    static func time(_ d: Date) -> String { hm.string(from: d) }
    static func timeWithSeconds(_ d: Date) -> String { hms.string(from: d) }
}
