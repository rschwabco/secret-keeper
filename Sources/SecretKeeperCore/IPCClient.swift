import Foundation
import Darwin

public struct IPCClient: Sendable {
    private let socketPath: String
    private let timeoutSeconds: Int

    public init(
        socketURL: URL = SecretKeeperPaths.socketURL,
        timeoutSeconds: Int = 5
    ) {
        self.socketPath = socketURL.path
        self.timeoutSeconds = timeoutSeconds
    }

    public func send(_ request: IPCRequest) async throws -> IPCResponse {
        try await Task.detached {
            try Self.sendSync(request, socketPath: self.socketPath, timeoutSeconds: self.timeoutSeconds)
        }.value
    }

    private static func sendSync(
        _ request: IPCRequest,
        socketPath: String,
        timeoutSeconds: Int
    ) throws -> IPCResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw SecretKeeperError.appNotRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SecretKeeperError.ipcFailure("socket() failed")
        }
        defer { close(fd) }

        var timeval = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try IPCServer.writeUnixPath(socketPath, into: &addr)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SecretKeeperError.ipcFailure("connect() failed (\(errno))")
        }

        let payload = try IPCCoding.encodeLine(request)
        let written = payload.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, payload.count)
        }
        guard written == payload.count else {
            throw SecretKeeperError.ipcFailure("Failed to write request")
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SecretKeeperError.ipcFailure("read() failed (\(errno))")
            }
            if n == 0 {
                throw SecretKeeperError.ipcFailure("Connection closed without response")
            }
            buffer.append(contentsOf: chunk[0..<n])
            if let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                return try IPCCoding.decodeLine(line, as: IPCResponse.self)
            }
        }
    }
}
