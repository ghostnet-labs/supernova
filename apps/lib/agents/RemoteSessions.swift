import CryptoKit
import Foundation

struct SessionEndpoint: Hashable {
    let source: SessionSource
    var host = ""
    var label: String { host.isEmpty ? source.rawValue : "\(host) · \(source.rawValue)" }
}

extension CodexSession {
    var endpoint: SessionEndpoint { SessionEndpoint(source: source, host: sshHost) }
}

enum RemoteSessions {
    static func hosts(_ text: String) throws -> [String] {
        let hosts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        for host in hosts {
            guard host.count <= 253, host.range(of: "^[A-Za-z0-9][A-Za-z0-9._@-]*$", options: .regularExpression) != nil else {
                throw ProviderError("Enter SSH host aliases or user@hostname, without options or shell commands.")
            }
        }
        return Array(Set(hosts)).sorted()
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func arguments(host: String, command: String, interactive: Bool = false) -> [String] {
        [interactive ? "-tt" : "-T", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=10",
         "-oServerAliveInterval=15", "-oServerAliveCountMax=2", "-oClearAllForwardings=yes", "--", host, command]
    }

    // Send our matching reader in memory. The host needs only Python 3; no checkout,
    // installation, login-shell output, or remote code version is involved.
    static func bootstrap(source: SessionSource, interval: Int) throws -> (command: String, payload: Data) {
        let script = try source.commandURL().resolvingSymlinksInPath()
        let module = script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("apps/agent-workspace/session_stream.py")
        let payload = try JSONSerialization.data(withJSONObject: [
            "script": String(contentsOf: script, encoding: .utf8), "module": String(contentsOf: module, encoding: .utf8)
        ])
        let code = """
        import json, os, sys, types
        if sys.version_info < (3, 10): raise SystemExit('Remote sessions require Python 3.10 or newer')
        remaining = int(sys.argv[1])
        chunks = []
        while remaining:
            chunk = os.read(0, min(remaining, 65536))
            if not chunk: raise SystemExit('Incomplete session reader')
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = json.loads(b''.join(chunks))
        module = types.ModuleType('session_stream')
        sys.modules['session_stream'] = module
        exec(compile(payload['module'], '<session_stream>', 'exec'), module.__dict__)
        __file__ = '/agent-workspace/dotfiles/.bin/' + sys.argv[2]
        sys.argv = [__file__, '--stream-json', '--interval', sys.argv[3]]
        exec(compile(payload['script'], __file__, 'exec'), globals())
        """
        return ("exec python3 -u -c \(quote(code)) \(payload.count) \(quote(source.command)) \(interval)", payload)
    }

    static func cacheURL(_ directory: URL, id: String) -> URL {
        let name = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jsonl")
    }

    static func terminalCommand(_ session: CodexSession, resume: Bool = false) throws -> String {
        guard try hosts(session.sshHost) == [session.sshHost], session.cwd.hasPrefix("/") else {
            throw ProviderError("The remote host or working directory is unavailable.")
        }
        let action: String
        if resume {
            guard UUID(uuidString: session.nativeID) != nil, !session.isLive, !session.stale else {
                throw ProviderError("Resume is available only for an inactive, connected remote session.")
            }
            action = "exec " + ([session.source.executable] + session.resumeArguments).map(quote).joined(separator: " ")
        } else if let live = session.live, !live.tmuxPane.isEmpty {
            let socket = live.tmuxSocket.isEmpty ? "" : " -S " + quote(live.tmuxSocket)
            action = "exec tmux\(socket) attach-session -t \(quote(live.tmuxPane))"
        } else if let live = session.live, !live.zellijSession.isEmpty {
            action = "exec zellij attach \(quote(live.zellijSession))"
        } else {
            action = "exec \"${SHELL:-/bin/sh}\" -l"
        }
        return "exec /usr/bin/ssh " + arguments(host: session.sshHost,
            command: "cd -- \(quote(session.cwd)) && \(action)", interactive: true).map(quote).joined(separator: " ")
    }
}
