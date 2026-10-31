// Embedded Swift shared by the UIKit app (src/) and the command-line tool (cli/).
// The @c functions are declared for Objective-C in HelloIOS6.h.

struct Device {
    let name: String

    var greeting: String { "Hello from Swift 6.4, \(name)!" }
}

func sumOfSquares(upTo n: Int) -> Int {
    (1...n).map { $0 * $0 }.reduce(0, +)
}

/// Copies `string` into `buffer` as NUL-terminated UTF-8, truncated to fit `size`.
/// Returns the number of bytes written, not counting the NUL.
func copyCString(_ string: String, to buffer: UnsafeMutablePointer<CChar>, size: Int) -> Int {
    guard size > 0 else { return 0 }
    var count = 0
    for byte in string.utf8 {
        guard count < size - 1 else { break }
        buffer[count] = CChar(bitPattern: byte)
        count += 1
    }
    buffer[count] = 0
    return count
}

@c func hello_greeting(_ buffer: UnsafeMutablePointer<CChar>, _ size: Int) -> Int {
    copyCString(Device(name: "iPod touch").greeting, to: buffer, size: size)
}

@c func hello_sum_of_squares(_ n: Int) -> Int {
    sumOfSquares(upTo: n)
}
