using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Pauselet.Core;

/// <summary>
/// Turns free text into exercises using something cleverer than the built-in
/// parser. (Mirrors ExerciseInterpreting in ExerciseInterpreter.swift.)
///
/// An interface so the import dialog can be driven by a stub without a network
/// or an API key — the same seam <c>ISpeechCoaching</c> gives the voice coach.
/// </summary>
public interface IExerciseInterpreter
{
    /// <summary>
    /// Interprets <paramref name="text"/>, or throws
    /// <see cref="AIImportException"/> if it cannot.
    ///
    /// Implementations return rows already passed through
    /// <see cref="Exercise.Normalized"/>, so a caller can never receive an
    /// exercise the editor would reject however the model answered.
    /// </summary>
    Task<IReadOnlyList<Exercise>> InterpretAsync(
        string text, CancellationToken cancellationToken = default);
}

/// <summary>
/// The models offered for interpreting exercise text.
///
/// Deliberately a short list rather than a free-text field: a typo in a model
/// name surfaces as an opaque API error, and none of the larger models are
/// worth their cost for pulling six numbers out of a paragraph.
/// </summary>
public sealed record AIImportModel(string Id, string Title, string Detail)
{
    public static readonly AIImportModel Nano = new(
        "gpt-5-nano",
        "GPT-5 nano (cheapest, but slow)",
        "Cheapest, but often takes 30 seconds or more to answer.");

    public static readonly AIImportModel Luna = new(
        "gpt-5.6-luna",
        "GPT-5.6 Luna (recommended)",
        "Reads flowing prose well and answers in a few seconds.");

    public static readonly AIImportModel Mini = new(
        "gpt-5-mini",
        "GPT-5 mini",
        "Better with unusual wording or long programmes.");

    /// <summary>In the order the picker shows them, matching the Mac.</summary>
    public static readonly IReadOnlyList<AIImportModel> All = [Nano, Luna, Mini];

    /// <summary>
    /// The one used when the user has not chosen.
    ///
    /// Not the cheapest on the list, deliberately. Measured on a three-exercise
    /// paragraph, gpt-5-nano took 31 s and gpt-5.6-luna 6 s: the nano tier
    /// spends far more reasoning effort on a small extraction than the task
    /// warrants, and 30 s of staring at a spinner is the difference between a
    /// feature that saves time and one that does not.
    /// </summary>
    public static AIImportModel Default => Luna;

    /// <summary>
    /// Resolves the stored setting, falling back to the default for
    /// <c>null</c> or for a model that has since been retired.
    /// </summary>
    public static AIImportModel Resolve(string? identifier) =>
        All.FirstOrDefault(model => model.Id == identifier) ?? Default;
}

/// <summary>
/// Something went wrong talking to OpenAI, phrased for the person who pasted
/// the text rather than for a log.
/// </summary>
public sealed class AIImportException : Exception
{
    public enum Reason
    {
        MissingKey,
        Unauthorized,
        RateLimited,
        /// <summary>The request never got there.</summary>
        Offline,
        /// <summary>OpenAI was reachable but slow — a different fault from offline.</summary>
        TimedOut,
        Server,
        UnreadableResponse,
        NothingFound,
    }

    public Reason FailureReason { get; }

    private AIImportException(Reason reason, string message) : base(message) =>
        FailureReason = reason;

    public static AIImportException MissingKey() => new(
        Reason.MissingKey, "Add an OpenAI API key in Settings to interpret text with AI.");

    public static AIImportException Unauthorized() => new(
        Reason.Unauthorized, "That API key was rejected. Check it in Settings.");

    public static AIImportException RateLimited() => new(
        Reason.RateLimited, "OpenAI is rate limiting this key. Try again in a moment.");

    public static AIImportException Offline() => new(
        Reason.Offline, "No connection to OpenAI. The built-in parser still works.");

    public static AIImportException TimedOut() => new(
        Reason.TimedOut, "OpenAI took too long to answer. Try again, or use Read Text.");

    public static AIImportException Server(int status, string? message) => new(
        Reason.Server, message ?? $"OpenAI returned an error ({status}).");

    public static AIImportException UnreadableResponse() => new(
        Reason.UnreadableResponse, "OpenAI's reply could not be read.");

    public static AIImportException NothingFound() => new(
        Reason.NothingFound, "No exercises were found in that text.");
}

/// <summary>
/// Interprets exercise text with OpenAI's Responses API, using Structured
/// Outputs so the reply is guaranteed to match the schema below rather than
/// being prose we then have to salvage.
/// </summary>
public sealed class OpenAIExerciseInterpreter : IExerciseInterpreter
{
    /// <summary>
    /// Generous: a reasoning model working through a whole programme regularly
    /// takes over 30 seconds, and a slow answer is still the answer the person
    /// asked for.
    /// </summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(120);

    /// <summary>
    /// One client for the app's lifetime. A new <c>HttpClient</c> per request
    /// holds its socket open past disposal and eventually exhausts the port
    /// pool; one shared instance is the documented way to use it, and there is
    /// only ever one endpoint here.
    /// </summary>
    private static readonly HttpClient Shared = new() { Timeout = Timeout };

    private readonly string _apiKey;
    private readonly AIImportModel _model;
    private readonly HttpClient _client;
    private readonly Uri _endpoint;

    public OpenAIExerciseInterpreter(
        string apiKey,
        AIImportModel? model = null,
        HttpClient? client = null,
        Uri? endpoint = null)
    {
        _apiKey = apiKey;
        _model = model ?? AIImportModel.Default;
        // Tests inject their own; everything else shares the one above.
        _client = client ?? Shared;
        _endpoint = endpoint ?? new Uri("https://api.openai.com/v1/responses");
    }

    public async Task<IReadOnlyList<Exercise>> InterpretAsync(
        string text, CancellationToken cancellationToken = default)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) throw AIImportException.NothingFound();
        if (_apiKey.Length == 0) throw AIImportException.MissingKey();

        using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint)
        {
            Content = new StringContent(Body(trimmed), Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);

        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // HttpClient reports its own timeout as a cancellation; a genuine
            // caller cancellation is the guard above. Reported as timed out
            // rather than offline: saying "no connection" about a reachable
            // but slow service sends people to debug a working network.
            throw AIImportException.TimedOut();
        }
        catch (HttpRequestException)
        {
            throw AIImportException.Offline();
        }

        using (response)
        {
            var data = await response.Content
                .ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw response.StatusCode switch
                {
                    HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                        AIImportException.Unauthorized(),
                    HttpStatusCode.TooManyRequests => AIImportException.RateLimited(),
                    _ => AIImportException.Server((int)response.StatusCode, MessageIn(data)),
                };
            }

            var payload = StructuredText(data);
            var decoded = Decode(payload);
            var normalized = Exercise.Normalized(decoded);
            if (normalized is not { Count: > 0 }) throw AIImportException.NothingFound();
            return normalized;
        }
    }

    // MARK: - Request

    private string Body(string text)
    {
        // Written with the writer rather than an anonymous object so the schema
        // below reads as the JSON OpenAI documents, not as a C# shape that
        // happens to serialize to it.
        var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("model", _model.Id);

            writer.WriteStartArray("input");
            writer.WriteStartObject();
            writer.WriteString("role", "system");
            writer.WriteString("content", SystemPrompt);
            writer.WriteEndObject();
            writer.WriteStartObject();
            writer.WriteString("role", "user");
            writer.WriteString("content", text);
            writer.WriteEndObject();
            writer.WriteEndArray();

            writer.WriteStartObject("text");
            writer.WriteStartObject("format");
            writer.WriteString("type", "json_schema");
            writer.WriteString("name", "exercises");
            writer.WriteBoolean("strict", true);
            writer.WritePropertyName("schema");
            writer.WriteRawValue(Schema);
            writer.WriteEndObject();
            writer.WriteEndObject();

            writer.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    /// <summary>
    /// Extraction, not authoring. The model must not invent a hold time that
    /// was never prescribed — a wrong number here becomes a wrong instruction
    /// during someone's rehabilitation.
    /// </summary>
    internal const string SystemPrompt = """
        You convert physiotherapy exercise instructions into structured data.

        Rules:
        - Extract only what the text states. Never invent or infer timings.
        - When a value is not stated use these defaults: sets 3, reps 10, holdSeconds 0, restBetweenRepsSeconds 0, restBetweenSetsSeconds 0.
        - All durations are in whole seconds. Convert minutes.
        - "name" is a short exercise name, without counts or timings.
        - "instructions" is any remaining guidance on how to perform it, verbatim where possible, or an empty string.
        - One object per distinct exercise, in the order given.
        - If the text describes no exercises, return an empty array.
        """;

    /// <summary>
    /// Mirrors <see cref="Exercise"/>'s stored fields. <c>strict: true</c>
    /// requires every property to be listed as required and additional ones
    /// forbidden, so the reply always decodes.
    /// </summary>
    internal const string Schema = """
        {
          "type": "object",
          "additionalProperties": false,
          "required": ["exercises"],
          "properties": {
            "exercises": {
              "type": "array",
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": [
                  "name", "instructions", "sets", "reps",
                  "holdSeconds", "restBetweenRepsSeconds", "restBetweenSetsSeconds"
                ],
                "properties": {
                  "name": { "type": "string" },
                  "instructions": { "type": "string" },
                  "sets": { "type": "integer" },
                  "reps": { "type": "integer" },
                  "holdSeconds": { "type": "integer" },
                  "restBetweenRepsSeconds": { "type": "integer" },
                  "restBetweenSetsSeconds": { "type": "integer" }
                }
              }
            }
          }
        }
        """;

    // MARK: - Response

    /// <summary>
    /// Digs the JSON string out of the Responses envelope.
    ///
    /// <c>output_text</c> is the convenience field; the walk over
    /// <c>output</c> is the documented shape and the fallback when it is absent.
    /// </summary>
    internal static string StructuredText(string data)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(data);
        }
        catch (JsonException)
        {
            throw AIImportException.UnreadableResponse();
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw AIImportException.UnreadableResponse();

            if (root.TryGetProperty("output_text", out var outputText)
                && outputText.ValueKind == JsonValueKind.String
                && outputText.GetString() is { Length: > 0 } text)
            {
                return text;
            }

            if (!root.TryGetProperty("output", out var output)
                || output.ValueKind != JsonValueKind.Array)
            {
                throw AIImportException.UnreadableResponse();
            }
            foreach (var item in output.EnumerateArray())
            {
                if (!item.TryGetProperty("content", out var contents)
                    || contents.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }
                foreach (var content in contents.EnumerateArray())
                {
                    if (content.TryGetProperty("text", out var value)
                        && value.ValueKind == JsonValueKind.String
                        && value.GetString() is { Length: > 0 } found)
                    {
                        return found;
                    }
                }
            }
            throw AIImportException.UnreadableResponse();
        }
    }

    /// <summary>
    /// Decodes the model's payload into exercises.
    ///
    /// Decoded field by field rather than through the data file's own decoder,
    /// because the model does not send an id and must never be able to set one
    /// — identity is ours to assign.
    /// </summary>
    internal static IReadOnlyList<Exercise> Decode(string payload)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(payload);
        }
        catch (JsonException)
        {
            throw AIImportException.UnreadableResponse();
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("exercises", out var rows)
                || rows.ValueKind != JsonValueKind.Array)
            {
                throw AIImportException.UnreadableResponse();
            }

            var exercises = new List<Exercise>();
            foreach (var row in rows.EnumerateArray())
            {
                if (row.ValueKind != JsonValueKind.Object) continue;
                if (!row.TryGetProperty("name", out var name)
                    || name.ValueKind != JsonValueKind.String)
                {
                    continue;
                }
                exercises.Add(new Exercise
                {
                    Name = name.GetString() ?? "",
                    Instructions = Text(row, "instructions") ?? "",
                    Sets = Integer(row, "sets") ?? 3,
                    Reps = Integer(row, "reps") ?? 10,
                    HoldSeconds = Integer(row, "holdSeconds") ?? 0,
                    RestBetweenRepsSeconds = Integer(row, "restBetweenRepsSeconds") ?? 0,
                    RestBetweenSetsSeconds = Integer(row, "restBetweenSetsSeconds") ?? 0,
                });
            }
            return exercises;
        }
    }

    private static string? Text(JsonElement row, string name) =>
        row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    /// <summary>
    /// Accepts a number written as a JSON number or as a string — models are
    /// not always consistent, and a quoted "3" should not lose the count.
    /// </summary>
    private static int? Integer(JsonElement row, string name)
    {
        if (!row.TryGetProperty(name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetInt32(out var number) => number,
            JsonValueKind.Number when value.TryGetDouble(out var real) => (int)real,
            JsonValueKind.String when int.TryParse(value.GetString(), out var parsed) => parsed,
            _ => null,
        };
    }

    /// <summary>The human-readable half of an OpenAI error body, when there is one.</summary>
    internal static string? MessageIn(string data)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            if (document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out var error)
                && error.TryGetProperty("message", out var message)
                && message.ValueKind == JsonValueKind.String)
            {
                return message.GetString();
            }
        }
        catch (JsonException)
        {
            // A non-JSON error body (a proxy's HTML, say) has no message to
            // show; the status code stands on its own.
        }
        return null;
    }
}

/// <summary>
/// A stand-in interpreter for tests: answers instantly from the built-in
/// parser instead of reaching the network, so nothing that renders the UI can
/// make a request or need a key.
/// </summary>
public sealed class PreviewExerciseInterpreter : IExerciseInterpreter
{
    private readonly IReadOnlyList<Exercise>? _result;

    /// <param name="result">What to return; <c>null</c> parses the text locally.</param>
    public PreviewExerciseInterpreter(IReadOnlyList<Exercise>? result = null) => _result = result;

    public Task<IReadOnlyList<Exercise>> InterpretAsync(
        string text, CancellationToken cancellationToken = default) =>
        Task.FromResult(_result ?? ExerciseImporter.Parse(text));
}
