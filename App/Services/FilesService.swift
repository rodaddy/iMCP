import AppKit
import Foundation
import JSONSchema
import OSLog
import UniformTypeIdentifiers

private let log = Logger.service("files")

final class FilesService: Service {
    static let shared = FilesService()

    var tools: [Tool] {
        Tool(
            name: "files_list",
            description:
                "List files and directories at a path with metadata (name, kind, size, modified date)",
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description:
                            "Absolute directory path to list (e.g. /Users/rico/Downloads)"
                    ),
                    "showHidden": .boolean(
                        description: "Include hidden files (default false)"
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let path) = arguments["path"], !path.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Path is required"])
            }

            let showHidden: Bool
            if case .bool(let h) = arguments["showHidden"] { showHidden = h } else {
                showHidden = false
            }

            let url = URL(fileURLWithPath: path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                isDir.boolValue
            else {
                throw NSError(
                    domain: "FilesError", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Not a directory: \(path)"
                    ])
            }

            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .isHiddenKey,
                ]
            )

            guard contents.count < 2000 else {
                throw NSError(
                    domain: "FilesError", code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Directory has \(contents.count) entries -- too many to list. Use a more specific path."
                    ])
            }

            let dateFormatter = ISO8601DateFormatter()

            let files: [Value] = contents.compactMap { fileURL in
                guard
                    let rv = try? fileURL.resourceValues(forKeys: [
                        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                        .isHiddenKey,
                    ])
                else { return nil }

                if !showHidden && (rv.isHidden == true) { return nil }

                var entry: [String: Value] = [
                    "name": .string(fileURL.lastPathComponent),
                    "kind": .string(rv.isDirectory == true ? "directory" : "file"),
                ]
                if let size = rv.fileSize {
                    entry["size"] = .int(size)
                }
                if let mod = rv.contentModificationDate {
                    entry["modified"] = .string(dateFormatter.string(from: mod))
                }
                return Value.object(entry)
            }.sorted {
                guard case .object(let a) = $0, case .object(let b) = $1,
                    case .string(let nameA) = a["name"],
                    case .string(let nameB) = b["name"]
                else { return false }
                return nameA < nameB
            }

            return Value.object([
                "path": .string(path),
                "count": .int(files.count),
                "entries": .array(files),
            ])
        }

        Tool(
            name: "files_read",
            description:
                "Read a file's content. Returns text for text files, base64 for binary. Max 10MB.",
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description: "Absolute file path to read"
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let path) = arguments["path"], !path.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Path is required"])
            }

            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw NSError(
                    domain: "FilesError", code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: "File not found: \(path)"
                    ])
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? Int) ?? 0
            guard size <= 10_000_000 else {
                throw NSError(
                    domain: "FilesError", code: 6,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "File too large (\(size / 1_000_000)MB). Max 10MB."
                    ])
            }

            let mimeType = Self.mimeType(for: url)

            if mimeType.hasPrefix("text/")
                || mimeType == "application/json"
                || mimeType == "application/xml"
                || mimeType == "application/x-yaml"
                || mimeType == "application/toml"
                || mimeType == "application/javascript"
            {
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    return Value.object([
                        "path": .string(path),
                        "mimeType": .string(mimeType),
                        "content": .string(content),
                    ])
                }
            }

            let data = try Data(contentsOf: url)
            return Value.data(mimeType: mimeType, data)
        }

        Tool(
            name: "files_info",
            description:
                "Get detailed metadata about a file or directory (size, dates, type, permissions)",
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description: "Absolute path to get info for"
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "File Info",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let path) = arguments["path"], !path.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Path is required"])
            }

            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw NSError(
                    domain: "FilesError", code: 8,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Path not found: \(path)"
                    ])
            }

            let rv = try url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
                .contentModificationDateKey, .creationDateKey,
                .contentTypeKey, .isHiddenKey, .isReadableKey, .isWritableKey,
            ])

            let dateFormatter = ISO8601DateFormatter()
            var info: [String: Value] = [
                "path": .string(path),
                "name": .string(url.lastPathComponent),
                "kind": .string(rv.isDirectory == true ? "directory" : "file"),
                "hidden": .bool(rv.isHidden ?? false),
                "readable": .bool(rv.isReadable ?? false),
                "writable": .bool(rv.isWritable ?? false),
            ]

            if let size = rv.fileSize { info["size"] = .int(size) }
            if let totalSize = rv.totalFileSize { info["totalSize"] = .int(totalSize) }
            if let mod = rv.contentModificationDate {
                info["modified"] = .string(dateFormatter.string(from: mod))
            }
            if let created = rv.creationDate {
                info["created"] = .string(dateFormatter.string(from: created))
            }
            if let contentType = rv.contentType {
                info["type"] = .string(contentType.identifier)
                if let mime = contentType.preferredMIMEType {
                    info["mimeType"] = .string(mime)
                }
            }

            return Value.object(info)
        }

        Tool(
            name: "files_search",
            description:
                "Search for files by name pattern within a directory tree. Returns matching paths.",
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description: "Root directory to search from"
                    ),
                    "pattern": .string(
                        description:
                            "File name pattern to match (case-insensitive substring match)"
                    ),
                    "limit": .integer(
                        description: "Maximum results to return",
                        default: .int(50)
                    ),
                ],
                required: ["path", "pattern"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let path) = arguments["path"], !path.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Path is required"])
            }
            guard case .string(let pattern) = arguments["pattern"], !pattern.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Pattern is required"])
            }

            let limit: Int
            if case .int(let l) = arguments["limit"] { limit = l } else { limit = 50 }

            let url = URL(fileURLWithPath: path)
            let lowerPattern = pattern.lowercased()
            var matches: [Value] = []

            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                if matches.count >= limit { break }
                let name = fileURL.lastPathComponent
                if name.lowercased().contains(lowerPattern) {
                    let rv = try? fileURL.resourceValues(forKeys: [
                        .isDirectoryKey, .fileSizeKey,
                    ])
                    var entry: [String: Value] = [
                        "path": .string(fileURL.path),
                        "name": .string(name),
                        "kind": .string(
                            rv?.isDirectory == true ? "directory" : "file"),
                    ]
                    if let size = rv?.fileSize { entry["size"] = .int(size) }
                    matches.append(Value.object(entry))
                }
            }

            return Value.object([
                "pattern": .string(pattern),
                "root": .string(path),
                "count": .int(matches.count),
                "matches": .array(matches),
            ])
        }

        Tool(
            name: "files_write",
            description:
                "Write text content to a file. Creates parent directories if needed. Use with caution.",
            inputSchema: .object(
                properties: [
                    "path": .string(
                        description: "Absolute file path to write to"
                    ),
                    "content": .string(
                        description: "Text content to write"
                    ),
                    "append": .boolean(
                        description: "Append to file instead of overwriting"
                    ),
                ],
                required: ["path", "content"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write File",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard case .string(let path) = arguments["path"], !path.isEmpty else {
                throw NSError(
                    domain: "FilesError", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Path is required"])
            }
            guard case .string(let content) = arguments["content"] else {
                throw NSError(
                    domain: "FilesError", code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "Content is required"])
            }

            let append: Bool
            if case .bool(let a) = arguments["append"] { append = a } else { append = false }

            let url = URL(fileURLWithPath: path)

            // Create parent directories if needed
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir, withIntermediateDirectories: true)

            if append {
                if FileManager.default.fileExists(atPath: path) {
                    let handle = try FileHandle(forWritingTo: url)
                    handle.seekToEndOfFile()
                    if let data = content.data(using: .utf8) {
                        handle.write(data)
                    }
                    handle.closeFile()
                } else {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                }
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? Int) ?? 0

            return Value.object([
                "success": .bool(true),
                "path": .string(path),
                "size": .int(size),
                "appended": .bool(append),
            ])
        }
    }

    // MARK: - Helpers

    static func mimeType(for url: URL) -> String {
        if let utType = UTType(filenameExtension: url.pathExtension),
            let mimeType = utType.preferredMIMEType
        {
            return mimeType
        }
        return "application/octet-stream"
    }
}
