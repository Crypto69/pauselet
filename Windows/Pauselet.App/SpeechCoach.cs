using System.Speech.Synthesis;
using System.Windows;

namespace Pauselet.App;

/// <summary>
/// What the exercise coach needs from a voice: say this now, or be quiet.
/// An interface so the coach can be driven without a synthesizer in tests.
/// (Mirrors SpeechCoaching in SpeechCoach.swift.)
/// </summary>
internal interface ISpeechCoaching
{
    /// <summary>
    /// Interrupts whatever is being said and says <paramref name="text"/>.
    /// <paramref name="onFinish"/> runs when the whole line has been said —
    /// not when it is cut off by <see cref="Stop"/> or by the next
    /// <see cref="Speak"/>, since whoever cut it off has moved on.
    /// </summary>
    void Speak(string text, Action? onFinish = null);

    void Stop();
}

/// <summary>
/// The one speech synthesizer in the app, so cues are spoken once however
/// many displays show the takeover, and the Preferences Test button uses the
/// same voice path the coach does.
///
/// System.Speech rather than the WinRT synthesizer: it speaks straight to the
/// default output device with no media-player plumbing, which is all a spoken
/// cue needs, and it enumerates the same SAPI voices the Windows speech
/// settings install.
/// </summary>
internal sealed class SpeechCoach : ISpeechCoaching, IDisposable
{
    /// <summary>True while an utterance is in progress; the Test button shows it.</summary>
    public bool IsSpeaking { get; private set; }

    /// <summary>Raised on the UI thread when <see cref="IsSpeaking"/> changes.</summary>
    public event Action? SpeakingChanged;

    /// <summary>
    /// The stored preference. Resolved through <see cref="VoiceCatalog"/> on
    /// every utterance, so a voice the user later uninstalls degrades to the
    /// best available one rather than to silence.
    /// </summary>
    public string? VoiceIdentifier { get; set; }

    /// <summary>Settings.VoiceCoachRate: percent of normal, 50 = the platform default.</summary>
    public int Rate { get; set; } = 45;

    private readonly SpeechSynthesizer _synthesizer = new();
    /// <summary>
    /// The completion for the utterance in flight, keyed by the prompt so a
    /// stale completion for an interrupted line cannot fire it.
    /// </summary>
    private Prompt? _pendingPrompt;
    private Action? _pendingFinish;
    private bool _disposed;

    public SpeechCoach()
    {
        _synthesizer.SetOutputToDefaultAudioDevice();
        _synthesizer.SpeakStarted += (_, _) => SetSpeaking(true);
        _synthesizer.SpeakCompleted += OnSpeakCompleted;
    }

    public void Speak(string text, Action? onFinish = null) =>
        Speak(text, VoiceIdentifier, Rate, onFinish);

    /// <summary>
    /// Speaks with a specific voice and pace — the Test button, previewing the
    /// picker's current choice before it is saved.
    /// </summary>
    public void Speak(string text, string? voiceIdentifier, int rate, Action? onFinish = null)
    {
        if (_disposed) return;
        Stop();
        if (VoiceCatalog.Resolve(voiceIdentifier) is { } voiceName)
        {
            try
            {
                _synthesizer.SelectVoice(voiceName);
            }
            catch (ArgumentException)
            {
                // The voice went away between enumeration and now; the
                // synthesizer keeps whichever one it already had.
            }
        }
        _synthesizer.Rate = UtteranceRate(rate);
        var prompt = new Prompt(text);
        _pendingPrompt = prompt;
        _pendingFinish = onFinish;
        _synthesizer.SpeakAsync(prompt);
    }

    public void Stop()
    {
        if (_disposed) return;
        _pendingPrompt = null;
        _pendingFinish = null;
        _synthesizer.SpeakAsyncCancelAll();
        SetSpeaking(false);
    }

    /// <summary>
    /// The settings slider is percent of normal, 50 being the default;
    /// System.Speech's Rate is -10…10 around its own default of 0. The ends
    /// are clamped well inside the range, where speech is still speech rather
    /// than a drawl or a blur.
    /// </summary>
    public static int UtteranceRate(int percent)
    {
        var clamped = Math.Clamp(percent, 20, 80);
        // 20 % → -6, 50 % → 0, 80 % → +6.
        return (int)Math.Round((clamped - 50) / 5.0);
    }

    private void OnSpeakCompleted(object? sender, SpeakCompletedEventArgs e)
    {
        // System.Speech raises this on a worker thread, and the completion
        // releases the coach's announcement — which walks the session and the
        // overlay. Both belong to the UI thread, so the whole handler is
        // marshalled rather than just the flag; that also keeps the pending
        // prompt's bookkeeping single-threaded.
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => OnSpeakCompleted(sender, e));
            return;
        }

        SetSpeaking(false);
        // A stale completion for a prompt that has since been superseded must
        // not release the announcement of the phase that replaced it.
        if (_pendingPrompt is null || !ReferenceEquals(_pendingPrompt, e.Prompt)) return;
        var finish = _pendingFinish;
        _pendingPrompt = null;
        _pendingFinish = null;
        // Cancelled prompts also complete; only a line that was actually said
        // through releases the coach's announcement.
        if (!e.Cancelled) finish?.Invoke();
    }

    /// <summary>
    /// Synthesizer events arrive on a worker thread; the coach and the Test
    /// button both touch WPF state, so hop to the UI thread.
    /// </summary>
    private void SetSpeaking(bool value)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is not null && !dispatcher.CheckAccess())
        {
            dispatcher.BeginInvoke(() => SetSpeaking(value));
            return;
        }
        if (IsSpeaking == value) return;
        IsSpeaking = value;
        SpeakingChanged?.Invoke();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _synthesizer.SpeakAsyncCancelAll();
        _synthesizer.Dispose();
    }
}

/// <summary>
/// The system voices worth offering, best first. (Mirrors VoiceCatalog in
/// SpeechCoach.swift; SAPI has no quality tier, so the ordering is by region
/// then name.)
/// </summary>
internal static class VoiceCatalog
{
    /// <param name="Id">The SAPI voice name, the value stored in settings.</param>
    /// <param name="Name">The voice's own name, e.g. "Microsoft Zira Desktop".</param>
    /// <param name="Language">BCP-47, e.g. "en-AU".</param>
    internal sealed record Voice(string Id, string Name, string Language)
    {
        /// <summary>"Zira — English (United States)".</summary>
        public string Label
        {
            get
            {
                string languageName;
                try
                {
                    languageName = new System.Globalization.CultureInfo(Language).DisplayName;
                }
                catch (System.Globalization.CultureNotFoundException)
                {
                    languageName = Language;
                }
                // SAPI names are "Microsoft Zira Desktop"; the middle word is
                // the only part that identifies the voice to a person.
                var bare = Name
                    .Replace("Microsoft ", "")
                    .Replace(" Desktop", "");
                return $"{bare} — {languageName}";
            }
        }
    }

    /// <summary>
    /// Enumerating voices constructs a synthesizer and walks the SAPI
    /// registry, which is far too slow to do per spoken cue. The list only
    /// changes when the user installs a voice in Windows' settings, so it is
    /// read once per app run.
    /// </summary>
    private static IReadOnlyList<Voice>? _cached;

    /// <summary>
    /// Installed English voices — the cues are English, so a voice in another
    /// language would mangle them — ordered so the first is the one to use by
    /// default: the user's own region first, then by name.
    /// </summary>
    public static IReadOnlyList<Voice> InstalledVoices() => _cached ??= Enumerate();

    private static IReadOnlyList<Voice> Enumerate()
    {
        using var synthesizer = new SpeechSynthesizer();
        List<Voice> english;
        try
        {
            english = synthesizer.GetInstalledVoices()
                .Where(voice => voice.Enabled)
                .Select(voice => voice.VoiceInfo)
                .Where(info => IsEnglish(info.Culture.Name))
                .Select(info => new Voice(info.Name, info.Name, info.Culture.Name))
                .ToList();
        }
        catch (PlatformNotSupportedException)
        {
            return [];
        }
        return english
            .OrderByDescending(IsHomeRegion)
            .ThenBy(voice => voice.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    public static Voice? DefaultVoice() => InstalledVoices().FirstOrDefault();

    /// <summary>
    /// The voice to speak with: the stored one if it is still installed,
    /// otherwise the best available. <c>null</c> when there are no English
    /// voices at all, which leaves the synthesizer on its own default.
    /// </summary>
    public static string? Resolve(string? identifier)
    {
        var installed = InstalledVoices();
        if (identifier is { Length: > 0 }
            && installed.Any(voice => voice.Id == identifier))
        {
            return identifier;
        }
        return installed.FirstOrDefault()?.Id;
    }

    private static bool IsEnglish(string culture) =>
        culture.StartsWith("en", StringComparison.OrdinalIgnoreCase);

    private static bool IsHomeRegion(Voice voice)
    {
        var region = System.Globalization.RegionInfo.CurrentRegion.TwoLetterISORegionName;
        var parts = voice.Language.Split('-');
        return parts.Length > 1
            && string.Equals(parts[^1], region, StringComparison.OrdinalIgnoreCase);
    }
}
