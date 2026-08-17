import Foundation
import Darwin

let arguments = CommandLine.arguments.dropFirst().joined(separator: " ")
print("OmoUsage OpenCode authentication fixture")
print("arguments: \(arguments)")
print("provider 선택: OpenCode")
print("Ctrl-C로 안전하게 취소하세요.")
fflush(stdout)

while readLine() != nil {}
