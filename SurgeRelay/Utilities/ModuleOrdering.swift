import Foundation

enum ModuleOrdering {
    static func moving<T>(_ values: [T], fromOffsets offsets: IndexSet, toOffset destination: Int) -> [T] {
        guard !offsets.isEmpty else { return values }
        let validOffsets = IndexSet(offsets.filter { values.indices.contains($0) })
        guard !validOffsets.isEmpty else { return values }

        let movingValues = validOffsets.map { values[$0] }
        var result = values
        for index in validOffsets.reversed() {
            result.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), result.count)
        result.insert(contentsOf: movingValues, at: insertionIndex)
        return result
    }

    static func reordering<T: Identifiable>(
        _ values: [T],
        matching ids: [T.ID]
    ) -> [T]? where T.ID: Hashable {
        guard ids.count == values.count,
              Set(ids).count == ids.count else { return nil }
        let valueIDs = values.map(\.id)
        guard Set(valueIDs).count == valueIDs.count,
              Set(ids) == Set(valueIDs) else { return nil }
        let lookup = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return ids.compactMap { lookup[$0] }
    }
}
