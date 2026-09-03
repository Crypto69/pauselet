import XCTest
@testable import ReminderCore

/// The exercise list on a reminder: what it means, how the editor tidies it,
/// and — the part that matters for file interchange — that the Mac encoder
/// writes exactly the bytes the Windows port's `ExerciseTests` expects.
final class ExerciseTests: XCTestCase {

    // MARK: - Model

    func testSummaryFormatsSetsAndReps() {
        XCTAssertEqual(Exercise(name: "Squats", sets: 3, reps: 10).summary, "3 × 10")
        XCTAssertEqual(
            Exercise(name: "Chin tucks", sets: 3, reps: 10, holdSeconds: 5).summary,
            "3 × 10 · hold 5 s"
        )
    }

    func testValidationRequiresANameAndPositiveCounts() {
        XCTAssertTrue(Exercise(name: "Squats").isValid)
        XCTAssertFalse(Exercise(name: "   ").isValid)
        XCTAssertFalse(Exercise(name: "Squats", sets: 0).isValid)
        XCTAssertFalse(Exercise(name: "Squats", reps: 0).isValid)
    }

    func testValidationRejectsNegativeTiming() {
        XCTAssertTrue(Exercise(name: "Squats", holdSeconds: 0).isValid)
        XCTAssertFalse(Exercise(name: "Squats", holdSeconds: -1).isValid)
        XCTAssertFalse(Exercise(name: "Squats", restBetweenRepsSeconds: -1).isValid)
        XCTAssertFalse(Exercise(name: "Squats", restBetweenSetsSeconds: -1).isValid)
    }

    func testIsGuidedMeansAHoldTime() {
        XCTAssertFalse(Exercise(name: "Squats").isGuided)
        XCTAssertFalse(Exercise(name: "Squats", restBetweenRepsSeconds: 10).isGuided)
        XCTAssertTrue(Exercise(name: "Chin tucks", holdSeconds: 5).isGuided)
    }

    func testNormalizationClampsTimingIntoRange() throws {
        let kept = try XCTUnwrap(Exercise.normalized([
            Exercise(
                name: "Squats", holdSeconds: -5,
                restBetweenRepsSeconds: 10_000, restBetweenSetsSeconds: 30
            ),
        ]))

        XCTAssertEqual(kept[0].holdSeconds, 0, "A negative hold is untimed, not dropped")
        XCTAssertEqual(kept[0].restBetweenRepsSeconds, Exercise.restRange.upperBound)
        XCTAssertEqual(kept[0].restBetweenSetsSeconds, 30)
    }

    func testNormalizationCollapsesAnEmptyListToNil() {
        XCTAssertNil(Exercise.normalized([]))
        XCTAssertNil(Exercise.normalized([
            Exercise(name: ""),
            Exercise(name: "x", sets: 0),
        ]))
    }

    func testNormalizationTrimsNamesAndUnifiesLineEndings() throws {
        let id = UUID()
        let typed = Exercise(
            id: id,
            name: "  Squats ",
            instructions: "Feet apart.\r\nLower slowly.\rHold.  "
        )

        let kept = try XCTUnwrap(Exercise.normalized([typed]))

        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].id, id)
        XCTAssertEqual(kept[0].name, "Squats")
        XCTAssertEqual(kept[0].instructions, "Feet apart.\nLower slowly.\nHold.")
    }

    func testReminderWithoutExercisesIsNotAnExerciseReminder() {
        var plain = Reminder(title: "Water", schedule: .interval(minutes: 60))
        XCTAssertFalse(plain.isExercise)
        XCTAssertNil(plain.exerciseSummary)

        plain.exercises = []
        XCTAssertFalse(plain.isExercise)
        XCTAssertNil(plain.exerciseSummary)
    }

    func testReminderWithExercisesReportsASummary() {
        var physio = Reminder(
            title: "Physio",
            schedule: .interval(minutes: 60),
            exercises: [
                Exercise(name: "Squats", sets: 3, reps: 10),
                Exercise(name: "Wall Push-ups", sets: 2, reps: 15),
            ]
        )
        XCTAssertTrue(physio.isExercise)
        XCTAssertEqual(physio.exerciseSummary, "2 exercises · 5 sets")

        physio.exercises = [Exercise(name: "Plank", sets: 1, reps: 1)]
        XCTAssertEqual(physio.exerciseSummary, "1 exercise · 1 set")
    }

    func testStarterSetContainsNoExerciseReminders() {
        XCTAssertTrue(DefaultReminders.starterSet().allSatisfy { !$0.isExercise })
    }

    // MARK: - Persistence

    /// Adding the field must not make an existing install fail to decode.
    /// `ReminderEngine` reacts to a decode failure by falling back to the
    /// starter set, which would silently wipe every reminder the user has.
    func testDataWrittenBeforeExercisesExistedStillDecodes() throws {
        let legacy = """
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
        """

        let data = try Self.decoder().decode(AppData.self, from: Data(legacy.utf8))

        XCTAssertEqual(data.reminders.count, 1)
        XCTAssertNil(data.reminders[0].exercises)
        XCTAssertFalse(data.reminders[0].isExercise)
    }

    func testExercisesDecodeFromRawJSON() throws {
        let raw = #"""
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
        """#

        let data = try Self.decoder().decode(AppData.self, from: Data(raw.utf8))
        let reminder = try XCTUnwrap(data.reminders.first)
        let exercises = try XCTUnwrap(reminder.exercises)

        XCTAssertTrue(reminder.isExercise)
        XCTAssertEqual(exercises.count, 2)
        XCTAssertEqual(exercises[0].id, UUID(uuidString: "11111111-aaaa-bbbb-cccc-dddddddddddd"))
        XCTAssertEqual(exercises[0].name, "Squats")
        XCTAssertEqual(exercises[0].instructions, "Line one.\nLine 2/3.")
        XCTAssertEqual(exercises[0].sets, 3)
        XCTAssertEqual(exercises[0].reps, 10)
        XCTAssertEqual(exercises[1].name, "Bridge")
        XCTAssertEqual(exercises[1].reps, 12)
        // Written before the timing fields existed: untimed, not a decode error.
        XCTAssertEqual(exercises[0].holdSeconds, 0)
        XCTAssertEqual(exercises[0].restBetweenRepsSeconds, 0)
        XCTAssertEqual(exercises[0].restBetweenSetsSeconds, 0)
        XCTAssertFalse(exercises[0].isGuided)
    }

    func testExercisesRoundTripThroughTheStore() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDataStore(fileURL: directory.appendingPathComponent("data.json"))

        let original = AppData(
            reminders: [
                Reminder(
                    title: "Physio",
                    schedule: .interval(minutes: 45),
                    priority: .critical,
                    exercises: [
                        Exercise(
                            name: "Squats",
                            instructions: "Feet apart.\nLower slowly, 2/3 depth.",
                            sets: 3, reps: 10,
                            holdSeconds: 5, restBetweenRepsSeconds: 3, restBetweenSetsSeconds: 30
                        ),
                        Exercise(name: "Bridge", sets: 2, reps: 12),
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_760_000_000)
                ),
            ],
            settings: Settings()
        )

        try store.save(original)
        let loaded = try store.load()

        XCTAssertEqual(loaded.reminders[0].exercises, original.reminders[0].exercises)
        XCTAssertEqual(loaded, original)
    }

    /// An ordinary reminder must not grow an `exercises` key: the encoder omits
    /// nil optionals, and a key that is sometimes there would change the bytes
    /// of every existing file.
    func testExercisesKeyIsOmittedWhenNil() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("data.json")
        let store = FileDataStore(fileURL: fileURL)

        try store.save(AppData(
            reminders: [Reminder(title: "Water", schedule: .interval(minutes: 60))],
            settings: Settings()
        ))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("\"exercises\""))
    }

    // MARK: - Byte compatibility with the Windows port

    /// The bytes this encoder writes for an exercise reminder. The Windows
    /// port's `ExerciseTests.cs` holds the same literal and must decode it and
    /// re-encode it byte-for-byte; this test is what keeps that literal
    /// honest. If it fails after an encoder change, update both copies from
    /// the actual output — the Mac encoder defines the format.
    private static let goldenExerciseFile = #"""
    {
      "events" : [

      ],
      "reminders" : [
        {
          "createdAt" : 1760000004,
          "exercises" : [
            {
              "holdSeconds" : 5,
              "id" : "11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
              "instructions" : "Feet shoulder-width apart.\nLower slowly, 2\/3 depth.",
              "name" : "Squats",
              "reps" : 10,
              "restBetweenRepsSeconds" : 3,
              "restBetweenSetsSeconds" : 30,
              "sets" : 3
            },
            {
              "holdSeconds" : 0,
              "id" : "22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD",
              "instructions" : "",
              "name" : "Wall Push-ups",
              "reps" : 15,
              "restBetweenRepsSeconds" : 0,
              "restBetweenSetsSeconds" : 0,
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
        "aiImportEnabled" : false,
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
        "subtleDisplaySeconds" : 8,
        "voiceCoachEnabled" : false,
        "voiceCoachRate" : 45
      }
    }
    """#

    private static func goldenExerciseModel() -> AppData {
        AppData(
            reminders: [
                Reminder(
                    id: UUID(uuidString: "EEEEEEEE-0000-1111-2222-333333333333")!,
                    title: "Physio Set",
                    message: "Work through the list, then press Done.",
                    schedule: .interval(minutes: 45),
                    priority: .critical,
                    symbolName: "dumbbell.fill",
                    exercises: [
                        Exercise(
                            id: UUID(uuidString: "11111111-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
                            name: "Squats",
                            instructions: "Feet shoulder-width apart.\nLower slowly, 2/3 depth.",
                            sets: 3, reps: 10,
                            holdSeconds: 5, restBetweenRepsSeconds: 3, restBetweenSetsSeconds: 30
                        ),
                        Exercise(
                            id: UUID(uuidString: "22222222-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
                            name: "Wall Push-ups",
                            instructions: "",
                            sets: 2, reps: 15
                        ),
                    ],
                    createdAt: Date(timeIntervalSince1970: 1_760_000_004)
                ),
            ],
            settings: Settings()
        )
    }

    func testExerciseReminderEncodesToTheGoldenBytes() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("data.json")
        let store = FileDataStore(fileURL: fileURL)

        try store.save(Self.goldenExerciseModel())

        let written = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(written, Self.goldenExerciseFile)
    }

    func testGoldenBytesDecodeToTheModel() throws {
        let data = try Self.decoder().decode(
            AppData.self, from: Data(Self.goldenExerciseFile.utf8)
        )
        XCTAssertEqual(data, Self.goldenExerciseModel())
    }

    // MARK: - Helpers

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            return Date(timeIntervalSince1970: try container.decode(Double.self))
        }
        return decoder
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }
}
