import Foundation

/// Names for results written next to their source: "Report (compressed).pdf", then
/// "Report (compressed 2).pdf" if that's taken. Existing files are never overwritten.
public enum SiblingFile {
    /// `tag` nil gives "Report.pdf", "Report 2.pdf", ...; `ext` empty gives a folder-style name.
    public static func name(base: String, tag: String?, ext: String, attempt: Int = 1) -> String {
        var stem = base
        if let tag {
            stem += attempt > 1 ? " (\(tag) \(attempt))" : " (\(tag))"
        } else if attempt > 1 {
            stem += " \(attempt)"
        }
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// The first name in `directory` for which `exists` is false.
    public static func unique(in directory: URL, base: String, tag: String?, ext: String,
                              exists: (URL) -> Bool) -> URL {
        var attempt = 1
        while true {
            let url = directory.appendingPathComponent(name(base: base, tag: tag, ext: ext, attempt: attempt))
            if !exists(url) { return url }
            attempt += 1
        }
    }

    /// A source file's name without its extension.
    public static func base(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
