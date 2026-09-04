using System.Net;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The OpenAI path: reading a reply out of the Responses envelope, refusing to
/// trust what it contains, and telling apart the failures a person can act on.
/// </summary>
public class ExerciseInterpreterTests
{
    /// <summary>Answers every request with a canned response, or throws.</summary>
    private sealed class StubHandler : HttpMessageHandler
    {
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public string Body { get; set; } = "";
        public Exception? Failure { get; set; }
        public HttpRequestMessage? LastRequest { get; private set; }
        public string? LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            LastRequest = request;
            if (request.Content is not null)
            {
                LastBody = await request.Content.ReadAsStringAsync(cancellationToken);
            }
            if (Failure is not null) throw Failure;
            return new HttpResponseMessage(Status) { Content = new StringContent(Body) };
        }
    }

    private static (OpenAIExerciseInterpreter Interpreter, StubHandler Handler) Build(
        string body = "", HttpStatusCode status = HttpStatusCode.OK)
    {
        var handler = new StubHandler { Body = body, Status = status };
        var interpreter = new OpenAIExerciseInterpreter(
            "sk-test", AIImportModel.Default, new HttpClient(handler));
        return (interpreter, handler);
    }

    /// <summary>A Responses reply carrying <paramref name="payload"/> as its structured text.</summary>
    private static string Envelope(string payload) =>
        $$"""{"output_text": {{System.Text.Json.JsonSerializer.Serialize(payload)}}}""";

    // MARK: - The happy path

    [Fact]
    public async Task ReadsExercisesOutOfAStructuredReply()
    {
        var (interpreter, _) = Build(Envelope("""
            {"exercises": [
              {"name": "Chin tucks", "instructions": "Keep level.", "sets": 3, "reps": 10,
               "holdSeconds": 5, "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 30}
            ]}
            """));

        var exercises = await interpreter.InterpretAsync("anything");
        var exercise = Assert.Single(exercises);
        Assert.Equal("Chin tucks", exercise.Name);
        Assert.Equal("Keep level.", exercise.Instructions);
        Assert.Equal(3, exercise.Sets);
        Assert.Equal(10, exercise.Reps);
        Assert.Equal(5, exercise.HoldSeconds);
        Assert.Equal(30, exercise.RestBetweenSetsSeconds);
    }

    [Fact]
    public async Task FallsBackToWalkingTheOutputArray()
    {
        var (interpreter, _) = Build("""
            {"output": [{"content": [{"text": "{\"exercises\": [{\"name\": \"Squats\", \"sets\": 4, \"reps\": 12, \"holdSeconds\": 0, \"restBetweenRepsSeconds\": 0, \"restBetweenSetsSeconds\": 0, \"instructions\": \"\"}]}"}]}]}
            """);

        var exercise = Assert.Single(await interpreter.InterpretAsync("anything"));
        Assert.Equal("Squats", exercise.Name);
        Assert.Equal(4, exercise.Sets);
    }

    [Fact]
    public async Task TheRequestNamesTheModelAndAsksForStrictJson()
    {
        var (interpreter, handler) = Build(Envelope("""{"exercises": []}"""));
        await Assert.ThrowsAsync<AIImportException>(() => interpreter.InterpretAsync("anything"));

        Assert.Contains("\"gpt-5.6-luna\"", handler.LastBody);
        Assert.Contains("\"strict\":true", handler.LastBody);
        Assert.Contains("json_schema", handler.LastBody);
        Assert.Equal(
            "Bearer sk-test",
            handler.LastRequest?.Headers.Authorization?.ToString());
    }

    // MARK: - Never trust the model

    /// <summary>
    /// Everything the AI path returns goes through Exercise.Normalized before
    /// it reaches an editor — a 99999-second hold clamps rather than escaping.
    /// </summary>
    [Fact]
    public async Task OutOfRangeTimingsAreClampedAndUnusableRowsDropped()
    {
        var (interpreter, _) = Build(Envelope("""
            {"exercises": [
              {"name": "Plank", "instructions": "", "sets": 1, "reps": 1,
               "holdSeconds": 99999, "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 0},
              {"name": "   ", "instructions": "", "sets": 3, "reps": 10,
               "holdSeconds": 0, "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 0}
            ]}
            """));

        var exercise = Assert.Single(await interpreter.InterpretAsync("anything"));
        Assert.Equal("Plank", exercise.Name);
        Assert.Equal(Exercise.MaxHoldSeconds, exercise.HoldSeconds);
    }

    /// <summary>Identity is ours to assign; the model never sends one.</summary>
    [Fact]
    public async Task EveryRowGetsAFreshIdentity()
    {
        var (interpreter, _) = Build(Envelope("""
            {"exercises": [
              {"name": "A", "instructions": "", "sets": 1, "reps": 1, "holdSeconds": 0,
               "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 0},
              {"name": "B", "instructions": "", "sets": 1, "reps": 1, "holdSeconds": 0,
               "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 0}
            ]}
            """));

        var exercises = await interpreter.InterpretAsync("anything");
        Assert.NotEqual(exercises[0].Id, exercises[1].Id);
        Assert.All(exercises, exercise => Assert.NotEqual(Guid.Empty, exercise.Id));
    }

    /// <summary>A quoted "3" should not lose the count.</summary>
    [Fact]
    public async Task CountsWrittenAsStringsAreStillRead()
    {
        var (interpreter, _) = Build(Envelope("""
            {"exercises": [
              {"name": "Squats", "instructions": "", "sets": "4", "reps": "12",
               "holdSeconds": "6", "restBetweenRepsSeconds": 0, "restBetweenSetsSeconds": 0}
            ]}
            """));

        var exercise = Assert.Single(await interpreter.InterpretAsync("anything"));
        Assert.Equal(4, exercise.Sets);
        Assert.Equal(12, exercise.Reps);
        Assert.Equal(6, exercise.HoldSeconds);
    }

    [Fact]
    public async Task AnEmptyResultIsReportedAsNothingFound()
    {
        var (interpreter, _) = Build(Envelope("""{"exercises": []}"""));
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.NothingFound, exception.FailureReason);
    }

    // MARK: - Failures a person can act on

    [Fact]
    public async Task EmptyTextIsRefusedBeforeAnyRequest()
    {
        var (interpreter, handler) = Build();
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("   \n "));
        Assert.Equal(AIImportException.Reason.NothingFound, exception.FailureReason);
        Assert.Null(handler.LastRequest);
    }

    [Fact]
    public async Task AnEmptyKeyIsRefusedBeforeAnyRequest()
    {
        var handler = new StubHandler();
        var interpreter = new OpenAIExerciseInterpreter(
            "", AIImportModel.Default, new HttpClient(handler));
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.MissingKey, exception.FailureReason);
        Assert.Null(handler.LastRequest);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, AIImportException.Reason.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden, AIImportException.Reason.Unauthorized)]
    [InlineData(HttpStatusCode.TooManyRequests, AIImportException.Reason.RateLimited)]
    [InlineData(HttpStatusCode.InternalServerError, AIImportException.Reason.Server)]
    public async Task StatusCodesMapToTheReasonTheyMean(
        HttpStatusCode status, AIImportException.Reason expected)
    {
        var (interpreter, _) = Build("{}", status);
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(expected, exception.FailureReason);
    }

    [Fact]
    public async Task AServerErrorShowsOpenAIsOwnMessage()
    {
        var (interpreter, _) = Build(
            """{"error": {"message": "That model is retired."}}""",
            HttpStatusCode.BadRequest);
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal("That model is retired.", exception.Message);
    }

    [Fact]
    public async Task ANetworkFailureIsOffline()
    {
        var (interpreter, handler) = Build();
        handler.Failure = new HttpRequestException("no route");
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.Offline, exception.FailureReason);
    }

    /// <summary>
    /// A slow answer is not a missing network. Conflating the two sent people
    /// to debug a connection that was working.
    /// </summary>
    [Fact]
    public async Task ASlowAnswerIsTimedOutRatherThanOffline()
    {
        var (interpreter, handler) = Build();
        handler.Failure = new TaskCanceledException("timed out");
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.TimedOut, exception.FailureReason);
    }

    [Fact]
    public async Task AReplyThatIsNotJsonIsUnreadableRatherThanACrash()
    {
        var (interpreter, _) = Build("<html>gateway</html>");
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.UnreadableResponse, exception.FailureReason);
    }

    [Fact]
    public async Task AReplyWithNoStructuredTextIsUnreadable()
    {
        var (interpreter, _) = Build("""{"output": []}""");
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => interpreter.InterpretAsync("anything"));
        Assert.Equal(AIImportException.Reason.UnreadableResponse, exception.FailureReason);
    }

    // MARK: - The model list

    [Fact]
    public void TheDefaultModelMatchesTheMac()
    {
        Assert.Equal("gpt-5.6-luna", AIImportModel.Default.Id);
        Assert.Equal(
            ["gpt-5-nano", "gpt-5.6-luna", "gpt-5-mini"],
            AIImportModel.All.Select(model => model.Id).ToArray());
    }

    [Fact]
    public void AnUnknownOrMissingModelFallsBackToTheDefault()
    {
        Assert.Equal(AIImportModel.Default, AIImportModel.Resolve(null));
        Assert.Equal(AIImportModel.Default, AIImportModel.Resolve("gpt-4-retired"));
        Assert.Equal(AIImportModel.Mini, AIImportModel.Resolve("gpt-5-mini"));
    }
}
