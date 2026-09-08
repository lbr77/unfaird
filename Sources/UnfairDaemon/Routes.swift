import Vapor

struct HealthResponse: Content {
    let status: String
    let service: String
    let buildCommit: String
    let buildTimestamp: String

    enum CodingKeys: String, CodingKey {
        case status
        case service
        case buildCommit = "build_commit"
        case buildTimestamp = "build_timestamp"
    }
}

func routes(_ app: Application) throws {
    app.get { _ in
        HealthResponse.current
    }

    app.get("health") { _ in
        HealthResponse.current
    }

    app.on(.POST, "api", "v1", "decrypt", body: .stream) { req -> EventLoopFuture<DecryptResponse> in
        if let contentLength = req.headers.first(name: .contentLength).flatMap(Int64.init),
           contentLength > DecryptService.maxUploadBytes {
            throw Abort(.payloadTooLarge, reason: "upload limit is 8GB")
        }
        return DecryptUploadReader.read(from: req).flatMap { upload in
            req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
                try DecryptService().run(upload)
            }
        }
    }

    app.get("api", "v1", "decrypt", ":id", "output") { req -> Response in
        guard let id = req.parameters.get("id"),
              let jobID = UUID(uuidString: id)
        else {
            throw Abort(.badRequest, reason: "valid job id required")
        }

        let output = try DecryptService.validatedOutputURL(for: jobID)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw Abort(.notFound, reason: "output ipa missing")
        }

        return req.fileio.streamFile(at: output.path)
    }
}

private extension HealthResponse {
    static var current: HealthResponse {
        HealthResponse(
            status: "ok",
            service: "unfaird",
            buildCommit: BuildInfo.commit,
            buildTimestamp: BuildInfo.timestamp
        )
    }
}
