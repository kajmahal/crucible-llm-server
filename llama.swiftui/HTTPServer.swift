import Foundation
import Network

/// Minimal HTTP server that serves an OpenAI-compatible chat completions API
class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private weak var llamaState: LlamaState?

    var isRunning: Bool { listener != nil }

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start(llamaState: LlamaState) throws {
        self.llamaState = llamaState
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: .global(qos: .userInitiated))
        print("HTTP Server started on port \(port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        print("HTTP Server stopped")
    }

    func getLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { continue }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveCompleteRequest(connection, accumulatedData: Data())
    }

    private func receiveCompleteRequest(_ connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, error == nil else {
                connection.cancel()
                return
            }

            var buffer = accumulatedData
            if let data = data { buffer.append(data) }
            let delimiter = Data("\r\n\r\n".utf8)
            guard let headerRange = buffer.range(of: delimiter) else {
                if isComplete { connection.cancel() }
                else { self.receiveCompleteRequest(connection, accumulatedData: buffer) }
                return
            }

            let headerEnd = headerRange.upperBound
            let headerText = String(data: buffer.prefix(headerRange.lowerBound), encoding: .utf8) ?? ""
            let expectedBodyLength = headerText.components(separatedBy: "\r\n").compactMap { line -> Int? in
                guard line.lowercased().hasPrefix("content-length:") else { return nil }
                return Int(line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
            }.first ?? 0
            let expectedLength = headerEnd + expectedBodyLength

            guard buffer.count >= expectedLength else {
                if isComplete { connection.cancel() }
                else { self.receiveCompleteRequest(connection, accumulatedData: buffer) }
                return
            }

            let requestData = buffer.prefix(expectedLength)
            guard let request = String(data: requestData, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.routeRequest(request, connection: connection)
        }
    }
    private func routeRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Bad Request\"}")
            return
        }

        let method = parts[0]
        let path = parts[1]

        // CORS headers for all responses
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "200 OK", body: "", extraHeaders: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type, Authorization"
            ])
            return
        }

        switch path {
        case "/":
            sendResponse(connection: connection, status: "200 OK", body: "Crucible LLM Server is running")
        case "/version":
            handleVersion(connection: connection)
        case "/v1/models", "/api/tags":
            handleModels(connection: connection)
        case "/v1/chat/completions":
            if method == "POST" {
                handleChatCompletion(request: request, connection: connection)
            } else {
                sendResponse(connection: connection, status: "405 Method Not Allowed", body: "{\"error\":\"Method Not Allowed\"}")
            }
        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Not Found\"}")
        }
    }

    private func handleVersion(connection: NWConnection) {
        let commit = Bundle.main.object(forInfoDictionaryKey: "CrucibleGitCommit") as? String ?? "unknown"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let payload: [String: Any] = ["app": "CrucibleLLM", "version": version, "build": build,
                                      "commit": commit, "context": 8192, "streaming": true,
                                      "runtime": "8k-metal-sse-http-framing"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let response = String(data: data, encoding: .utf8) else { return }
        sendResponse(connection: connection, status: "200 OK", body: response, contentType: "application/json")
    }
    private func handleModels(connection: NWConnection) {
        let response = """
        {"object":"list","data":[{"id":"local","object":"model","created":0,"owned_by":"local"}]}
        """
        sendResponse(connection: connection, status: "200 OK", body: response, contentType: "application/json")
    }

    private func handleChatCompletion(request: String, connection: NWConnection) {
        // Extract JSON body from HTTP request
        guard let bodyStart = request.range(of: "\r\n\r\n")?.upperBound else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"No body\"}", contentType: "application/json")
            return
        }

        let bodyString = String(request[bodyStart...])
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid JSON\"}", contentType: "application/json")
            return
        }

        // Preserve OpenAI roles/content and let llama.cpp apply the chat template embedded in the GGUF.
        let chatMessages: [LlamaChatInput] = messages.compactMap { msg in
            guard let role = msg["role"] as? String,
                  let content = msg["content"] as? String else { return nil }
            return LlamaChatInput(role: role, content: content)
        }
        guard !chatMessages.isEmpty else {
            sendResponse(connection: connection, status: "400 Bad Request",
                         body: "{\"error\":\"No valid messages\"}", contentType: "application/json")
            return
        }

        let maxTokens = json["max_tokens"] as? Int ?? 2048
        let stream = json["stream"] as? Bool ?? false

        // Run inference on a background thread
        Task {
            guard let llamaState = await self.llamaState else {
                self.sendResponse(connection: connection, status: "500 Internal Server Error",
                                  body: "{\"error\":\"No model loaded\"}", contentType: "application/json")
                return
            }

            if stream {
                let streamID = "chatcmpl-\(UUID().uuidString.prefix(8))"
                self.sendStreamingHeaders(connection: connection)
                self.sendStreamChunk(connection: connection, id: streamID, role: "assistant")
                _ = await llamaState.completeForAPIStreaming(messages: chatMessages, maxTokens: maxTokens) { chunk in
                    self.sendStreamChunk(connection: connection, id: streamID, content: chunk)
                }
                self.finishStream(connection: connection, id: streamID)
                return
            }

            let result = await llamaState.completeForAPI(messages: chatMessages, maxTokens: maxTokens)

            let responseJSON: [String: Any] = [
                "id": "chatcmpl-\(UUID().uuidString.prefix(8))",
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": "local",
                "choices": [[
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": result
                    ],
                    "finish_reason": "stop"
                ]]
            ]

            if let jsonData = try? JSONSerialization.data(withJSONObject: responseJSON),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: "200 OK", body: jsonString, contentType: "application/json")
            } else {
                self.sendResponse(connection: connection, status: "500 Internal Server Error",
                                  body: "{\"error\":\"Failed to serialize response\"}", contentType: "application/json")
            }
        }
    }

    private func sendStreamingHeaders(connection: NWConnection) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        connection.send(content: headers.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func streamChunkJSON(id: String, role: String? = nil, content: String? = nil,
                                 finishReason: String? = nil) -> String? {
        var delta: [String: Any] = [:]
        if let role = role { delta["role"] = role }
        if let content = content { delta["content"] = content }
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finishReason = finishReason { choice["finish_reason"] = finishReason }
        else { choice["finish_reason"] = NSNull() }
        let payload: [String: Any] = [
            "id": id, "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970), "model": "local",
            "choices": [choice]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func sendStreamChunk(connection: NWConnection, id: String, role: String? = nil,
                                 content: String? = nil, finishReason: String? = nil) {
        guard let json = streamChunkJSON(id: id, role: role, content: content, finishReason: finishReason),
              let data = "data: \(json)\n\n".data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finishStream(connection: NWConnection, id: String) {
        guard let json = streamChunkJSON(id: id, finishReason: "stop"),
              let data = "data: \(json)\n\ndata: [DONE]\n\n".data(using: .utf8) else {
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func sendResponse(connection: NWConnection, status: String, body: String,
                              contentType: String = "text/plain", extraHeaders: [String] = []) {
        var headers = "HTTP/1.1 \(status)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.utf8.count)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Connection: close\r\n"
        for header in extraHeaders {
            headers += "\(header)\r\n"
        }
        headers += "\r\n"

        let responseData = (headers + body).data(using: .utf8)!
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
