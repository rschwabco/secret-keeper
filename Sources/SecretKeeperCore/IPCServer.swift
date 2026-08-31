import Foundation
import Darwin

public actor IPCServer {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let socketPath: String
    private var serverFD: Int32 = -1
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.secretkeeper.ipc.accept")
    private var running = false

    public init(
        socketURL: URL = SecretKeeperPaths.socketURL,
        handler: @escaping Handler
    ) {
        self.socketPath = socketURL.path
        self.handler = handler
    }

    public func start() throws {
        try SecretKeeperPaths.ensureDirectoriesExist()
        if FileManager.default.fileExists(atPath: socketPath) {
            try FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SecretKeeperError.ipcFailure("socket() failed")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try Self.writeUnixPath(socketPath, into: &addr)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SecretKeeperError.ipcFailure("bind() failed (\(errno))")
        }

        guard Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw SecretKeeperError.ipcFailure("listen() failed")
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: socketPath
        )

        serverFD = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.blockingAcceptLoop(serverFD: fd)
        }
    }

    public func stop() {
        running = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    nonisolated private func blockingAcceptLoop(serverFD: Int32) {
        while true {
            let client = Darwin.accept(serverFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Task { await self.serve(clientFD: client) }
        }
    }

    private func serve(clientFD: Int32) async {
        defer { close(clientFD) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        while true {
            let n = read(clientFD, &chunk, chunk.count)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            while let range = buffer.range(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                guard !line.isEmpty else { continue }

                let response: IPCResponse
                do {
                    let request = try IPCCoding.decodeLine(line, as: IPCRequest.self)
                    response = await handler(request)
                } catch {
                    response = .failure(
                        id: "unknown",
                        error: "Malformed request: \(error.localizedDescription)"
                    )
                }

                do {
                    let data = try IPCCoding.encodeLine(response)
                    _ = data.withUnsafeBytes { ptr in
                        write(clientFD, ptr.baseAddress!, data.count)
                    }
                } catch {
                    return
                }
            }
        }
    }

    nonisolated static func writeUnixPath(_ path: String, into addr: inout sockaddr_un) throws {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count + 1 <= capacity else {
            throw SecretKeeperError.ipcFailure("Socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
    }
}
