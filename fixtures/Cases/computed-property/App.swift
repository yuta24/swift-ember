struct Box {
    var raw = 21
    var doubled: Int { raw * 2 }
}

let box = Box()

func probe() async throws -> [String] { ["doubled=\(box.doubled)"] }
