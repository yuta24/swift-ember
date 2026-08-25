// A fileprivate member overridden by a subclass in the same file. Carrying a
// copy of the base method put it in an extension, where it is statically
// dispatched, and the subclass's version silently stopped running. Replacement
// binds at the key the vtable already points at, so dispatch is untouched.

class Base {
    fileprivate func tag() -> String { "base" }
    func describe() -> String { "tag=\(tag())" }
}

final class Sub: Base {
    override fileprivate func tag() -> String { "sub" }
}

nonisolated(unsafe) let subject: Base = Sub()

func probe() async throws -> [String] { [subject.describe()] }
