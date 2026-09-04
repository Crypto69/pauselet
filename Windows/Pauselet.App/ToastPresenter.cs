using Microsoft.Toolkit.Uwp.Notifications;
using Pauselet.Core;
using Windows.UI.Notifications;

namespace Pauselet.App;

/// <summary>
/// Posts toast notifications for the Normal and Important tiers, and routes
/// the buttons the user taps back to the engine.
///
/// The two extreme tiers (Subtle, Critical) bypass this entirely and use the
/// app's own windows, because system notifications cannot be made either quiet
/// enough or insistent enough for those cases.
///
/// The fallback ladder is the part that must survive from the Mac version: a
/// reminder is never allowed to drop silently. Windows has the same failure
/// modes with different names — notifications disabled for the app, Do Not
/// Disturb swallowing a toast into the notification centre, API errors — so
/// the same availability tracking and in-app fallback card apply. Unlike
/// macOS there is no authorization prompt to wait on, so availability starts
/// from the actual per-app setting rather than "unknown".
/// </summary>
internal sealed class ToastPresenter
{
    public ReminderEngine? Engine { get; set; }

    /// <summary>
    /// Called when a toast cannot be delivered, so the caller can show the
    /// reminder some other way rather than dropping it silently.
    /// </summary>
    public Action<Reminder, Core.Settings>? FallbackPresenter { get; set; }

    private enum Availability
    {
        Unknown,
        Available,
        Unavailable,
    }

    private Availability _availability = Availability.Unknown;

    private const string ReminderIdKey = "reminderID";
    private const string ActionKey = "action";

    public void Configure()
    {
        ToastNotificationManagerCompat.OnActivated += OnActivated;
        RefreshAvailability();
    }

    /// <summary>
    /// Re-reads whether the system will currently show toasts for this app.
    /// Notifications can be off per-app or globally; a reminder app that
    /// silently drops reminders is worse than useless, so this decides between
    /// the toast path and the in-app card.
    /// </summary>
    public void RefreshAvailability()
    {
        try
        {
            var setting = ToastNotificationManagerCompat.CreateToastNotifier().Setting;
            _availability = setting == NotificationSetting.Enabled
                ? Availability.Available
                : Availability.Unavailable;
        }
        catch
        {
            _availability = Availability.Unavailable;
        }
    }

    /// <summary>
    /// Posts a toast for <paramref name="reminder"/>. Delivered immediately —
    /// the resident tick loop is the scheduler, so no toast is ever scheduled
    /// for the future.
    /// </summary>
    public void Post(Reminder reminder, Core.Settings settings)
    {
        if (_availability == Availability.Unavailable)
        {
            FallbackPresenter?.Invoke(reminder, settings);
            // Re-check so a user who re-enables notifications later gets
            // toasts back without relaunching — the only path out of the
            // fallback state.
            RefreshAvailability();
            return;
        }

        try
        {
            var builder = new ToastContentBuilder()
                .AddArgument(ReminderIdKey, reminder.Id.ToString())
                .AddArgument(ActionKey, "complete")
                .AddText(reminder.Title);
            if (reminder.Message.Length > 0)
            {
                builder.AddText(reminder.Message);
            }
            builder.AddButton(new ToastButton()
                .SetContent("Done")
                .AddArgument(ReminderIdKey, reminder.Id.ToString())
                .AddArgument(ActionKey, "complete")
                .SetBackgroundActivation());
            builder.AddButton(new ToastButton()
                .SetContent("Snooze")
                .AddArgument(ReminderIdKey, reminder.Id.ToString())
                .AddArgument(ActionKey, "snooze")
                .SetBackgroundActivation());

            if (reminder.Priority >= Priority.Important)
            {
                // Stays on screen until dismissed — the analogue of the Mac
                // app's time-sensitive interruption level.
                builder.SetToastScenario(ToastScenario.Reminder);
            }

            // Toast audio is limited to a small stock set, so all sound is
            // played out-of-band below — exactly as the Mac app already does
            // for its system sounds. The toast itself stays silent.
            builder.AddAudio(new ToastAudio { Silent = true });

            builder.Show(toast =>
            {
                toast.Dismissed += (_, dismissArgs) =>
                {
                    if (dismissArgs.Reason != ToastDismissalReason.UserCanceled) return;
                    RunOnDispatcher(() => Engine?.Dismiss(reminder.Id));
                };
            });

            // Only the important tier makes noise; normal stays silent so a
            // busy reminder set does not become a stream of chimes.
            if (settings.PlaysSound(reminder.Priority))
            {
                Sounds.Play(reminder.SoundName ?? "Ping");
            }
        }
        catch
        {
            // Delivery failed; show it ourselves rather than losing it.
            _availability = Availability.Unavailable;
            FallbackPresenter?.Invoke(reminder, settings);
        }
    }

    private void OnActivated(ToastNotificationActivatedEventArgsCompat args)
    {
        ToastArguments parsed;
        try
        {
            parsed = ToastArguments.Parse(args.Argument);
        }
        catch
        {
            return;
        }
        if (!parsed.TryGetValue(ReminderIdKey, out var rawId)
            || !Guid.TryParse(rawId, out var id))
        {
            return;
        }
        var action = parsed.TryGetValue(ActionKey, out var value) ? value : "complete";

        RunOnDispatcher(() =>
        {
            switch (action)
            {
                case "complete":
                    Engine?.Complete(id);
                    break;
                case "snooze":
                    Engine?.Snooze(id);
                    break;
            }
        });
    }

    /// <summary>
    /// Toast activation arrives on a background thread; the engine lives on
    /// the dispatcher thread, same as the Mac engine lives on the main actor.
    /// </summary>
    private static void RunOnDispatcher(Action action)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null)
        {
            return;
        }
        dispatcher.BeginInvoke(action);
    }
}
