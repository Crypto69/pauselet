namespace Pauselet.Core;

/// <summary>
/// Owns the API key and the state of any request in flight, so the settings
/// section and the import dialog share one view of whether AI import is
/// available. (Mirrors AIImportController.swift.)
///
/// The key is read from the secret store on demand rather than held as a
/// property: nothing in the UI ever needs its value — only whether one exists
/// — and a secret held in a field is a secret that ends up in a crash dump.
/// </summary>
public sealed class AIImportController
{
    /// <summary>What a "Test key" attempt came back with.</summary>
    public sealed record TestResult(bool Succeeded, string? Message)
    {
        public static readonly TestResult Success = new(true, null);
        public static TestResult Failure(string message) => new(false, message);
    }

    /// <summary>
    /// True when a key is stored, so callers can show or hide the AI path
    /// without reading the key itself.
    /// </summary>
    public bool IsConfigured { get; private set; }

    /// <summary>The result of the last <see cref="TestKeyAsync"/>, cleared when the key changes.</summary>
    public TestResult? LastTestResult { get; private set; }

    public bool IsTesting { get; private set; }

    /// <summary>The model chosen in settings, set by whoever has them to hand.</summary>
    public AIImportModel Model { get; set; } = AIImportModel.Default;

    private readonly ISecretStore _secrets;
    private readonly Func<string, AIImportModel, IExerciseInterpreter> _makeInterpreter;

    /// <param name="makeInterpreter">
    /// Injected so tests can supply a stub instead of reaching OpenAI.
    /// </param>
    public AIImportController(
        ISecretStore? secrets = null,
        Func<string, AIImportModel, IExerciseInterpreter>? makeInterpreter = null)
    {
        _secrets = secrets ?? new DpapiSecretStore();
        _makeInterpreter = makeInterpreter
            ?? ((key, model) => new OpenAIExerciseInterpreter(key, model));
        Refresh();
    }

    // MARK: - The key

    public void Refresh() => IsConfigured = ReadKey() is { Length: > 0 };

    /// <summary>
    /// Stores a key, or removes it when <paramref name="key"/> is null or
    /// blank.
    ///
    /// Returns the error to show, or <c>null</c> on success — a store that
    /// cannot be written to is worth telling the user about rather than
    /// silently losing what they typed.
    /// </summary>
    public string? Store(string? key)
    {
        LastTestResult = null;
        try
        {
            _secrets.Write(key?.Trim(), SecretAccounts.AIImportKey);
            Refresh();
            return null;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException
                or System.Security.Cryptography.CryptographicException
                or PlatformNotSupportedException)
        {
            return $"Could not save the key ({exception.Message}).";
        }
    }

    // MARK: - Using it

    public async Task<IReadOnlyList<Exercise>> InterpretAsync(
        string text, CancellationToken cancellationToken = default)
    {
        if (ReadKey() is not { Length: > 0 } key) throw AIImportException.MissingKey();
        return await _makeInterpreter(key, Model)
            .InterpretAsync(text, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Proves the whole path works — key, model, network — on a scrap of text,
    /// so a bad key is discovered in Settings rather than mid-import.
    /// </summary>
    public async Task TestKeyAsync(CancellationToken cancellationToken = default)
    {
        if (IsTesting) return;
        IsTesting = true;
        LastTestResult = null;
        try
        {
            await InterpretAsync(TestPhrase, cancellationToken).ConfigureAwait(false);
            LastTestResult = TestResult.Success;
        }
        catch (AIImportException exception)
            when (exception.FailureReason == AIImportException.Reason.NothingFound)
        {
            // The key and the model worked; the model just found nothing in a
            // deliberately trivial phrase. That is still a pass.
            LastTestResult = TestResult.Success;
        }
        catch (AIImportException exception)
        {
            LastTestResult = TestResult.Failure(exception.Message);
        }
        finally
        {
            IsTesting = false;
        }
    }

    private string? ReadKey()
    {
        try
        {
            return _secrets.Read(SecretAccounts.AIImportKey);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException
                or System.Security.Cryptography.CryptographicException
                or PlatformNotSupportedException)
        {
            return null;
        }
    }

    private const string TestPhrase = "3 sets of 10 squats";
}
