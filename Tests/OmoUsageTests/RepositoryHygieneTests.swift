import Foundation
import Testing

@Suite
struct RepositoryHygieneTests {
    @Test
    func repositoryKeepsOnlyDocumentedFilesAndExecutableScripts() throws {
        let fileManager = FileManager.default

        #expect(
            !fileManager.fileExists(
                atPath: repositoryRoot.appending(
                    path: "758588182_17891656152596285_1812746344893833058_n.jpg"
                ).path
            )
        )
        #expect(
            fileManager.fileExists(
                atPath: repositoryRoot.appending(path: ".gitattributes").path
            )
        )
        #expect(
            fileManager.fileExists(
                atPath: repositoryRoot.appending(
                    path: "Scripts/check-repository-hygiene.sh"
                ).path
            )
        )

        for path in executableScripts.sorted() {
            #expect(mode(of: path) == 0o755, "\(path) must be executable")
        }

        for path in try trackedPaths().sorted() {
            guard fileManager.fileExists(
                atPath: repositoryRoot.appending(path: path).path
            ) else {
                continue
            }
            let expectedMode: UInt16 = executableScripts.contains(path)
                ? 0o755
                : 0o644
            #expect(mode(of: path) == expectedMode, "\(path) has an unexpected mode")
        }
    }

    private let executableScripts: Set<String> = [
        "Scripts/check-repository-hygiene.sh",
        "Scripts/package-app.sh",
        "Scripts/qa-dev-six-fixes.sh"
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func trackedPaths() throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = repositoryRoot
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["ls-files", "-z"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RepositoryHygieneError.couldNotReadTrackedPaths
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
    }

    private func mode(of path: String) -> UInt16? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: repositoryRoot.appending(path: path).path
        )
        guard let permissions = attributes?[.posixPermissions] as? NSNumber else {
            return nil
        }
        return permissions.uint16Value & 0o777
    }
}

private enum RepositoryHygieneError: Error {
    case couldNotReadTrackedPaths
}
