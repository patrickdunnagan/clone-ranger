import Foundation

/// Low-level file calls on plain String paths. Foundation's URL and FileManager path APIs rewrite
/// accented names into another Unicode form ("é" as e + accent), so a copy made through them can
/// differ byte-for-byte from the original name. Everything that touches names inside a transfer
/// goes through here instead; Swift passes a String's bytes to the system unchanged.
public enum FS {
    public static func join(_ a: String, _ b: String) -> String {
        b.isEmpty ? a : a.hasSuffix("/") ? a + b : a + "/" + b
    }

    public static func lstatInfo(_ p: String) -> stat? {
        var st = stat()
        return lstat(p, &st) == 0 ? st : nil
    }

    public static func exists(_ p: String) -> Bool { lstatInfo(p) != nil }

    public static func errorText(_ code: Int32 = errno) -> String {
        code == ENOSPC ? "The drive is full" : String(cString: strerror(code))
    }

    /// mkdir -p. Existing folders are fine.
    public static func makeFolders(_ p: String) throws {
        if let st = lstatInfo(p) {
            if (st.st_mode & S_IFMT) == S_IFDIR { return }
            throw CopyError.io("A file is in the way of folder \((p as NSString).lastPathComponent)")
        }
        let parent = (p as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != p { try makeFolders(parent) }
        if mkdir(p, 0o755) != 0 && errno != EEXIST {
            throw CopyError.io("Couldn't create folder \((p as NSString).lastPathComponent): \(errorText())")
        }
    }

    /// Creates exactly one new folder; fails if anything already has that name.
    public static func makeNewFolder(_ p: String) throws {
        if mkdir(p, 0o755) != 0 {
            throw CopyError.io("Couldn't create \((p as NSString).lastPathComponent): \(errorText())")
        }
    }

    /// Modification and creation dates, set together.
    public static func setDates(_ p: String, modified: timespec, created: timespec) {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME) | attrgroup_t(ATTR_CMN_MODTIME)
        var times = (created, modified)   // order follows the attribute bits: creation, then modification
        _ = withUnsafeMutableBytes(of: &times) { buf in
            setattrlist(p, &list, buf.baseAddress, buf.count, UInt32(FSOPT_NOFOLLOW))
        }
    }
}
