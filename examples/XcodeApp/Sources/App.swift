import SwiftUI
import SpliceRuntime

@main
struct XcodeApp: App {
    @StateObject private var cart = Cart()

    var body: some Scene {
        WindowGroup {
            ContentView(cart: cart)
        }
    }
}

struct ContentView: View {
    @ObservedObject var cart: Cart

    var body: some View {
        NavigationStack {
            List {
                Section("Process") {
                    LabeledContent("Session", value: cart.sessionToken).monospaced()
                }
                Section("Cart") {
                    ForEach(cart.items) { item in
                        LabeledContent(item.name, value: "\(item.cents) cents")
                    }
                }
                Section("Patched output") {
                    LabeledContent("Subtotal", value: cart.subtotalLabel())
                    LabeledContent("Discount", value: cart.discountLabel())
                }
                Section("Add") {
                    Button("Add Juice") { cart.add("Juice", cents: 500) }
                }
                Section("Hot reload") {
                    LabeledContent("Daemon", value: cart.connected ? "connected" : "not connected")
                    ForEach(Array(cart.reloadLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).monospaced()
                    }
                }
            }
            .navigationTitle("swift-splice")
            // No #if here. Splice.start() exists in every configuration and
            // does nothing unless the runtime was compiled with SPLICE_ENABLED,
            // which the package only defines for Debug.
            .onAppear {
                Splice.start { status in
                    Task { @MainActor in
                        cart.apply(status)
                    }
                }
            }
        }
    }
}
