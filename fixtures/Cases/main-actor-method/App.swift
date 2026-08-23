@MainActor
final class ViewModel {
    var token = "kept"
    func render() -> String { "old(\(token))" }
}

@MainActor let viewModel = ViewModel()

func probe() async throws -> [String] { [await viewModel.render()] }
