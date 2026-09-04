using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The API key's life in the secret store, and the guarantee that nothing
/// reaches OpenAI without one. (Mirrors AIImportControllerTests on iOS.)
/// </summary>
public class AIImportControllerTests
{
    /// <summary>
    /// Records what it was asked to interpret, so a test can prove a request
    /// was — or was not — made.
    /// </summary>
    private sealed class RecordingInterpreter : IExerciseInterpreter
    {
        public List<string> Requests { get; } = [];
        public string? KeyUsed { get; set; }
        public AIImportModel? ModelUsed { get; set; }
        public Exception? Failure { get; set; }

        public Task<IReadOnlyList<Exercise>> InterpretAsync(
            string text, CancellationToken cancellationToken = default)
        {
            Requests.Add(text);
            if (Failure is not null) throw Failure;
            return Task.FromResult(ExerciseImporter.Parse(text));
        }
    }

    private static (AIImportController Controller, RecordingInterpreter Interpreter,
        InMemorySecretStore Secrets) Build(string? initialKey = null)
    {
        var secrets = new InMemorySecretStore();
        if (initialKey is not null) secrets.Write(initialKey, SecretAccounts.AIImportKey);
        var interpreter = new RecordingInterpreter();
        var controller = new AIImportController(secrets, (key, model) =>
        {
            interpreter.KeyUsed = key;
            interpreter.ModelUsed = model;
            return interpreter;
        });
        return (controller, interpreter, secrets);
    }

    // MARK: - The key

    [Fact]
    public void StartsUnconfiguredWithNoKey()
    {
        var (controller, _, _) = Build();
        Assert.False(controller.IsConfigured);
    }

    [Fact]
    public void StartsConfiguredWhenAKeyIsAlreadyStored()
    {
        var (controller, _, _) = Build("sk-existing");
        Assert.True(controller.IsConfigured);
    }

    [Fact]
    public void StoringAKeyConfiguresTheController()
    {
        var (controller, _, secrets) = Build();
        Assert.Null(controller.Store("sk-test"));
        Assert.True(controller.IsConfigured);
        Assert.Equal("sk-test", secrets.Read(SecretAccounts.AIImportKey));
    }

    [Fact]
    public void StoringABlankKeyRemovesIt()
    {
        var (controller, _, secrets) = Build("sk-existing");
        controller.Store("   ");
        Assert.False(controller.IsConfigured);
        Assert.Null(secrets.Read(SecretAccounts.AIImportKey));
    }

    [Fact]
    public void StoringNullRemovesTheKey()
    {
        var (controller, _, secrets) = Build("sk-existing");
        controller.Store(null);
        Assert.False(controller.IsConfigured);
        Assert.Null(secrets.Read(SecretAccounts.AIImportKey));
    }

    [Fact]
    public void SurroundingWhitespaceIsTrimmedOffAPastedKey()
    {
        var (controller, _, secrets) = Build();
        controller.Store("  sk-pasted\n");
        Assert.Equal("sk-pasted", secrets.Read(SecretAccounts.AIImportKey));
    }

    // MARK: - Using it

    [Fact]
    public async Task InterpretingWithoutAKeyMakesNoRequest()
    {
        var (controller, interpreter, _) = Build();
        var exception = await Assert.ThrowsAsync<AIImportException>(
            () => controller.InterpretAsync("3 sets of 10 squats"));
        Assert.Equal(AIImportException.Reason.MissingKey, exception.FailureReason);
        Assert.Empty(interpreter.Requests);
    }

    [Fact]
    public async Task InterpretingPassesTheStoredKeyAndChosenModel()
    {
        var (controller, interpreter, _) = Build("sk-test");
        controller.Model = AIImportModel.Mini;
        var exercises = await controller.InterpretAsync("Chin tucks 3 x 10, hold 5 seconds");

        Assert.Equal("sk-test", interpreter.KeyUsed);
        Assert.Equal(AIImportModel.Mini, interpreter.ModelUsed);
        Assert.Single(interpreter.Requests);
        Assert.Equal("Chin tucks", exercises[0].Name);
    }

    [Fact]
    public async Task ATestKeyRunReportsSuccess()
    {
        var (controller, _, _) = Build("sk-test");
        await controller.TestKeyAsync();
        Assert.True(controller.LastTestResult?.Succeeded);
        Assert.False(controller.IsTesting);
    }

    /// <summary>
    /// The key and the model worked; the model just found nothing in a
    /// deliberately trivial phrase. That is still a pass.
    /// </summary>
    [Fact]
    public async Task NothingFoundStillCountsAsAWorkingKey()
    {
        var (controller, interpreter, _) = Build("sk-test");
        interpreter.Failure = AIImportException.NothingFound();
        await controller.TestKeyAsync();
        Assert.True(controller.LastTestResult?.Succeeded);
    }

    [Fact]
    public async Task ARejectedKeyIsReportedWithItsMessage()
    {
        var (controller, interpreter, _) = Build("sk-bad");
        interpreter.Failure = AIImportException.Unauthorized();
        await controller.TestKeyAsync();
        Assert.False(controller.LastTestResult?.Succeeded);
        Assert.Equal(
            "That API key was rejected. Check it in Settings.",
            controller.LastTestResult?.Message);
    }

    [Fact]
    public void StoringANewKeyClearsTheLastTestResult()
    {
        var (controller, _, _) = Build("sk-test");
        controller.Store("sk-other");
        Assert.Null(controller.LastTestResult);
    }
}
