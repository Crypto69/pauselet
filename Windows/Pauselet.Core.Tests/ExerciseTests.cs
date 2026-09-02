using System.Text;
using Pauselet.Core;
using Xunit;

namespace Pauselet.Core.Tests;

/// <summary>
/// The exercise list on a reminder: what it means, how the editor tidies it,
/// and — the part that matters for file interchange — that it reads and
/// writes exactly the bytes the Mac encoder produces.
/// </summary>
public class ExerciseTests
{
    // MARK: - Model

    [Fact]
    public void SummaryFormatsSetsAndReps()
    {
        var squats = new Exercise { Name = "Squats", Sets = 3, Reps = 10 };
        Assert.Equal("3 × 10", squats.Summary);
    }

    [Fact]
    public void ValidationRequiresANameAndPositiveCounts()
    {
        Assert.True(new Exercise { Name = "Squats" }.IsValid);
        Assert.False(new Exercise { Name = "   " }.IsValid);
        Assert.False(new Exercise { Name = "Squats", Sets = 0 }.IsValid);
        Assert.False(new Exercise { Name = "Squats", Reps = 0 }.IsValid);
    }

    [Fact]
    public void NormalizationCollapsesAnEmptyListToNull()
    {
        Assert.Null(Exercise.Normalized([]));
        Assert.Null(Exercise.Normalized([new Exercise { Name = "" }, new Exercise { Name = "x", Sets = 0 }]));
    }

    [Fact]
    public void NormalizationTrimsNamesAndUnifiesLineEndings()
    {
        var id = Guid.NewGuid();
        var typed = new Exercise
        {
            Id = id,
            Name = "  Squats ",
            Instructions = "Feet apart.\r\nLower slowly.\rHold.  ",
        };

        var kept = Exercise.Normalized([typed]);

        Assert.NotNull(kept);
        var exercise = Assert.Single(kept);
        Assert.Equal(id, exercise.Id);
        Assert.Equal("Squats", exercise.Name);
        Assert.Equal("Feet apart.\nLower slowly.\nHold.", exercise.Instructions);
    }

    [Fact]
    public void ReminderWithoutExercisesIsNotAnExerciseReminder()
    {
        var plain = new Reminder { Title = "Water", Schedule = new Schedule.Interval(60) };
        var empty = plain with { Exercises = [] };

        Assert.False(plain.IsExercise);
        Assert.Null(plain.ExerciseSummary);
        Assert.False(empty.IsExercise);
        Assert.Null(empty.ExerciseSummary);
    }

    [Fact]
    public void ReminderWithExercisesReportsASummary()
    {
        var physio = new Reminder
        {
            Title = "Physio",
            Schedule = new Schedule.Interval(60),
            Exercises =
            [
                new Exercise { Name = "Squats", Sets = 3, Reps = 10 },
                new Exercise { Name = "Wall Push-ups", Sets = 2, Reps = 15 },
            ],
        };
        var single = physio with { Exercises = [new Exercise { Name = "Plank", Sets = 1, Reps = 1 }] };

        Assert.True(physio.IsExercise);
        Assert.Equal("2 exercises · 5 sets", physio.ExerciseSummary);
        Assert.Equal("1 exercise · 1 set", single.ExerciseSummary);
    }

    /// <summary>
    /// The store round-trip tests compare whole AppData values, which only
    /// works if a reminder built from one list equals a reminder built from
    /// another list with the same contents.
    /// </summary>
    [Fact]
    public void RemindersWithEqualExercisesCompareEqual()
    {
        var id = Guid.NewGuid();
        var exerciseId = Guid.NewGuid();
        var created = NodaTime.Instant.FromUnixTimeSeconds(1_760_000_000);
        Reminder Build(int reps) => new()
        {
            Id = id,
            Title = "Physio",
            Schedule = new Schedule.Interval(60),
            Exercises = [new Exercise { Id = exerciseId, Name = "Squats", Sets = 3, Reps = reps }],
            CreatedAt = created,
        };

        Assert.Equal(Build(10), Build(10));
        Assert.Equal(Build(10).GetHashCode(), Build(10).GetHashCode());
        Assert.NotEqual(Build(10), Build(12));
        Assert.NotEqual(Build(10), Build(10) with { Exercises = null });
    }

    // MARK: - Persistence

    /// <summary>
    /// A data file written before exercises existed must not fail to decode:
    /// the engine reacts to a decode failure by falling back to the starter
    /// set, which would silently wipe every reminder the user has.
    /// </summary>
    [Fact]
    public void DataWrittenBeforeExercisesExistedStillDecodes()
    {
        const string legacy = """
        {
          "schemaVersion": 1,
          "reminders": [{
            "id": "9E1B4A2C-1F3D-4B5E-8A7C-0D2E3F4A5B6C",
            "title": "Tilt Back",
            "message": "Tilt your chair back.",
            "schedule": { "interval": { "minutes": 60 } },
            "priority": "critical",
            "isEnabled": true,
            "symbolName": "figure.seated.side",
            "music": { "none": {} },
            "createdAt": 1700000000
          }],
          "settings": {
            "quietHours": {
              "isEnabled": false, "startHour": 22, "startMinute": 0,
              "endHour": 7, "endMinute": 0, "allowsCritical": true
            },
            "isPaused": false,
            "snoozeMinutes": 5,
            "subtleDisplaySeconds": 8,
            "launchAtLogin": false,
            "showsNextReminderInMenuBar": true,
            "soundEnabled": true
          },
          "events": []
        }
        """;

        var data = AppDataJson.Decode(Encoding.UTF8.GetBytes(legacy));

        var reminder = Assert.Single(data.Reminders);
        Assert.Null(reminder.Exercises);
        Assert.False(reminder.IsExercise);
    }

    [Fact]
    public void ExercisesDecodeFromRawJson()
    {
        const string raw = """
        {
          "schemaVersion": 1,
          "reminders": [{
            "id": "9E1B4A2C-1F3D-4B5E-8A7C-0D2E3F4A5B6C",
            "title": "Physio",
            "message": "",
            "schedule": { "interval": { "minutes": 60 } },
            "priority": "critical",
            "isEnabled": true,
            "symbolName": "dumbbell.fill",
            "music": { "none": {} },
            "exercises": [
              { "id": "11111111-aaaa-bbbb-cccc-dddddddddddd", "name": "Squats",
                "instructions": "Line one.\nLine 2\/3.", "sets": 3, "reps": 10 },
              { "id": "22222222-aaaa-bbbb-cccc-dddddddddddd", "name": "Bridge",
                "instructions": "", "sets": 2, "reps": 12 }
            ],
            "createdAt": 1700000000
          }],
          "settings": {
            "quietHours": {
              "isEnabled": false, "startHour": 22, "startMinute": 0,
              "endHour": 7, "endMinute": 0, "allowsCritical": true
            },
            "isPaused": false,
            "snoozeMinutes": 5,
            "subtleDisplaySeconds": 8,
            "launchAtLogin": false,
            "showsNextReminderInMenuBar": true,
            "soundEnabled": true
          },
          "events": []
        }
        """;

        var reminder = Assert.Single(AppDataJson.Decode(Encoding.UTF8.GetBytes(raw)).Reminders);

        Assert.True(reminder.IsExercise);
        Assert.NotNull(reminder.Exercises);
        Assert.Equal(2, reminder.Exercises.Count);
        var squats = reminder.Exercises[0];
        Assert.Equal(Guid.Parse("11111111-aaaa-bbbb-cccc-dddddddddddd"), squats.Id);
        Assert.Equal("Squats", squats.Name);
        Assert.Equal("Line one.\nLine 2/3.", squats.Instructions);
        Assert.Equal(3, squats.Sets);
        Assert.Equal(10, squats.Reps);
        Assert.Equal("Bridge", reminder.Exercises[1].Name);
        Assert.Equal(12, reminder.Exercises[1].Reps);
    }

    [Fact]
    public void ExercisesRoundTripThroughTheStore()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(directory);
        try
        {
            var store = new FileDataStore(Path.Combine(directory, "data.json"));
            var original = new AppData
            {
                Reminders =
                [
                    new Reminder
                    {
                        Title = "Physio",
                        Schedule = new Schedule.Interval(45),
                        Priority = Priority.Critical,
                        Exercises =
                        [
                            new Exercise
                            {
                                Name = "Squats",
                                Instructions = "Feet apart.\nLower slowly, 2/3 depth.",
                                Sets = 3,
                                Reps = 10,
                            },
                            new Exercise { Name = "Bridge", Sets = 2, Reps = 12 },
                        ],
                        CreatedAt = NodaTime.Instant.FromUnixTimeSeconds(1_760_000_000),
                    },
                ],
            };

            store.Save(original);
            var loaded = store.Load();

            Assert.Equal(original.Reminders[0].Exercises, loaded.Reminders[0].Exercises);
            Assert.Equal(original, loaded);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    /// An ordinary reminder must not grow an <c>exercises</c> key: the Mac
    /// encoder omits nil optionals, and a key that is sometimes there would
    /// change the bytes of every existing file.
    /// </summary>
    [Fact]
    public void ExercisesKeyIsOmittedWhenNull()
    {
        var data = new AppData
        {
            Reminders = [new Reminder { Title = "Water", Schedule = new Schedule.Interval(60) }],
        };

        var text = Encoding.UTF8.GetString(AppDataJson.Encode(data));

        Assert.DoesNotContain("\"exercises\"", text);
    }

    // MARK: - Byte compatibility with the Mac encoder

    /// <summary>
    /// Produced by the real Swift encoder (JSONEncoder, prettyPrinted +
    /// sortedKeys, whole-second dates) for the reminder built in
    /// <see cref="ExerciseFixtureModel"/>. Keep it identical to the literal in
    /// the Swift suite's <c>testExerciseReminderEncodesToTheGoldenBytes</c>.
    /// Line endings are normalised on read so a CRLF checkout cannot break it.
    /// </summary>
    private const string ExerciseFixture = """
        {
          "events" : [

          ],
          "reminders" : [
            {
              "createdAt" : 1760000004,
              "exercises" : [
                {
                  "id" : "11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
                  "instructions" : "Feet shoulder-width apart.\nLower slowly, 2\/3 depth.",
                  "name" : "Squats",
                  "reps" : 10,
                  "sets" : 3
                },
                {
                  "id" : "22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
                  "instructions" : "",
                  "name" : "Wall Push-ups",
                  "reps" : 15,
                  "sets" : 2
                }
              ],
              "id" : "EEEEEEEE-0000-1111-2222-333333333333",
              "isEnabled" : true,
              "message" : "Work through the list, then press Done.",
              "music" : {
                "none" : {

                }
              },
              "priority" : "critical",
              "schedule" : {
                "interval" : {
                  "minutes" : 45
                }
              },
              "symbolName" : "dumbbell.fill",
              "title" : "Physio Set"
            }
          ],
          "schemaVersion" : 1,
          "settings" : {
            "isPaused" : false,
            "launchAtLogin" : false,
            "musicEnabled" : true,
            "musicVolume" : 55,
            "quietHours" : {
              "allowsCritical" : true,
              "endHour" : 7,
              "endMinute" : 0,
              "isEnabled" : false,
              "startHour" : 22,
              "startMinute" : 0
            },
            "showsNextReminderInMenuBar" : true,
            "snoozeMinutes" : 5,
            "soundEnabled" : true,
            "subtleDisplaySeconds" : 8
          }
        }
        """;

    private static byte[] ExerciseFixtureBytes() =>
        Encoding.UTF8.GetBytes(ExerciseFixture.Replace("\r\n", "\n"));

    private static AppData ExerciseFixtureModel() => new()
    {
        Reminders =
        [
            new Reminder
            {
                Id = Guid.Parse("EEEEEEEE-0000-1111-2222-333333333333"),
                Title = "Physio Set",
                Message = "Work through the list, then press Done.",
                Schedule = new Schedule.Interval(45),
                Priority = Priority.Critical,
                SymbolName = "dumbbell.fill",
                Exercises =
                [
                    new Exercise
                    {
                        Id = Guid.Parse("11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD"),
                        Name = "Squats",
                        Instructions = "Feet shoulder-width apart.\nLower slowly, 2/3 depth.",
                        Sets = 3,
                        Reps = 10,
                    },
                    new Exercise
                    {
                        Id = Guid.Parse("22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD"),
                        Name = "Wall Push-ups",
                        Instructions = "",
                        Sets = 2,
                        Reps = 15,
                    },
                ],
                CreatedAt = NodaTime.Instant.FromUnixTimeSeconds(1_760_000_004),
            },
        ],
    };

    [Fact]
    public void ExerciseFixtureDecodesToTheExpectedValues()
    {
        var data = AppDataJson.Decode(ExerciseFixtureBytes());

        Assert.Equal(ExerciseFixtureModel(), data);
        var reminder = Assert.Single(data.Reminders);
        Assert.True(reminder.IsExercise);
        Assert.Equal(Priority.Critical, reminder.Priority);
        Assert.Equal("2 exercises · 5 sets", reminder.ExerciseSummary);
    }

    [Fact]
    public void ExerciseModelEncodesToTheMacBytes()
    {
        Assert.Equal(ExerciseFixtureBytes(), AppDataJson.Encode(ExerciseFixtureModel()));
    }

    [Fact]
    public void ExerciseFixtureReencodesByteIdentically()
    {
        var bytes = ExerciseFixtureBytes();
        Assert.Equal(bytes, AppDataJson.Encode(AppDataJson.Decode(bytes)));
    }

    /// <summary>
    /// The Swift encoder writes an empty array when the optional is non-nil
    /// but empty. Such a file must re-encode unchanged rather than have the
    /// key dropped — and still read as "not an exercise reminder".
    /// </summary>
    [Fact]
    public void EmptyExercisesArrayReencodesByteIdentically()
    {
        var bytes = Encoding.UTF8.GetBytes(ExerciseFixture
            .Replace("\r\n", "\n")
            .Replace("""
              "exercises" : [
                {
                  "id" : "11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
                  "instructions" : "Feet shoulder-width apart.\nLower slowly, 2\/3 depth.",
                  "name" : "Squats",
                  "reps" : 10,
                  "sets" : 3
                },
                {
                  "id" : "22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
                  "instructions" : "",
                  "name" : "Wall Push-ups",
                  "reps" : 15,
                  "sets" : 2
                }
              ],
        """.Replace("\r\n", "\n"), """
              "exercises" : [

              ],
        """.Replace("\r\n", "\n")));

        var data = AppDataJson.Decode(bytes);

        var reminder = Assert.Single(data.Reminders);
        Assert.NotNull(reminder.Exercises);
        Assert.Empty(reminder.Exercises);
        Assert.False(reminder.IsExercise);
        Assert.Equal(bytes, AppDataJson.Encode(data));
    }
}
