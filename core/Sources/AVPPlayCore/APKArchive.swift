import Foundation

/// Check the archive structure before the system unzip tool writes anything.
/// APKs use ordinary ZIP records; ZIP64/multidisk/encrypted archives are refused.
enum APKArchive {
    static func invalid() -> APKImportError {
        .invalid(L("unsupported or unsafe APK archive (paths, links, duplicate entries, sizes or ZIP records)",
                   "nicht unterstütztes oder unsicheres APK-Archiv (Pfade, Verweise, doppelte Einträge, Größen oder ZIP-Struktur)"))
    }

    static func validate(_ url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 22, length <= 4 << 30 else { throw invalid() }
        let tailLength = min(Int(length), 65_557)
        try file.seek(toOffset: length - UInt64(tailLength))
        guard let tail = try file.read(upToCount: tailLength), tail.count == tailLength else { throw invalid() }
        func u16(_ data: Data, _ at: Int) throws -> Int {
            guard at >= 0, at <= data.count - 2 else { throw invalid() }
            return Int(data[at]) | Int(data[at + 1]) << 8
        }
        func u32(_ data: Data, _ at: Int) throws -> Int {
            return try u16(data, at) | u16(data, at + 2) << 16
        }
        var end: Int?
        for at in stride(from: tail.count - 22, through: 0, by: -1) {
            if try u32(tail, at) == 0x06054b50, try at + 22 + u16(tail, at + 20) == tail.count { end = at; break }
        }
        guard let end, try u16(tail, end + 4) == 0, try u16(tail, end + 6) == 0 else { throw invalid() }
        let count = try u16(tail, end + 10), directorySize = try u32(tail, end + 12), directoryOffset = try u32(tail, end + 16)
        guard count > 0, count < 65_535, try u16(tail, end + 8) == count,
              directorySize > 0, directorySize <= 16 << 20,
              UInt64(directoryOffset + directorySize) == length - UInt64(tailLength) + UInt64(end) else { throw invalid() }
        try file.seek(toOffset: UInt64(directoryOffset))
        guard let directory = try file.read(upToCount: directorySize), directory.count == directorySize else { throw invalid() }
        var at = 0, total = 0
        var explicit = Set<String>(), types: [String: Bool] = [:], extents: [(Int, Int)] = []
        for _ in 0..<count {
            guard try u32(directory, at) == 0x02014b50 else { throw invalid() }
            let flags = try u16(directory, at + 8), method = try u16(directory, at + 10)
            let compressed = try u32(directory, at + 20), expanded = try u32(directory, at + 24)
            let nameSize = try u16(directory, at + 28), extra = try u16(directory, at + 30), comment = try u16(directory, at + 32)
            let mode = try (u32(directory, at + 38) >> 16) & 0xf000
            let local = try u32(directory, at + 42), next = at + 46 + nameSize + extra + comment
            guard flags & 1 == 0, method == 0 || method == 8, try u16(directory, at + 34) == 0,
                  nameSize > 0, nameSize <= 4096, next <= directory.count,
                  expanded <= 2 << 30, mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw invalid() }
            total += expanded
            guard total <= 8 << 30 else { throw invalid() }
            let rawName = directory.subdata(in: (at + 46)..<(at + 46 + nameSize))
            guard let name = String(data: rawName, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw invalid() }
            let isDirectory = name.hasSuffix("/") || mode == 0x4000
            guard mode != 0x4000 || name.hasSuffix("/") else { throw invalid() }
            var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), !isDirectory || expanded == 0 else { throw invalid() }
            let key = parts.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard explicit.insert(key).inserted, types[key] == nil || types[key] == isDirectory else { throw invalid() }
            for size in 1..<parts.count {
                let parent = parts.prefix(size).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
                guard types[parent] != false else { throw invalid() }
                types[parent] = true
            }
            types[key] = isDirectory
            guard local >= 0, local + 30 <= directoryOffset else { throw invalid() }
            try file.seek(toOffset: UInt64(local))
            guard let header = try file.read(upToCount: 30), header.count == 30,
                  try u32(header, 0) == 0x04034b50, try u16(header, 6) == flags, try u16(header, 8) == method,
                  try u16(header, 26) == nameSize else { throw invalid() }
            let localCRC = try u32(header, 14), localCompressed = try u32(header, 18), localExpanded = try u32(header, 22)
            let crc = try u32(directory, at + 16)
            if flags & 8 == 0 {
                guard localCRC == crc, localCompressed == compressed, localExpanded == expanded else { throw invalid() }
            } else {
                guard (localCRC == 0 || localCRC == crc), (localCompressed == 0 || localCompressed == compressed),
                      (localExpanded == 0 || localExpanded == expanded) else { throw invalid() }
            }
            let dataStart = try local + 30 + nameSize + u16(header, 28)
            guard dataStart <= directoryOffset, compressed <= directoryOffset - dataStart,
                  let localName = try file.read(upToCount: nameSize), localName == rawName else { throw invalid() }
            extents.append((local, dataStart + compressed))
            at = next
        }
        guard at == directory.count else { throw invalid() }
        let sorted = extents.sorted { $0.0 < $1.0 }
        for index in 1..<sorted.count where sorted[index].0 < sorted[index - 1].1 { throw invalid() }
    }
}
