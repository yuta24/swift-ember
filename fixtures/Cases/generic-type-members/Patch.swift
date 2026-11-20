@testable import Fixture

extension ValueBox {
    @_dynamicReplacement(for: init(_:))
    init(patch value: T) {
        self.value = value
        initializedBy = "new"
    }

    @_dynamicReplacement(for: method())
    func patchedMethod() -> String { "new(\(value))" }

    @_dynamicReplacement(for: computed)
    var patchedComputed: String { "new(\(value))" }

    @_dynamicReplacement(for: typeMethod())
    static func patchedTypeMethod() -> String { "new(\(T.self))" }
}

extension ReferenceBox {
    @_dynamicReplacement(for: init(_:))
    init(patch value: T) {
        self.value = value
        initializedBy = "new"
        convenienceBody = ""
    }

    @_dynamicReplacement(for: init(copy:))
    convenience init(patchCopy value: T) {
        self.init(value)
        convenienceBody = "new"
    }

    @_dynamicReplacement(for: method())
    func patchedMethod() -> String { "new(\(value))" }

    @_dynamicReplacement(for: computed)
    var patchedComputed: String { "new(\(value))" }

    @_dynamicReplacement(for: typeMethod())
    static func patchedTypeMethod() -> String { "new(\(T.self))" }
}
