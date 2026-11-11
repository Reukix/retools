// Retools native SwiftUI interactions, adapted 2026-11-11. GPL-2.0-or-later.
import SwiftUI

enum RevealActionStyle { case compact, round }
enum RevealRowGrouping { case standalone, first, middle }

private struct NativeDeleteAction: ViewModifier {
    let enabled: Bool
    let title: String
    let action: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: action) { Label(title, systemImage: "trash") }
            }
            .accessibilityAction(named: Text(title), action)
        } else { content }
    }
}

extension View {
    // Preserve call-site identities while moving gesture ownership to SwiftUI List.
    func revealDelete(id: String, enabled: Bool = true, grouping: RevealRowGrouping = .standalone, separatorInset: CGFloat? = nil, style: RevealActionStyle = .round, title: String = "删除", action: @escaping () -> Void) -> some View {
        modifier(NativeDeleteAction(enabled: enabled, title: title, action: action))
            .listRowBackground(UX.surface)
            .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
    }
}
