import Foundation

/// The colour assigned to a speaker.
///
/// An enum of names rather than actual colours, so this file stays free of
/// SwiftUI and the assignment logic stays testable. `ContentView` maps each
/// case to a `Color`, and because the switch there must be exhaustive the two
/// cannot drift apart.
///
/// Almost all are system colours, which adapt to light and dark automatically —
/// this is why the palette is fixed rather than a free colour well: a free
/// choice lets you pick something invisible against one of the two themes.
/// Burgundy has no system equivalent, so it is defined for both appearances
/// by hand: deep wine on light, a lighter wine on dark, because a true
/// burgundy on a dark background is barely legible.
enum SpeakerColor: Int, CaseIterable, Equatable, Codable {
    case blue
    case orange
    case green
    case purple
    case pink
    case teal
    case indigo
    case brown
    // Appended, never inserted. The raw values are what saved transcripts
    // store, so reordering these would recolour every speaker on disk.
    case red
    case burgundy

    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .orange: return "Orange"
        case .green: return "Green"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .teal: return "Teal"
        case .indigo: return "Indigo"
        case .brown: return "Brown"
        case .red: return "Red"
        case .burgundy: return "Burgundy"
        }
    }

    /// Colours are handed out in order of first appearance, wrapping around if
    /// a recording somehow has more speakers than the palette has colours.
    static func forSpeaker(atIndex index: Int) -> SpeakerColor {
        let all = allCases
        return all[((index % all.count) + all.count) % all.count]
    }

    /// The default assignment for a whole transcript.
    static func assign(to speakerIDs: [String]) -> [String: SpeakerColor] {
        var colors: [String: SpeakerColor] = [:]
        for (index, id) in speakerIDs.enumerated() {
            colors[id] = forSpeaker(atIndex: index)
        }
        return colors
    }
}
