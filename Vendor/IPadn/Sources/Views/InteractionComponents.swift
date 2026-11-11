import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ActionConfirmationView: View {
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    var showsCancel = true
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView { confirmation }.scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("confirmation.scroll")
            } else { confirmation }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(showsCancel ? 320 : 280), .large])
        .presentationDragIndicator(.visible).presentationCornerRadius(28)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader).accessibilityIdentifier("confirmation.title")
            if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("confirmation.message") }
            VStack(spacing: 10) {
                Button(role: destructive ? .destructive : nil) { action(); dismiss() } label: {
                    Text(confirmTitle).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 24)
                }.buttonStyle(MonochromeButtonStyle()).accessibilityIdentifier("confirmation.confirm")
                if showsCancel {
                    Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityIdentifier("confirmation.cancel")
                }
            }
        }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
    }
}

private struct ActionConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content.storeSheet(isPresented: $isPresented) {
            ActionConfirmationView(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, action: action)
                // A presented sheet can reset the parent's SwiftUI override.
                // Keep its text size aligned with the page that opened it.
                .environment(\.dynamicTypeSize, typeSize)
        }
    }
}
extension View {
    func actionConfirmation(isPresented: Binding<Bool>, title: String, message: String = "", confirmTitle: String, destructive: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ActionConfirmationModifier(isPresented: isPresented, title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, action: action))
    }
}
