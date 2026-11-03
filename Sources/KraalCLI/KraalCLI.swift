// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// `kraal` is the window control CLI: commands/ls/status/do/shot. The Herdr 1
// endpoint probe and its `herdr` subprocess helpers were removed with the old
// client stack; there is nothing left to talk to directly.

import Foundation
import KraalActions

@main
enum KraalCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if runControlCommand(arguments) { return }
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
            printControlUsage()
            exit(arguments.isEmpty ? 2 : 0)
        }
        FileHandle.standardError.write(Data("kraal: unknown command\n".utf8))
        printControlUsage()
        exit(2)
    }
}

func printCommands() {
    do {
        print(try KraalActions.listingJSON())
    } catch {
        FileHandle.standardError.write(Data(("kraal: cannot encode commands: \(error)\n").utf8))
        exit(2)
    }
}
