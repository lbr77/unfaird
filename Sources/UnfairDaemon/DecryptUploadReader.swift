import Foundation
import Vapor

enum DecryptUploadReader {
    fileprivate static let maxTextBytes = 64 * 1024

    static func read(from req: Request) -> EventLoopFuture<DecryptUpload> {
        if req.headers.contentType?.type.lowercased() == "multipart" {
            return streamMultipart(req)
        }
        return req.body.collect(max: maxTextBytes).flatMapThrowing { _ in
            try req.content.decode(DecryptUpload.self)
        }
    }

    private static func streamMultipart(_ req: Request) -> EventLoopFuture<DecryptUpload> {
        guard let boundary = req.headers.contentType?.parameters["boundary"], boundary.isEmpty == false else {
            return req.eventLoop.makeFailedFuture(Abort(.badRequest, reason: "multipart boundary required"))
        }
        let session = Session(request: req, boundary: boundary)
        session.start()
        return session.promise.futureResult
    }
}

private final class Session {
    let promise: EventLoopPromise<DecryptUpload>
    private let request: Request
    private let parser: MultipartParser
    private var writes: EventLoopFuture<Void>
    private var headers = HTTPHeaders()
    private var started = false
    private var name: String?
    private var text = ByteBufferAllocator().buffer(capacity: 0)
    private var pending = ByteBufferAllocator().buffer(capacity: 0)
    private var handle: FileHandle?
    private var stagedURL: URL?
    private var ipaFilename: String?
    private var url: String?
    private var ipaURL: String?
    private var received: Int64 = 0
    private var finished = false
    private var failure: Error?

    init(request: Request, boundary: String) {
        self.request = request
        self.promise = request.eventLoop.makePromise(of: DecryptUpload.self)
        self.parser = MultipartParser(boundary: boundary)
        self.writes = request.eventLoop.makeSucceededFuture(())
        parser.onHeader = { [weak self] name, value in
            self?.headers.add(name: name, value: value)
        }
        parser.onBody = { [weak self] buffer in
            self?.appendBody(&buffer)
        }
        parser.onPartComplete = { [weak self] in
            self?.endPart()
        }
    }

    func start() {
        request.body.drain { result in
            self.handle(result)
        }
    }

    private func handle(_ result: BodyStreamResult) -> EventLoopFuture<Void> {
        switch result {
        case .buffer(let buffer):
            guard finished == false else {
                return request.eventLoop.makeSucceededFuture(())
            }
            received += Int64(buffer.readableBytes)
            guard received <= DecryptService.maxUploadBytes else {
                return fail(Abort(.payloadTooLarge, reason: "upload limit is 8GB"))
            }
            do {
                try parser.execute(buffer)
            } catch {
                return fail(Abort(.badRequest, reason: "invalid multipart body"))
            }
            if let failure {
                return request.eventLoop.makeFailedFuture(failure)
            }
            flush()
            return writes
        case .error(let error):
            return fail(error)
        case .end:
            return complete()
        }
    }

    private func appendBody(_ buffer: inout ByteBuffer) {
        guard finished == false else {
            return
        }
        beginPart()
        guard finished == false else {
            return
        }
        if name == "ipa" {
            pending.writeBuffer(&buffer)
            return
        }
        guard name == "url" || name == "ipa_url" else {
            return
        }
        text.writeBuffer(&buffer)
        if text.readableBytes > DecryptUploadReader.maxTextBytes {
            _ = fail(Abort(.payloadTooLarge, reason: "request body too large"))
        }
    }

    private func beginPart() {
        guard started == false else {
            return
        }
        started = true
        name = headers.contentDisposition?.name
        guard name == "ipa" else {
            return
        }
        if ipaFilename != nil {
            _ = fail(Abort(.badRequest, reason: "provide one ipa file or one ipa_url"))
            return
        }
        guard let filename = headers.contentDisposition?.filename,
              filename.lowercased().hasSuffix(".ipa")
        else {
            _ = fail(Abort(.badRequest, reason: "ipa file required"))
            return
        }
        do {
            let fileURL = try DecryptService.makeStagedUploadURL()
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Abort(.internalServerError, reason: "failed to stage upload")
            }
            stagedURL = fileURL
            ipaFilename = filename
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            _ = fail(error)
        }
    }

    private func endPart() {
        guard finished == false else {
            return
        }
        beginPart()
        guard finished == false else {
            return
        }
        flush()
        if name == "ipa" {
            let handle = self.handle
            self.handle = nil
            writes = writes.flatMap { self.close(handle) }
        } else if name == "url" {
            url = text.readString(length: text.readableBytes)
        } else if name == "ipa_url" {
            ipaURL = text.readString(length: text.readableBytes)
        }
        headers = HTTPHeaders()
        started = false
        name = nil
        text.clear()
    }

    private func complete() -> EventLoopFuture<Void> {
        guard finished == false else {
            return request.eventLoop.makeSucceededFuture(())
        }
        writes.whenComplete { result in
            switch result {
            case .failure(let error):
                _ = self.fail(error)
            case .success:
                if self.handle != nil {
                    _ = self.fail(Abort(.badRequest, reason: "incomplete upload"))
                    return
                }
                self.finished = true
                self.promise.succeed(
                    DecryptUpload(ipa: self.stagedFile(), url: self.url, ipaURL: self.ipaURL)
                )
            }
        }
        return writes
    }

    private func fail(_ error: Error) -> EventLoopFuture<Void> {
        guard finished == false else {
            return request.eventLoop.makeSucceededFuture(())
        }
        finished = true
        failure = error
        let handle = self.handle
        self.handle = nil
        writes.whenComplete { _ in
            try? handle?.close()
            if let url = self.stagedURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.promise.fail(error)
        }
        return request.eventLoop.makeFailedFuture(error)
    }

    private func flush() {
        var buffer = pending
        pending = ByteBufferAllocator().buffer(capacity: 0)
        guard let handle, buffer.readableBytes > 0 else {
            return
        }
        guard let data = buffer.readData(length: buffer.readableBytes) else {
            return
        }
        writes = writes.flatMap {
            self.request.application.threadPool.runIfActive(eventLoop: self.request.eventLoop) {
                handle.write(data)
            }
        }
    }

    private func close(_ handle: FileHandle?) -> EventLoopFuture<Void> {
        guard let handle else {
            return request.eventLoop.makeSucceededFuture(())
        }
        return request.application.threadPool.runIfActive(eventLoop: request.eventLoop) {
            try handle.close()
        }
    }

    private func stagedFile() -> StagedIPAFile? {
        guard let filename = ipaFilename, let url = stagedURL else {
            return nil
        }
        return StagedIPAFile(filename: filename, url: url)
    }
}
