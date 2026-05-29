import Foundation

/// Strips ANSI escape sequences from text. Invoked on `ShellRunner` stdout before
/// `TextInjector.inject` so users don't see raw color codes pasted into their docs.
///
/// Handles:
/// - CSI (Control Sequence Introducer): ESC `[` ... letter (e.g. `[31m`).
/// - OSC (Operating System Command): ESC `]` ... BEL or ESC `\`.
/// - Bare ESC followed by an unrecognized intro: drop the ESC byte.
enum ANSIStripper {
    static func strip(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "\u{001B}" {
                let next = input.index(after: i)
                if next < input.endIndex {
                    let intro = input[next]
                    if intro == "[" {
                        var j = input.index(after: next)
                        while j < input.endIndex {
                            let cc = input[j]
                            if let scalar = cc.unicodeScalars.first,
                               (0x40...0x7E).contains(Int(scalar.value)) {
                                j = input.index(after: j)
                                break
                            }
                            j = input.index(after: j)
                        }
                        i = j
                        continue
                    } else if intro == "]" {
                        var j = input.index(after: next)
                        while j < input.endIndex {
                            let cc = input[j]
                            if cc == "\u{0007}" {
                                j = input.index(after: j)
                                break
                            }
                            if cc == "\u{001B}" {
                                let k = input.index(after: j)
                                if k < input.endIndex, input[k] == "\\" {
                                    j = input.index(after: k)
                                    break
                                }
                            }
                            j = input.index(after: j)
                        }
                        i = j
                        continue
                    } else {
                        i = next
                        continue
                    }
                } else {
                    break
                }
            }
            out.append(c)
            i = input.index(after: i)
        }
        return out
    }
}
