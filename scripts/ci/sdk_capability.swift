import Foundation
#if canImport(MusicUnderstanding)
import MusicUnderstanding
#endif

// Check the actual selected SDK branch rather than infer it from a runner label.
guard CommandLine.arguments.count == 2,
      ["enabled", "disabled"].contains(CommandLine.arguments[1]) else {
    fatalError("usage: sdk_capability.swift enabled|disabled")
}
#if canImport(MusicUnderstanding)
let compiled = "enabled"
#else
let compiled = "disabled"
#endif
guard compiled == CommandLine.arguments[1] else {
    fatalError("MusicUnderstanding compile capability was \(compiled), expected \(CommandLine.arguments[1])")
}
print("MusicUnderstanding compile capability: \(compiled)")
print("This probes SDK availability, not successful live music analysis.")
