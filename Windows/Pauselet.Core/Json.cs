using System.Globalization;
using System.Text;
using System.Text.Json;
using NodaTime;

namespace Pauselet.Core;

public static class InstantExtensions
{
    /// <summary>
    /// The instant rounded to a whole second, matching the on-disk precision.
    /// Mirrors Swift's <c>rounded()</c>: half-seconds round away from zero.
    /// </summary>
    public static Instant RoundedToSecond(this Instant instant)
    {
        var seconds = Math.Round(
            instant.ToUnixTimeTicks() / (double)NodaConstants.TicksPerSecond,
            MidpointRounding.AwayFromZero
        );
        return Instant.FromUnixTimeSeconds((long)seconds);
    }
}

/// <summary>
/// Encodes and decodes <c>AppData</c> in exactly the JSON dialect the Mac
/// app's Swift encoder produces, so one data file can be copied between a Mac
/// and a PC in either direction.
///
/// The Swift side is <c>JSONEncoder</c> with <c>.prettyPrinted</c> +
/// <c>.sortedKeys</c> and a custom whole-seconds date strategy
/// (<c>Store.swift</c>). Its output shape — verified against real encoder
/// output captured in the golden fixtures — is:
///
/// - two-space indentation, with a space on *both* sides of the colon
///   (<c>"key" : value</c>);
/// - object keys sorted by ordinal comparison;
/// - empty objects/arrays as an open bracket, a truly empty line, and the
///   closing bracket at the parent indent;
/// - dates as whole seconds since 1970, written as bare integers;
/// - forward slashes escaped (<c>\/</c>), non-ASCII written raw as UTF-8;
/// - UUIDs uppercase;
/// - Swift enums with associated values as single-key objects
///   (<c>{"interval":{"minutes":60}}</c>), payload-free cases as empty
///   objects (<c>{"none":{}}</c>);
/// - an optional <c>exercises</c> array of
///   <c>{id, instructions, name, reps, sets}</c> objects on a reminder,
///   present only when the Mac optional is non-nil;
/// - no trailing newline.
///
/// The one deliberate deviation: Swift encodes <c>Set</c> values (weekly
/// weekdays) in hash order, which is randomized per process. This encoder
/// always writes weekdays sorted ascending — a canonical form the Mac app
/// decodes identically.
///
/// Decoding is tolerant exactly where the Swift decoder is tolerant (fields
/// added after 1.0 fall back to their defaults; unknown keys are ignored) and
/// strict where it is strict (a missing required field throws, so the engine's
/// corrupt-file fallback path engages rather than half-loading a file).
/// </summary>
public static class AppDataJson
{
    // MARK: - Value tree

    private abstract class JVal
    {
        public sealed class Obj : JVal
        {
            public readonly SortedDictionary<string, JVal> Members =
                new(StringComparer.Ordinal);
        }

        public sealed class Arr : JVal
        {
            public readonly List<JVal> Items = [];
        }

        public sealed class Str(string value) : JVal
        {
            public readonly string Value = value;
        }

        public sealed class Num(long value) : JVal
        {
            public readonly long Value = value;
        }

        public sealed class Bool(bool value) : JVal
        {
            public readonly bool Value = value;
        }
    }

    // MARK: - Encoding

    public static byte[] Encode(AppData data)
    {
        var root = new JVal.Obj();
        root.Members["schemaVersion"] = new JVal.Num(data.SchemaVersion);

        var reminders = new JVal.Arr();
        foreach (var reminder in data.Reminders) reminders.Items.Add(EncodeReminder(reminder));
        root.Members["reminders"] = reminders;

        root.Members["settings"] = EncodeSettings(data.Settings);

        var events = new JVal.Arr();
        foreach (var e in data.Events) events.Items.Add(EncodeEvent(e));
        root.Members["events"] = events;

        var builder = new StringBuilder();
        WriteValue(builder, root, 0);
        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    private static JVal EncodeReminder(Reminder reminder)
    {
        var obj = new JVal.Obj();
        obj.Members["id"] = EncodeUuid(reminder.Id);
        obj.Members["title"] = new JVal.Str(reminder.Title);
        obj.Members["message"] = new JVal.Str(reminder.Message);
        obj.Members["schedule"] = EncodeSchedule(reminder.Schedule);
        obj.Members["priority"] = new JVal.Str(PriorityRaw(reminder.Priority));
        obj.Members["isEnabled"] = new JVal.Bool(reminder.IsEnabled);
        obj.Members["symbolName"] = new JVal.Str(reminder.SymbolName);
        if (reminder.ActivityDurationSeconds is { } duration)
        {
            obj.Members["activityDurationSeconds"] = new JVal.Num(duration);
        }
        if (reminder.SoundName is { } sound)
        {
            obj.Members["soundName"] = new JVal.Str(sound);
        }
        if (reminder.DisplaySeconds is { } display)
        {
            obj.Members["displaySeconds"] = new JVal.Num(display);
        }
        obj.Members["music"] = EncodeMusic(reminder.Music);
        // Present whenever the Swift optional is non-nil — including empty —
        // so a Mac file re-encodes byte-identically. Empty lists are kept off
        // disk by Exercise.Normalized in the editor, not here.
        if (reminder.Exercises is { } exercises)
        {
            var array = new JVal.Arr();
            foreach (var exercise in exercises) array.Items.Add(EncodeExercise(exercise));
            obj.Members["exercises"] = array;
        }
        if (reminder.LastFiredAt is { } fired)
        {
            obj.Members["lastFiredAt"] = EncodeDate(fired);
        }
        if (reminder.LastAcknowledgedAt is { } acked)
        {
            obj.Members["lastAcknowledgedAt"] = EncodeDate(acked);
        }
        if (reminder.SnoozedUntil is { } snoozed)
        {
            obj.Members["snoozedUntil"] = EncodeDate(snoozed);
        }
        obj.Members["createdAt"] = EncodeDate(reminder.CreatedAt);
        return obj;
    }

    private static JVal EncodeSchedule(Schedule schedule)
    {
        var payload = new JVal.Obj();
        var wrapper = new JVal.Obj();
        switch (schedule)
        {
            case Schedule.Interval interval:
                payload.Members["minutes"] = new JVal.Num(interval.Minutes);
                wrapper.Members["interval"] = payload;
                break;
            case Schedule.DailyAt daily:
                payload.Members["hour"] = new JVal.Num(daily.Hour);
                payload.Members["minute"] = new JVal.Num(daily.Minute);
                payload.Members["dayInterval"] = new JVal.Num(daily.DayInterval);
                wrapper.Members["dailyAt"] = payload;
                break;
            case Schedule.WeeklyAt weekly:
                payload.Members["hour"] = new JVal.Num(weekly.Hour);
                payload.Members["minute"] = new JVal.Num(weekly.Minute);
                var weekdays = new JVal.Arr();
                foreach (var day in weekly.Weekdays.OrderBy(d => d))
                {
                    weekdays.Items.Add(new JVal.Num(day));
                }
                payload.Members["weekdays"] = weekdays;
                wrapper.Members["weeklyAt"] = payload;
                break;
            default:
                throw new InvalidOperationException();
        }
        return wrapper;
    }

    private static JVal EncodeMusic(MusicChoice music)
    {
        var payload = new JVal.Obj();
        var wrapper = new JVal.Obj();
        switch (music)
        {
            case MusicChoice.NoneChoice:
                wrapper.Members["none"] = payload;
                break;
            case MusicChoice.DefaultPlaylistChoice:
                wrapper.Members["defaultPlaylist"] = payload;
                break;
            case MusicChoice.PlaylistChoice playlist:
                payload.Members["uri"] = new JVal.Str(playlist.Uri);
                wrapper.Members["playlist"] = payload;
                break;
            default:
                throw new InvalidOperationException();
        }
        return wrapper;
    }

    private static JVal EncodeExercise(Exercise exercise)
    {
        var obj = new JVal.Obj();
        obj.Members["id"] = EncodeUuid(exercise.Id);
        obj.Members["name"] = new JVal.Str(exercise.Name);
        obj.Members["instructions"] = new JVal.Str(exercise.Instructions);
        obj.Members["sets"] = new JVal.Num(exercise.Sets);
        obj.Members["reps"] = new JVal.Num(exercise.Reps);
        return obj;
    }

    private static JVal EncodeSettings(Settings settings)
    {
        var quiet = new JVal.Obj();
        quiet.Members["isEnabled"] = new JVal.Bool(settings.QuietHours.IsEnabled);
        quiet.Members["startHour"] = new JVal.Num(settings.QuietHours.StartHour);
        quiet.Members["startMinute"] = new JVal.Num(settings.QuietHours.StartMinute);
        quiet.Members["endHour"] = new JVal.Num(settings.QuietHours.EndHour);
        quiet.Members["endMinute"] = new JVal.Num(settings.QuietHours.EndMinute);
        quiet.Members["allowsCritical"] = new JVal.Bool(settings.QuietHours.AllowsCritical);

        var obj = new JVal.Obj();
        obj.Members["quietHours"] = quiet;
        obj.Members["isPaused"] = new JVal.Bool(settings.IsPaused);
        if (settings.PausedUntil is { } pausedUntil)
        {
            obj.Members["pausedUntil"] = EncodeDate(pausedUntil);
        }
        obj.Members["snoozeMinutes"] = new JVal.Num(settings.SnoozeMinutes);
        obj.Members["subtleDisplaySeconds"] = new JVal.Num(settings.SubtleDisplaySeconds);
        obj.Members["launchAtLogin"] = new JVal.Bool(settings.LaunchAtLogin);
        obj.Members["showsNextReminderInMenuBar"] =
            new JVal.Bool(settings.ShowsNextReminderInMenuBar);
        obj.Members["soundEnabled"] = new JVal.Bool(settings.SoundEnabled);
        if (settings.DefaultPlaylistUri is { } uri)
        {
            obj.Members["defaultPlaylistURI"] = new JVal.Str(uri);
        }
        obj.Members["musicEnabled"] = new JVal.Bool(settings.MusicEnabled);
        obj.Members["musicVolume"] = new JVal.Num(settings.MusicVolume);
        return obj;
    }

    private static JVal EncodeEvent(ReminderEvent e)
    {
        var obj = new JVal.Obj();
        obj.Members["id"] = EncodeUuid(e.Id);
        obj.Members["reminderID"] = EncodeUuid(e.ReminderId);
        obj.Members["reminderTitle"] = new JVal.Str(e.ReminderTitle);
        obj.Members["date"] = EncodeDate(e.Date);
        obj.Members["outcome"] = new JVal.Str(OutcomeRaw(e.EventOutcome));
        return obj;
    }

    private static JVal EncodeUuid(Guid id) =>
        new JVal.Str(id.ToString("D").ToUpperInvariant());

    private static JVal EncodeDate(Instant instant) =>
        new JVal.Num(instant.RoundedToSecond().ToUnixTimeSeconds());

    private static string PriorityRaw(Priority priority) => priority switch
    {
        Priority.Subtle => "subtle",
        Priority.Normal => "normal",
        Priority.Important => "important",
        Priority.Critical => "critical",
        _ => throw new InvalidOperationException(),
    };

    private static string OutcomeRaw(ReminderEvent.Outcome outcome) => outcome switch
    {
        ReminderEvent.Outcome.Fired => "fired",
        ReminderEvent.Outcome.Completed => "completed",
        ReminderEvent.Outcome.Snoozed => "snoozed",
        ReminderEvent.Outcome.Dismissed => "dismissed",
        ReminderEvent.Outcome.Missed => "missed",
        _ => throw new InvalidOperationException(),
    };

    // MARK: - Writer

    private static void WriteValue(StringBuilder builder, JVal value, int depth)
    {
        switch (value)
        {
            case JVal.Obj obj when obj.Members.Count == 0:
                builder.Append("{\n\n").Append(' ', depth * 2).Append('}');
                break;

            case JVal.Obj obj:
            {
                builder.Append("{\n");
                var remaining = obj.Members.Count;
                foreach (var (key, member) in obj.Members)
                {
                    builder.Append(' ', (depth + 1) * 2);
                    WriteString(builder, key);
                    builder.Append(" : ");
                    WriteValue(builder, member, depth + 1);
                    if (--remaining > 0) builder.Append(',');
                    builder.Append('\n');
                }
                builder.Append(' ', depth * 2).Append('}');
                break;
            }

            case JVal.Arr arr when arr.Items.Count == 0:
                builder.Append("[\n\n").Append(' ', depth * 2).Append(']');
                break;

            case JVal.Arr arr:
            {
                builder.Append("[\n");
                var remaining = arr.Items.Count;
                foreach (var item in arr.Items)
                {
                    builder.Append(' ', (depth + 1) * 2);
                    WriteValue(builder, item, depth + 1);
                    if (--remaining > 0) builder.Append(',');
                    builder.Append('\n');
                }
                builder.Append(' ', depth * 2).Append(']');
                break;
            }

            case JVal.Str str:
                WriteString(builder, str.Value);
                break;

            case JVal.Num num:
                builder.Append(num.Value.ToString(CultureInfo.InvariantCulture));
                break;

            case JVal.Bool boolean:
                builder.Append(boolean.Value ? "true" : "false");
                break;
        }
    }

    private static void WriteString(StringBuilder builder, string value)
    {
        builder.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '/': builder.Append("\\/"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                case '\b': builder.Append("\\b"); break;
                case '\f': builder.Append("\\f"); break;
                default:
                    if (c < 0x20)
                    {
                        builder.Append("\\u").Append(((int)c).ToString("x4"));
                    }
                    else
                    {
                        builder.Append(c);
                    }
                    break;
            }
        }
        builder.Append('"');
    }

    // MARK: - Decoding

    public static AppData Decode(byte[] raw)
    {
        // Tolerate a UTF-8 BOM: strict Parse refuses one, and a data file
        // resaved by a Windows editor (or written by Windows PowerShell)
        // easily grows one. Rejecting it would send the engine down the
        // corrupt-file fallback and replace the user's reminders with the
        // starter set — far too high a price for three invisible bytes.
        // Nothing here ever writes a BOM.
        var payload = raw is [0xEF, 0xBB, 0xBF, ..] ? raw.AsMemory(3) : raw.AsMemory();
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new FormatException("Top level is not an object");
        }

        var reminders = new List<Reminder>();
        foreach (var element in Require(root, "reminders").EnumerateArray())
        {
            reminders.Add(DecodeReminder(element));
        }

        var events = new List<ReminderEvent>();
        foreach (var element in Require(root, "events").EnumerateArray())
        {
            events.Add(DecodeEvent(element));
        }

        return new AppData
        {
            SchemaVersion = Require(root, "schemaVersion").GetInt32(),
            Reminders = reminders,
            Settings = DecodeSettings(Require(root, "settings")),
            Events = events,
        };
    }

    private static Reminder DecodeReminder(JsonElement element) => new()
    {
        Id = DecodeUuid(Require(element, "id")),
        Title = Require(element, "title").GetString()
            ?? throw new FormatException("title is not a string"),
        Message = Require(element, "message").GetString()
            ?? throw new FormatException("message is not a string"),
        Schedule = DecodeSchedule(Require(element, "schedule")),
        Priority = DecodePriority(Require(element, "priority")),
        IsEnabled = Require(element, "isEnabled").GetBoolean(),
        SymbolName = Require(element, "symbolName").GetString()
            ?? throw new FormatException("symbolName is not a string"),
        ActivityDurationSeconds = OptionalInt(element, "activityDurationSeconds"),
        SoundName = OptionalString(element, "soundName"),
        DisplaySeconds = OptionalInt(element, "displaySeconds"),
        // Lenient, so a data file written before the music feature existed
        // still loads instead of the engine wiping it with the starter set.
        Music = element.TryGetProperty("music", out var music)
            ? DecodeMusic(music)
            : MusicChoice.None,
        Exercises = OptionalExercises(element),
        LastFiredAt = OptionalDate(element, "lastFiredAt"),
        LastAcknowledgedAt = OptionalDate(element, "lastAcknowledgedAt"),
        SnoozedUntil = OptionalDate(element, "snoozedUntil"),
        CreatedAt = DecodeDate(Require(element, "createdAt")),
    };

    private static Schedule DecodeSchedule(JsonElement element)
    {
        if (element.TryGetProperty("interval", out var interval))
        {
            return new Schedule.Interval(Require(interval, "minutes").GetInt32());
        }
        if (element.TryGetProperty("dailyAt", out var daily))
        {
            return new Schedule.DailyAt(
                Require(daily, "hour").GetInt32(),
                Require(daily, "minute").GetInt32(),
                Require(daily, "dayInterval").GetInt32()
            );
        }
        if (element.TryGetProperty("weeklyAt", out var weekly))
        {
            var weekdays = new HashSet<int>();
            foreach (var day in Require(weekly, "weekdays").EnumerateArray())
            {
                weekdays.Add(day.GetInt32());
            }
            return new Schedule.WeeklyAt(
                Require(weekly, "hour").GetInt32(),
                Require(weekly, "minute").GetInt32(),
                weekdays
            );
        }
        throw new FormatException("Unrecognised schedule kind");
    }

    private static MusicChoice DecodeMusic(JsonElement element)
    {
        if (element.TryGetProperty("none", out _)) return MusicChoice.None;
        if (element.TryGetProperty("defaultPlaylist", out _)) return MusicChoice.DefaultPlaylist;
        if (element.TryGetProperty("playlist", out var playlist))
        {
            return MusicChoice.Playlist(
                Require(playlist, "uri").GetString()
                ?? throw new FormatException("uri is not a string")
            );
        }
        throw new FormatException("Unrecognised music kind");
    }

    /// <summary>
    /// Lenient at the reminder level (absent means "not an exercise reminder",
    /// the same way absent music means "no music"); strict inside each
    /// exercise, where both encoders always write every key.
    /// </summary>
    private static IReadOnlyList<Exercise>? OptionalExercises(JsonElement element)
    {
        if (!element.TryGetProperty("exercises", out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw new FormatException("exercises is not an array");
        }
        return value.EnumerateArray().Select(DecodeExercise).ToList();
    }

    private static Exercise DecodeExercise(JsonElement element) => new()
    {
        Id = DecodeUuid(Require(element, "id")),
        Name = Require(element, "name").GetString()
            ?? throw new FormatException("name is not a string"),
        Instructions = Require(element, "instructions").GetString()
            ?? throw new FormatException("instructions is not a string"),
        Sets = Require(element, "sets").GetInt32(),
        Reps = Require(element, "reps").GetInt32(),
    };

    private static Settings DecodeSettings(JsonElement element) => new()
    {
        QuietHours = DecodeQuietHours(Require(element, "quietHours")),
        IsPaused = Require(element, "isPaused").GetBoolean(),
        PausedUntil = OptionalDate(element, "pausedUntil"),
        SnoozeMinutes = Require(element, "snoozeMinutes").GetInt32(),
        SubtleDisplaySeconds = Require(element, "subtleDisplaySeconds").GetInt32(),
        LaunchAtLogin = Require(element, "launchAtLogin").GetBoolean(),
        ShowsNextReminderInMenuBar =
            Require(element, "showsNextReminderInMenuBar").GetBoolean(),
        SoundEnabled = Require(element, "soundEnabled").GetBoolean(),
        DefaultPlaylistUri = OptionalString(element, "defaultPlaylistURI"),
        // Lenient: settings written before the music feature existed load with
        // the defaults rather than resetting every preference. See the
        // matching note on Reminder decoding.
        MusicEnabled = element.TryGetProperty("musicEnabled", out var musicEnabled)
            && musicEnabled.ValueKind != JsonValueKind.Null
            ? musicEnabled.GetBoolean()
            : true,
        MusicVolume = element.TryGetProperty("musicVolume", out var musicVolume)
            && musicVolume.ValueKind != JsonValueKind.Null
            ? musicVolume.GetInt32()
            : 55,
    };

    private static QuietHours DecodeQuietHours(JsonElement element) => new()
    {
        IsEnabled = Require(element, "isEnabled").GetBoolean(),
        StartHour = Require(element, "startHour").GetInt32(),
        StartMinute = Require(element, "startMinute").GetInt32(),
        EndHour = Require(element, "endHour").GetInt32(),
        EndMinute = Require(element, "endMinute").GetInt32(),
        AllowsCritical = Require(element, "allowsCritical").GetBoolean(),
    };

    private static ReminderEvent DecodeEvent(JsonElement element) => new()
    {
        Id = DecodeUuid(Require(element, "id")),
        ReminderId = DecodeUuid(Require(element, "reminderID")),
        ReminderTitle = Require(element, "reminderTitle").GetString()
            ?? throw new FormatException("reminderTitle is not a string"),
        Date = DecodeDate(Require(element, "date")),
        EventOutcome = DecodeOutcome(Require(element, "outcome")),
    };

    private static Priority DecodePriority(JsonElement element) =>
        element.GetString() switch
        {
            "subtle" => Priority.Subtle,
            "normal" => Priority.Normal,
            "important" => Priority.Important,
            "critical" => Priority.Critical,
            var other => throw new FormatException($"Unknown priority '{other}'"),
        };

    private static ReminderEvent.Outcome DecodeOutcome(JsonElement element) =>
        element.GetString() switch
        {
            "fired" => ReminderEvent.Outcome.Fired,
            "completed" => ReminderEvent.Outcome.Completed,
            "snoozed" => ReminderEvent.Outcome.Snoozed,
            "dismissed" => ReminderEvent.Outcome.Dismissed,
            "missed" => ReminderEvent.Outcome.Missed,
            var other => throw new FormatException($"Unknown outcome '{other}'"),
        };

    private static Guid DecodeUuid(JsonElement element) =>
        Guid.Parse(
            element.GetString() ?? throw new FormatException("UUID is not a string")
        );

    private static Instant DecodeDate(JsonElement element)
    {
        // Whole seconds since 1970, rounding exactly as the Swift decoder does
        // so both platforms materialise the same instant from the same bytes.
        var seconds = Math.Round(element.GetDouble(), MidpointRounding.AwayFromZero);
        return Instant.FromUnixTimeSeconds((long)seconds);
    }

    private static JsonElement Require(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            throw new FormatException($"Missing required field '{name}'");
        }
        return value;
    }

    private static int? OptionalInt(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value)
        && value.ValueKind != JsonValueKind.Null
            ? value.GetInt32()
            : null;

    private static string? OptionalString(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value)
        && value.ValueKind != JsonValueKind.Null
            ? value.GetString()
            : null;

    private static Instant? OptionalDate(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value)
        && value.ValueKind != JsonValueKind.Null
            ? DecodeDate(value)
            : null;
}
