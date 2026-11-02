// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool

import Foundation
import Testing

@testable import KraalHC

@Suite("Core paths")
struct HcPathsTests {
    private func resolve(
        _ environment: [String: String] = [:],
        home: String = "/Users/tester",
        uid: UInt32 = 501,
        existing: Set<String> = [],
        config: String? = nil
    ) throws -> HcPaths {
        try HcPaths.resolve(
            environment: environment,
            home: home,
            uid: uid,
            fileExists: { existing.contains($0) },
            readText: { path in
                path.hasSuffix("config.toml") ? config : nil
            }
        )
    }

    @Test("defaults to the state dir when there is no runtime dir")
    func defaultLayout() throws {
        let paths = try resolve()
        #expect(paths.session == "default")
        #expect(paths.socket == "/Users/tester/.local/state/herdr-core/default/default.sock")
        #expect(paths.stateDirectory == "/Users/tester/.local/state/herdr-core/default")
        #expect(paths.configFile == "/Users/tester/.config/herdr-core/config.toml")
        #expect(paths.lockFile == "/Users/tester/.local/state/herdr-core/default/core.lock")
    }

    @Test("XDG_RUNTIME_DIR wins over the state dir")
    func runtimeDir() throws {
        let paths = try resolve(["XDG_RUNTIME_DIR": "/tmp/runtime"])
        #expect(paths.socket == "/tmp/runtime/herdr-core/default.sock")
    }

    @Test("uses /run/user when it exists and XDG_RUNTIME_DIR is unset")
    func perUserRuntime() throws {
        let paths = try resolve(
            ["HC_SESSION": "dev"],
            existing: ["/run/user/501"]
        )
        #expect(paths.socket == "/run/user/501/herdr-core/dev.sock")
    }

    @Test("HC_SOCKET overrides everything")
    func socketOverride() throws {
        let paths = try resolve(
            ["HC_SOCKET": "/tmp/explicit.sock", "XDG_RUNTIME_DIR": "/tmp/runtime"],
            config: #"socket = "/tmp/config.sock""#
        )
        #expect(paths.socket == "/tmp/explicit.sock")
    }

    @Test("config.toml socket is next")
    func configSocket() throws {
        let paths = try resolve(
            ["XDG_RUNTIME_DIR": "/tmp/runtime"],
            config: "socket = \"/tmp/config.sock\" # comment\n"
        )
        #expect(paths.socket == "/tmp/config.sock")
    }

    @Test("ignores socket keys inside a section")
    func configSection() throws {
        let paths = try resolve(config: "[other]\nsocket = \"/tmp/no.sock\"\n")
        #expect(paths.socket.hasSuffix("/default/default.sock"))
    }

    @Test("accepts only safe session names")
    func sessionValidation() throws {
        #expect(try HcPaths.validatedSession(nil) == "default")
        #expect(try HcPaths.validatedSession("  ") == "default")
        #expect(try HcPaths.validatedSession(" dev ") == "dev")
        #expect(try HcPaths.validatedSession("a-b_c.d") == "a-b_c.d")
        for bad in [".", "..", "a/b", "a:b", "a\\b", "a|b", "a\u{7}b"] {
            #expect(throws: HcPathError.self) {
                _ = try HcPaths.validatedSession(bad)
            }
        }
    }

    @Test("reports an over-long socket path before dialing")
    func tooLong() {
        #expect(throws: HcPathError.self) {
            _ = try resolve(["HC_SESSION": String(repeating: "a", count: 200)])
        }
    }

    @Test("reads the socket the core recorded when it differs")
    func lockFileHint() async throws {
        try await withTempDirectory { directory in
            let paths = HcPaths(
                session: "dev",
                socket: "/tmp/computed.sock",
                stateDirectory: directory,
                configFile: directory + "/config.toml"
            )
            try "/tmp/actual.sock\n".write(
                toFile: paths.lockFile,
                atomically: true,
                encoding: .utf8
            )
            #expect(paths.recordedSocket() == "/tmp/actual.sock")
        }
    }

    @Test("has no hint when the lock matches or is missing")
    func noLockHint() {
        let paths = HcPaths(
            session: "dev",
            socket: "/tmp/computed.sock",
            stateDirectory: "/nonexistent",
            configFile: "/nonexistent/config.toml"
        )
        #expect(paths.recordedSocket() == nil)
    }
}
