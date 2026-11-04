import Foundation

/// What `restore-engine-dfu` checks before running anything as root.
public enum RootTool {
    /// macvdmtool sits next to `restore-engine-dfu`; neither takes a path from the caller.
    public static let toolName = "macvdmtool"
    public static let ports = 0...3

    /// Owner and mode of a path, without following a final symlink.
    public struct Entry: Equatable, Sendable {
        public var uid: UInt32
        public var mode: UInt32  // st_mode
        public init(uid: UInt32, mode: UInt32) { self.uid = uid; self.mode = mode }
    }

    /// Why `path` isn't safe to run as root, or nil: it and every folder up to `/` must be
    /// owned by root and writable by nobody else, and none may be a symlink. `entry` reads
    /// one path (lstat); tests pass a fake file system.
    public static func untrusted(_ path: String, entry: (String) -> Entry? = lstatEntry) -> String? {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else { return "\(path) isn't an absolute, plain path." }
        var current = path
        var isFile = true
        while true {
            guard let info = entry(current) else { return "\(current) is missing." }
            let type = info.mode & UInt32(S_IFMT)
            if type == UInt32(S_IFLNK) { return "\(current) is a symlink." }
            if isFile, type != UInt32(S_IFREG) { return "\(current) isn't a regular file." }
            if !isFile, type != UInt32(S_IFDIR) { return "\(current) isn't a folder." }
            if info.uid != 0 { return "\(current) isn't owned by root." }
            // Group/other writable; a sticky shared folder (/tmp) is no good either.
            if info.mode & UInt32(S_IWGRP | S_IWOTH) != 0 { return "\(current) is writable by others." }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
            isFile = false
        }
    }

    public static func lstatEntry(_ path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Entry(uid: UInt32(info.st_uid), mode: UInt32(info.st_mode))
    }

    /// The real (symlink-free) path of the running executable.
    public static func ownExecutable() -> String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }
}
