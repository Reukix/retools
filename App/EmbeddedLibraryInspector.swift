import Foundation

/// Describes files and Mach-O links without assuming that every bundled
/// framework is a user-installed tweak, or inventing a lost Debian package name.
enum EmbeddedLibraryInspector {
    static let version = 2
    static func inspect(app: URL) throws -> [EmbeddedLibrary] {
        let fm = FileManager.default
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        let info = try ArchiveService.metadata(at: root)
        let main = info["CFBundleExecutable"] as! String
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw WorkspaceFailure("无法读取 IPA 中的动态库。")
        }
        var files: [String: URL] = [:]
        var frameworks = Set<String>()
        var executables = ["": main]
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            if file.pathExtension == "framework", let metadata = try? ArchiveService.metadata(at: file) {
                frameworks.insert(String(file.appendingPathComponent(metadata["CFBundleExecutable"] as! String).path.dropFirst(root.path.count + 1)))
            }
            if ["appex", "app"].contains(file.pathExtension), let metadata = try? ArchiveService.metadata(at: file) {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                executables[relative] = relative + "/" + (metadata["CFBundleExecutable"] as! String)
            }
            if values.isRegularFile == true {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                files[relative] = file
            }
        }
        var binaries: [String: MachOInspector.Result] = [:]
        for (path, file) in files {
            let handle = try FileHandle(forReadingFrom: file)
            let head = try handle.read(upToCount: 4); try handle.close()
            guard let head, [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xbe, 0xba, 0xfe, 0xca])].contains(head) else { continue }
            if let binary = try? MachOInspector.inspect(file), binary.hasARM64 { binaries[path] = binary }
        }
        var links: [String: [(String, Bool)]] = [:]
        var evidence: [String: Set<EmbeddedPluginEvidence>] = [:]
        let containerPatched = fm.fileExists(atPath: root.appendingPathComponent("LCAppInfo.plist").path)
        func executableDirectory(for owner: String) -> String {
            let components = owner.split(separator: "/").map(String.init)
            if let index = components.lastIndex(where: { $0.hasSuffix(".appex") || $0.hasSuffix(".app") }) { return components[...index].joined(separator: "/") }
            return ""
        }
        func expand(_ path: String, owner: String) -> String {
            path.replacingOccurrences(of: "@loader_path", with: (owner as NSString).deletingLastPathComponent)
                .replacingOccurrences(of: "@executable_path", with: executableDirectory(for: owner))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        func resolved(_ dependency: String, owner: String) -> String? {
            if dependency.hasPrefix("/System/") || dependency.hasPrefix("/usr/lib/") { return nil }
            if containerPatched, dependency == "@loader_path/../../Tweaks/TweakLoader.dylib" { return nil }
            let candidate: String
            if dependency.hasPrefix("@executable_path/") { candidate = (executableDirectory(for: owner) as NSString).appendingPathComponent(String(dependency.dropFirst(17))) }
            else if dependency.hasPrefix("@loader_path/") {
                candidate = ((owner as NSString).deletingLastPathComponent as NSString).appendingPathComponent(String(dependency.dropFirst(13)))
            } else if dependency.hasPrefix("@rpath/") {
                let suffix = String(dependency.dropFirst(7))
                let executable = executables[executableDirectory(for: owner)] ?? main
                let paths = (binaries[owner]?.rpaths ?? []).map { ($0, owner) } + (binaries[executable]?.rpaths ?? []).map { ($0, executable) } + (binaries[main]?.rpaths ?? []).map { ($0, main) }
                for (path, origin) in paths where !path.hasPrefix("/") {
                    let relative = (expand(path, owner: origin) as NSString).appendingPathComponent(suffix)
                    let normalized = root.appendingPathComponent(relative).standardizedFileURL.path
                    if normalized.hasPrefix(root.path + "/"), files[String(normalized.dropFirst(root.path.count + 1))] != nil { return String(normalized.dropFirst(root.path.count + 1)) }
                }
                let matches = files.keys.filter { $0 == suffix || $0.hasSuffix("/" + suffix) }
                if matches.count == 1 { return matches.first }
                candidate = "Frameworks/" + suffix
            } else if dependency.hasPrefix("/") {
                // Injected jailbreak paths may deliberately remain unresolved.
                return dependency
            } else { candidate = dependency }
            let url = root.appendingPathComponent(candidate).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return dependency }
            return String(url.path.dropFirst(root.path.count + 1))
        }
        for (owner, binary) in binaries {
            for dependency in binary.dependencies {
                guard let path = resolved(dependency.path, owner: owner) else { continue }
                links[path, default: []].append((owner, dependency.isWeak))
                if executables.values.contains(owner), binary.appendedDependencies.contains(where: { $0.path == dependency.path }) {
                    evidence[path, default: []].insert(.appendedLoadCommand)
                }
            }
        }
        // Retools Loader uses a manifest instead of one Mach-O command per tweak.
        for (path, file) in files where file.lastPathComponent == "RetoolsPlugins.json" {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let bytes = try? Data(contentsOf: file), bytes.count <= 1_048_576,
                  let manifest = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  manifest["version"] as? Int == 1,
                  let entries = manifest["entries"] as? [[String: Any]] else { continue }
            let owner = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("RetoolsPluginLoader.dylib")
            guard binaries[owner] != nil else { continue }
            for entry in entries.prefix(128) {
                guard let value = entry["path"] as? String, (try? ArchiveService.validate(path: value)) != nil else { continue }
                links[value, default: []].append((owner, entry["optional"] as? Bool ?? false))
                evidence[value, default: []].insert(.loaderManifest)
            }
        }
        // LoadControl manages unlinked dylibs beside itself. Its runtime and
        // Substrate are support components, rather than separate user plugins.
        let managedFolders = Set(binaries.keys.filter {
            ($0 as NSString).lastPathComponent.lowercased() == "loadcontrol.dylib" && !(links[$0] ?? []).isEmpty
        }.map { ($0 as NSString).deletingLastPathComponent })
        for (path, binary) in binaries where binary.isDynamicLibrary && (path.hasSuffix(".dylib") || path.hasSuffix(".dylib.disabled")) {
            if managedFolders.contains((path as NSString).deletingLastPathComponent), (links[path] ?? []).isEmpty { evidence[path, default: []].insert(.loaderDirectory) }
            guard !(links[path] ?? []).isEmpty else { continue }
            let filter = root.appendingPathComponent(path).deletingPathExtension().appendingPathExtension("plist")
            guard let values = try? filter.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 131072,
                  let bytes = try? Data(contentsOf: filter),
                  let descriptor = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let rules = descriptor["Filter"] as? [String: Any],
                  !(rules["Bundles"] as? [String] ?? []).isEmpty || !(rules["Executables"] as? [String] ?? []).isEmpty else { continue }
            evidence[path, default: []].insert(.tweakFilter)
        }
        let paths = Set(binaries.filter { $0.key != main && ($0.value.isDynamicLibrary || $0.key.hasSuffix(".dylib") || frameworks.contains($0.key)) }.map(\.key)).union(links.keys)
        return try paths.sorted().map { path in
            let owners = links[path] ?? []
            let binary = binaries[path]
            return EmbeddedLibrary(path: path, byteCount: Int64(try files[path]?.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
                                   isFramework: frameworks.contains(path) || path.contains(".framework/"),
                                   linkedBy: Array(Set(owners.map(\.0))).sorted(), weakLinkedBy: Array(Set(owners.filter(\.1).map(\.0))).sorted(),
                                   isPresent: files[path] != nil, minimumOS: binary?.minimumOS, dependencies: binary?.dependencies ?? [],
                                   pluginEvidence: evidence[path].map { $0.sorted { $0.rawValue < $1.rawValue } })
        }.sorted { lhs, rhs in
            if lhs.linkedBy.isEmpty != rhs.linkedBy.isEmpty { return !lhs.linkedBy.isEmpty }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }
}
