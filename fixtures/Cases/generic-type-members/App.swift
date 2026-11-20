struct ValueBox<T> {
    let value: T
    let initializedBy: String

    init(_ value: T) {
        self.value = value
        initializedBy = "old"
    }

    func method() -> String { "old(\(value))" }
    var computed: String { "old(\(value))" }
    static func typeMethod() -> String { "old(\(T.self))" }
}

class ReferenceBox<T> {
    let value: T
    let initializedBy: String
    var convenienceBody = ""

    init(_ value: T) {
        self.value = value
        initializedBy = "old"
    }

    convenience init(copy value: T) {
        self.init(value)
        convenienceBody = "old"
    }

    func method() -> String { "old(\(value))" }
    var computed: String { "old(\(value))" }
    static func typeMethod() -> String { "old(\(T.self))" }
}

private let storedValue = ValueBox(7)
private let storedReference = ReferenceBox(copy: 8)

func probe() async throws -> [String] {
    [
        "struct method: \(storedValue.method())",
        "struct getter: \(storedValue.computed)",
        "struct static: \(ValueBox<Int>.typeMethod())",
        "struct init: \(storedValue.initializedBy) / \(ValueBox(7).initializedBy)",
        "class method: \(storedReference.method())",
        "class getter: \(storedReference.computed)",
        "class static: \(ReferenceBox<Int>.typeMethod())",
        "class designated init: \(storedReference.initializedBy) / \(ReferenceBox(8).initializedBy)",
        "class convenience init: \(storedReference.convenienceBody) / \(ReferenceBox(copy: 8).convenienceBody)",
    ]
}
