import SwiftUI

@main
struct CounterApp: App {
    @StateObject private var cart = Cart()

    var body: some Scene {
        WindowGroup {
            ContentView(cart: cart)
        }
    }
}

/// A SwiftUI body small enough to watch change. The M4 spike edits this one.
struct Banner: View {
    var body: some View {
        Text("banner: one line").font(.caption).foregroundStyle(.secondary)
    }
}

struct ContentView: View {
    @ObservedObject var cart: Cart

    private let catalog = [("Coffee", 450), ("Bagel", 325), ("Juice", 500)]

    var body: some View {
        NavigationStack {
            List {
                Section("Process") {
                    LabeledContent("Session", value: cart.sessionToken)
                        .monospaced()
                    Text("This token is generated once at launch. If it survives a patch, the process was never restarted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Cart") {
                    ForEach(cart.items) { item in
                        LabeledContent(item.name, value: "\(item.cents) cents")
                    }
                    if cart.items.isEmpty {
                        Text("empty").foregroundStyle(.secondary)
                    }
                }

                // Banner's body is the M4 subject and the counterexample: a
                // patch to it loads and reports success, and this row does not
                // change, because SwiftUI does not evaluate a body through the
                // replacement. See DESIGN.md 13.
                Section("SwiftUI") {
                    Banner()
                }

                // Both rows come from patchable methods on Cart. Edit their
                // bodies in Sources/Cart.swift while `swift-ember watch` is
                // running and these change without the app restarting.
                Section("Patched output") {
                    LabeledContent("Subtotal", value: cart.subtotalLabel())
                    LabeledContent("Discount", value: cart.discountLabel())
                }

                Section("Add") {
                    ForEach(catalog, id: \.0) { name, cents in
                        Button("Add \(name)") { cart.add(name, cents: cents) }
                    }
                }

                #if EMBER_ENABLED
                Section("Hot reload") {
                    LabeledContent("Daemon", value: cart.connected ? "connected" : "not connected")
                    Button("Load pending patches") { Ember.loadPendingPatches() }
                    ForEach(Array(cart.reloadLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).monospaced()
                    }
                }
                #else
                Section("Hot reload") {
                    Text("not built in").foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("swift-ember")
            #if EMBER_ENABLED
            .onAppear {
                Ember.start { status in
                    Task { @MainActor in cart.apply(status) }
                }
            }
            #endif
        }
    }
}
