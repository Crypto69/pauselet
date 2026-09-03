import Foundation
import ReminderCore

/// Turns free text into exercises using something cleverer than the built-in
/// parser.
///
/// A protocol so the import sheet can be driven by a stub in tests, previews
/// and snapshots without a network or an API key — the same seam
/// `SpeechCoaching` gives the voice coach.
public protocol ExerciseInterpreting: Sendable {
    /// Interprets `text`, or throws if it cannot.
    ///
    /// Implementations return rows already passed through
    /// `Exercise.normalized(_:)`, so a caller can never receive an exercise the
    /// editor would reject however the model answered.
    func interpret(_ text: String) async throws -> [Exercise]
}

/// The models offered for interpreting exercise text.
///
/// Deliberately a short list rather than a free-text field: a typo in a model
/// name surfaces as an opaque API error, and none of the larger models are
/// worth their cost for pulling six numbers out of a paragraph.
public enum AIImportModel: String, CaseIterable, Identifiable, Sendable {
    case nano = "gpt-5-nano"
    case luna = "gpt-5.6-luna"
    case mini = "gpt-5-mini"

    public var id: String { rawValue }

    /// The one used when the user has not chosen.
    ///
    /// Not the cheapest on the list, deliberately. Measured on a three-exercise
    /// paragraph, `gpt-5-nano` took 31 s and `gpt-5.6-luna` 6 s: the nano tier
    /// spends far more reasoning effort on a small extraction than the task
    /// warrants, and 30 s of staring at a spinner is the difference between a
    /// feature that saves time and one that does not. Luna is still well under
    /// a tenth of a cent per import, and read the same text more accurately.
    public static let `default`: AIImportModel = .luna

    /// Resolves the stored setting, falling back to the default for `nil` or
    /// for a model that has since been retired.
    public static func resolve(_ identifier: String?) -> AIImportModel {
        guard let identifier, let model = AIImportModel(rawValue: identifier) else {
            return .default
        }
        return model
    }

    public var title: String {
        switch self {
        case .nano: return "GPT-5 nano (cheapest, but slow)"
        case .luna: return "GPT-5.6 Luna (recommended)"
        case .mini: return "GPT-5 mini"
        }
    }

    public var detail: String {
        switch self {
        case .nano: return "Cheapest, but often takes 30 seconds or more to answer."
        case .luna: return "Reads flowing prose well and answers in a few seconds."
        case .mini: return "Better with unusual wording or long programmes."
        }
    }
}

/// Something went wrong talking to OpenAI, phrased for the person who pasted
/// the text rather than for a log.
public enum AIImportError: LocalizedError, Equatable {
    case missingKey
    case unauthorized
    case rateLimited
    case offline
    case timedOut
    case server(status: Int, message: String?)
    case unreadableResponse
    case nothingFound

    public var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add an OpenAI API key in Settings to interpret text with AI."
        case .unauthorized:
            return "That API key was rejected. Check it in Settings."
        case .rateLimited:
            return "OpenAI is rate limiting this key. Try again in a moment."
        case .offline:
            return "No connection to OpenAI. The built-in parser still works."
        case .timedOut:
            return "OpenAI took too long to answer. Try again, or use Read Text."
        case let .server(status, message):
            return message ?? "OpenAI returned an error (\(status))."
        case .unreadableResponse:
            return "OpenAI's reply could not be read."
        case .nothingFound:
            return "No exercises were found in that text."
        }
    }
}

/// Interprets exercise text with OpenAI's Responses API, using Structured
/// Outputs so the reply is guaranteed to match the schema below rather than
/// being prose we then have to salvage.
public struct OpenAIExerciseInterpreter: ExerciseInterpreting {
    private let apiKey: String
    private let model: AIImportModel
    private let session: URLSession
    private let endpoint: URL

    public init(
        apiKey: String,
        model: AIImportModel = .default,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.endpoint = endpoint
    }

    public func interpret(_ text: String) async throws -> [Exercise] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIImportError.nothingFound }
        guard !apiKey.isEmpty else { throw AIImportError.missingKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(for: trimmed))
        // Generous: a reasoning model working through a whole programme
        // regularly takes over 30 seconds, and a slow answer is still the
        // answer the person asked for.
        request.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.offlineCodes.contains(error.code) {
            throw AIImportError.offline
        } catch let error as URLError where error.code == .timedOut {
            throw AIImportError.timedOut
        }

        guard let http = response as? HTTPURLResponse else { throw AIImportError.unreadableResponse }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw AIImportError.unauthorized
        case 429: throw AIImportError.rateLimited
        default: throw AIImportError.server(status: http.statusCode, message: Self.message(in: data))
        }

        let payload = try Self.structuredText(in: data)
        let decoded = try Self.decode(payload)
        guard let normalized = Exercise.normalized(decoded), !normalized.isEmpty else {
            throw AIImportError.nothingFound
        }
        return normalized
    }

    /// Codes that really do mean "the request never got there". `.timedOut`
    /// is deliberately absent: it means OpenAI was reachable but slow, and
    /// reporting that as a connection fault sends people to check a network
    /// that was never broken.
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .dataNotAllowed, .internationalRoamingOff,
    ]

    // MARK: - Request

    private func body(for text: String) -> [String: Any] {
        [
            "model": model.rawValue,
            "input": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": text],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "exercises",
                    "strict": true,
                    "schema": Self.schema,
                ]
            ],
        ]
    }

    /// Extraction, not authoring. The model must not invent a hold time that
    /// was never prescribed — a wrong number here becomes a wrong instruction
    /// during someone's rehabilitation.
    static let systemPrompt = """
        You convert physiotherapy exercise instructions into structured data.

        Rules:
        - Extract only what the text states. Never invent or infer timings.
        - When a value is not stated use these defaults: sets 3, reps 10, \
        holdSeconds 0, restBetweenRepsSeconds 0, restBetweenSetsSeconds 0.
        - All durations are in whole seconds. Convert minutes.
        - "name" is a short exercise name, without counts or timings.
        - "instructions" is any remaining guidance on how to perform it, \
        verbatim where possible, or an empty string.
        - One object per distinct exercise, in the order given.
        - If the text describes no exercises, return an empty array.
        """

    /// Mirrors `Exercise`'s stored fields. `strict: true` requires every
    /// property to be listed as required and additional ones forbidden, so the
    /// reply always decodes.
    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["exercises"],
        "properties": [
            "exercises": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "name", "instructions", "sets", "reps",
                        "holdSeconds", "restBetweenRepsSeconds", "restBetweenSetsSeconds",
                    ],
                    "properties": [
                        "name": ["type": "string"],
                        "instructions": ["type": "string"],
                        "sets": ["type": "integer"],
                        "reps": ["type": "integer"],
                        "holdSeconds": ["type": "integer"],
                        "restBetweenRepsSeconds": ["type": "integer"],
                        "restBetweenSetsSeconds": ["type": "integer"],
                    ],
                ],
            ]
        ],
    ]

    // MARK: - Response

    /// Digs the JSON string out of the Responses envelope.
    ///
    /// `output_text` is the convenience field; the walk over `output` is the
    /// documented shape and the fallback when it is absent.
    static func structuredText(in data: Data) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIImportError.unreadableResponse
        }
        if let text = root["output_text"] as? String, !text.isEmpty {
            return Data(text.utf8)
        }
        guard let output = root["output"] as? [[String: Any]] else {
            throw AIImportError.unreadableResponse
        }
        for item in output {
            guard let contents = item["content"] as? [[String: Any]] else { continue }
            for content in contents {
                if let text = content["text"] as? String, !text.isEmpty {
                    return Data(text.utf8)
                }
            }
        }
        throw AIImportError.unreadableResponse
    }

    /// Decodes the model's payload into exercises.
    ///
    /// Decoded field by field rather than through `Exercise`'s own `Codable`,
    /// because the model does not send an `id` and must never be able to set
    /// one — identity is ours to assign.
    static func decode(_ payload: Data) throws -> [Exercise] {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let rows = root["exercises"] as? [[String: Any]] else {
            throw AIImportError.unreadableResponse
        }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Exercise(
                name: name,
                instructions: row["instructions"] as? String ?? "",
                sets: integer(row["sets"]) ?? 3,
                reps: integer(row["reps"]) ?? 10,
                holdSeconds: integer(row["holdSeconds"]) ?? 0,
                restBetweenRepsSeconds: integer(row["restBetweenRepsSeconds"]) ?? 0,
                restBetweenSetsSeconds: integer(row["restBetweenSetsSeconds"]) ?? 0
            )
        }
    }

    /// Accepts a number written as a JSON number or as a string — models are
    /// not always consistent, and a quoted "3" should not lose the count.
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// The human-readable half of an OpenAI error body, when there is one.
    static func message(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

/// A stand-in interpreter for previews, snapshots and tests: answers instantly
/// from the built-in parser instead of reaching the network, so nothing that
/// renders the UI can make a request or need a key.
public struct PreviewExerciseInterpreter: ExerciseInterpreting {
    private let result: [Exercise]?

    /// - Parameter result: what to return; `nil` parses the text locally.
    public init(result: [Exercise]? = nil) { self.result = result }

    public func interpret(_ text: String) async throws -> [Exercise] {
        if let result { return result }
        return ExerciseImporter.parse(text)
    }
}
