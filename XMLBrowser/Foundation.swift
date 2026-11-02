// Typed Swift declarations of the Foundation API the browser uses to find
// files, written with ObjCInterop's macros.

import ObjCInterop

@ObjC
struct NSFileManager {
    @ObjCMethod static func defaultManager() -> NSFileManager
    /// The names in a directory, or nil if it can't be read.
    @ObjCMethod func contentsOfDirectory(atPath path: String, error: ObjCValue) -> NSArray?
    @ObjCMethod func attributesOfItem(atPath path: String, error: ObjCValue) -> NSDictionary?
}

@ObjC
struct NSArray {
    @ObjCProperty(readonly: true) var count: Int
    @ObjCMethod func objectAtIndex(_ index: Int) -> ObjCValue
}

@ObjC
struct NSDictionary {
    /// NSFileSize, for a file's attributes.
    @ObjCMethod func fileSize() -> Int64
}

@ObjC
struct NSFileHandle {
    @ObjCMethod static func fileHandleForReading(atPath path: String) -> NSFileHandle?
    @ObjCMethod func readData(ofLength length: Int) -> ObjCValue
    @ObjCMethod func closeFile()
}

@ObjC
struct NSBundle {
    @ObjCMethod static func mainBundle() -> NSBundle
    @ObjCProperty(readonly: true) var resourcePath: String
}

@ObjC
struct NSDate {
    @ObjCMethod static func timeIntervalSinceReferenceDate() -> Double
}

extension NSFileManager {
    /// The names in a directory, in alphabetical order.
    func names(in directory: String) -> [String] {
        guard let list = contentsOfDirectory(atPath: directory, error: ObjC.nil) else { return [] }
        var names: [String] = []
        for index in 0..<list.count {
            if let name = list.objectAtIndex(index).asString { names.append(name) }
        }
        return names.sorted()
    }

    /// A file's size in bytes, or nil if it doesn't exist.
    func size(of path: String) -> Int? {
        attributesOfItem(atPath: path, error: ObjC.nil).map { Int($0.fileSize()) }
    }

    /// Whether a file starts with an XML declaration (plists are often binary instead).
    func isXML(_ path: String) -> Bool {
        guard let handle = NSFileHandle.fileHandleForReading(atPath: path) else { return false }
        let data = handle.readData(ofLength: 5)
        handle.closeFile()
        return ObjC.NSString.alloc().initWithData(data, encoding: 4).asString == "<?xml"
    }
}
