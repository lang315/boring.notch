import Foundation

/// Minimal assertion for the standalone CodeBurn check programs (no XCTest target exists).
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8))
        exit(1)
    }
}
