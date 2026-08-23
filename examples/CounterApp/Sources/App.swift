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

                // Both rows are produced by patchable methods on Cart.
                Section("Patched output") {
                    LabeledContent("Subtotal", value: cart.subtotalLabel())
                    LabeledContent("Discount", value: cart.discountLabel())
                }

                Section("Add") {
                    ForEach(catalog, id: \.0) { name, cents in
                        Button("Add \(name)") { cart.add(name, cents: cents) }
                    }
                }

                #if SPLICE_ENABLED
                Section("Hot reload") {
                    Text("watching \(Splice.inbox.lastPathComponent)/")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Load pending patches now") {
                        let results = Splice.loadPendingPatches()
                        if results.isEmpty {
                            cart.note("nothing pending")
                        }
                        for result in results {
                            cart.note("\(result.name): \(result.detail)")
                        }
                    }
                    ForEach(Array(cart.reloadLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).monospaced()
                    }
                }
                #else
                Section("Hot reload") {
                    Text("not built in")
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("swift-splice M1")
            #if SPLICE_ENABLED
            .onAppear {
                Splice.startWatching { results in
                    for result in results { cart.note("\(result.name): \(result.detail)") }
                }
            }
            #endif
        }
    }
}
