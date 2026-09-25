import Foundation

/// Runs async work over a list with at most `limit` jobs in flight, keeping input order.
enum EmailConcurrency {
    static func map<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                              _ transform: @escaping @Sendable (T) async throws -> R) async throws -> [R] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(max(1, limit), items.count) {
                let i = next, item = items[i]
                group.addTask { (i, try await transform(item)) }
                next += 1
            }
            while let (i, r) = try await group.next() {
                results[i] = r
                if next < items.count {
                    let j = next, item = items[j]
                    group.addTask { (j, try await transform(item)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
