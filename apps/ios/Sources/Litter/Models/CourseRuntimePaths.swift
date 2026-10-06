import Foundation

/// Projects the app-owned course workspace into the filesystem visible to
/// Codex. The embedded iOS runtime sees an iSH mount; installed Mac Codex sees
/// the native directory used by the course repository.
enum CourseRuntimePaths {
    enum FileSystem: Equatable, Sendable {
        case embeddedIOS
        case nativeMac
    }

    static var currentFileSystem: FileSystem {
#if targetEnvironment(macCatalyst)
        .nativeMac
#else
        .embeddedIOS
#endif
    }

    static var defaultCoursesRootURL: URL {
        Foundation.FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent("Courses", isDirectory: true)
    }

    static func workspacePath(
        workspaceID: String,
        workspaceURL: URL,
        fileSystem: FileSystem = currentFileSystem
    ) -> String {
        switch fileSystem {
        case .embeddedIOS: "/mnt/apps/Courses/\(workspaceID)"
        case .nativeMac: workspaceURL.standardizedFileURL.path
        }
    }

    static func originalSourcePath(
        filename: String,
        workspaceID: String,
        workspaceURL: URL,
        fileSystem: FileSystem = currentFileSystem
    ) -> String {
        workspacePath(workspaceID: workspaceID, workspaceURL: workspaceURL, fileSystem: fileSystem)
            + "/sources/originals/\(filename)"
    }

    /// Accepts a persisted path only inside this workspace's original-source
    /// directory. Legacy iOS paths are accepted on Mac and projected to the
    /// current native root after the caller verifies that the file exists.
    static func originalSourceFilename(
        runtimePath: String,
        workspaceID: String,
        workspaceURL: URL,
        fileSystem: FileSystem = currentFileSystem
    ) -> String? {
        var prefixes = [workspacePath(
            workspaceID: workspaceID,
            workspaceURL: workspaceURL,
            fileSystem: fileSystem
        ) + "/sources/originals/"]
        if fileSystem == .nativeMac {
            prefixes.append("/mnt/apps/Courses/\(workspaceID)/sources/originals/")
        }
        guard let prefix = prefixes.first(where: runtimePath.hasPrefix) else { return nil }
        let filename = String(runtimePath.dropFirst(prefix.count))
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\0") else { return nil }
        return filename
    }
}
