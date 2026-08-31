import Foundation

public struct AppResolver: Sendable {
    public init() {}

    public func resolve(
        worktreePath: String,
        apps: [VaultApp],
        explicitApp: String? = nil
    ) throws -> VaultApp {
        if let explicitApp, !explicitApp.isEmpty {
            if let byID = UUID(uuidString: explicitApp),
               let match = apps.first(where: { $0.id == byID }) {
                return match
            }
            let lowered = explicitApp.lowercased()
            let matches = apps.filter {
                $0.name.lowercased() == lowered
                    || URL(fileURLWithPath: $0.rootFolder).lastPathComponent.lowercased() == lowered
            }
            guard let match = matches.first else {
                throw SecretKeeperError.appNotFound(explicitApp)
            }
            if matches.count > 1 {
                throw SecretKeeperError.ambiguousAppMatch(matches.map(\.name))
            }
            return match
        }

        let normalizedWorktree = try normalizeDirectory(worktreePath)
        let candidates = apps.compactMap { app -> (VaultApp, Int)? in
            guard let score = matchScore(worktree: normalizedWorktree, app: app) else { return nil }
            return (app, score)
        }

        if candidates.isEmpty {
            // Try git main worktree / common dir
            if let gitRoot = resolveGitMainWorktree(for: normalizedWorktree) {
                let gitCandidates = apps.compactMap { app -> (VaultApp, Int)? in
                    guard let score = matchScore(worktree: gitRoot, app: app) else { return nil }
                    return (app, score)
                }
                return try pickBest(gitCandidates, worktree: normalizedWorktree)
            }
            throw SecretKeeperError.appNotFound(normalizedWorktree)
        }

        return try pickBest(candidates, worktree: normalizedWorktree)
    }

    private func pickBest(_ candidates: [(VaultApp, Int)], worktree: String) throws -> VaultApp {
        guard !candidates.isEmpty else {
            throw SecretKeeperError.appNotFound(worktree)
        }
        let bestScore = candidates.map(\.1).max()!
        let best = candidates.filter { $0.1 == bestScore }.map(\.0)
        if best.count == 1 { return best[0] }
        throw SecretKeeperError.ambiguousAppMatch(best.map(\.name))
    }

    /// Higher score = more specific (longer) root folder match.
    private func matchScore(worktree: String, app: VaultApp) -> Int? {
        let root = (app.rootFolder as NSString).standardizingPath
        if worktree == root { return root.count + 1_000_000 }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if worktree.hasPrefix(prefix) { return root.count }
        return nil
    }

    public func normalizeDirectory(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw SecretKeeperError.worktreeNotFound(path)
        }
        return url.path
    }

    /// Resolves the primary checkout for a git worktree, if possible.
    public func resolveGitMainWorktree(for worktreePath: String) -> String? {
        let gitPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDir) {
            if isDir.boolValue {
                // Regular repo — itself is the main worktree
                return worktreePath
            }
            // Worktree: .git is a file pointing at gitdir
            guard let contents = try? String(contentsOf: gitPath, encoding: .utf8) else { return nil }
            let line = contents
                .split(separator: "\n")
                .map(String.init)
                .first { $0.hasPrefix("gitdir:") }
            guard let line else { return nil }
            let gitDir = line
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let gitDirURL = URL(fileURLWithPath: gitDir, relativeTo: URL(fileURLWithPath: worktreePath))
                .standardizedFileURL

            // Common layout: <main>/.git/worktrees/<name>
            let path = gitDirURL.path
            if let range = path.range(of: "/.git/worktrees/") {
                return String(path[..<range.lowerBound])
            }
            if path.hasSuffix("/.git") {
                return String(path.dropLast("/.git".count))
            }

            // Fallback: git rev-parse --show-toplevel via common dir
            if let common = try? String(contentsOf: gitDirURL.appendingPathComponent("commondir"), encoding: .utf8) {
                let commonPath = common.trimmingCharacters(in: .whitespacesAndNewlines)
                let commonURL = URL(fileURLWithPath: commonPath, relativeTo: gitDirURL).standardizedFileURL
                if commonURL.lastPathComponent == ".git" {
                    return commonURL.deletingLastPathComponent().path
                }
            }
        }
        return nil
    }
}
