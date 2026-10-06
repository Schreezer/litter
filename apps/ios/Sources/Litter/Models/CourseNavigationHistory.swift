/// Window-local navigation history for desktop Back and Forward commands.
/// Course data and progress remain owned by CourseExperienceStore.
struct CourseNavigationHistory<Route: Equatable> {
    private(set) var currentPath: [Route] = []
    private var backPaths: [[Route]] = []
    private var forwardPaths: [[Route]] = []
    private var expectedCommandPath: [Route]?

    mutating func record(path: [Route]) {
        if path == expectedCommandPath {
            expectedCommandPath = nil
            return
        }
        guard path != currentPath else { return }
        backPaths.append(currentPath)
        currentPath = path
        forwardPaths.removeAll()
        expectedCommandPath = nil
    }

    mutating func back() -> [Route]? {
        guard let path = backPaths.popLast() else { return nil }
        forwardPaths.append(currentPath)
        currentPath = path
        expectedCommandPath = path
        return path
    }

    mutating func forward() -> [Route]? {
        guard let path = forwardPaths.popLast() else { return nil }
        backPaths.append(currentPath)
        currentPath = path
        expectedCommandPath = path
        return path
    }
}
