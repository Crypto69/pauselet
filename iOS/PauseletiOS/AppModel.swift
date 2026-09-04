import SwiftUI
import Combine
import BackgroundTasks
import UserNotifications
import ReminderCore
import ReminderAI

/// Owns the engine and every iOS delivery surface, and keeps the two worlds —
/// the live in-app engine and the system's pre-scheduled notifications and
/// alarms — telling the same story.
///
/// The macOS app is a resident tick loop; iOS inverts that (§3.3 of the plan):
/// while the app is frontmost a timer ticks the engine and reminders present
/// in-app, and the moment it leaves the foreground everything upcoming is
/// handed to the system as scheduled notifications (subtle/normal/important)
/// and AlarmKit alarms (critical). Every return to the foreground reconciles
/// what the system did in the meantime — *before* the first tick, as the
/// engine's contract requires — then re-schedules.
@MainActor
final class AppModel: NSObject, ObservableObject, ReminderPresenting {

    static let shared = AppModel()

    let engine: ReminderEngine
    let notifications: NotificationScheduler
    let alarms: CriticalAlarmController
    /// The one speech synthesizer in the app, so the coach and the Settings
    /// Test button share a voice path — and so a cue is never spoken twice.
    let speech: SpeechCoach
    /// The API key and any interpretation in flight. Optional at runtime: with
    /// no key stored the importer uses the local parser and the app makes no
    /// network requests at all.
    let ai: AIImportController

    // MARK: - In-app surfaces

    struct TakeoverItem: Identifiable, Equatable {
        let id = UUID()
        let reminder: Reminder
        let isPreview: Bool
    }

    struct SubtleCardItem: Identifiable, Equatable {
        let id = UUID()
        let reminder: Reminder
        let dismissAfterSeconds: Int
        let isPreview: Bool
    }

    /// The critical takeover currently covering the app, if any.
    @Published var takeover: TakeoverItem?
    /// The subtle card currently overlaid on the app, if any.
    @Published var subtleCard: SubtleCardItem?
    /// Whether the scene is frontmost; the notification delegate consults this
    /// to decide between a system banner and the in-app surface.
    @Published private(set) var isActive = false

    /// Takeovers that fired while another takeover was up. Only honoured while
    /// fresh — see `ReminderEngine.shouldPresentQueued`.
    private var takeoverQueue: [(reminder: Reminder, queuedAt: Date)] = []
    private var subtleQueue: [Reminder] = []
    private var subtleDismissTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var activationTask: Task<Void, Never>?
    /// The takeover a lock-screen notification has already been posted for,
    /// so backgrounding twice does not post it twice.
    private var handedOffTakeoverID: UUID?
    private var timeChangeObserver: NSObjectProtocol?

    static let backgroundRefreshIdentifier = "com.pauselet.pauselet.refresh"

    override private init() {
        let store: DataStoring
        do {
            store = try FileDataStore()
        } catch {
            // Falling back to memory keeps the app usable for the session even
            // if the container is somehow unwritable.
            store = InMemoryDataStore(
                data: AppData(reminders: DefaultReminders.starterSet())
            )
        }
        let engine = ReminderEngine(store: store)
        self.engine = engine
        self.notifications = NotificationScheduler(engine: engine)
        self.alarms = CriticalAlarmController(engine: engine)
        self.speech = SpeechCoach()
        self.ai = AIImportController()
        super.init()
        ai.model = AIImportModel.resolve(engine.settings.aiImportModel)
        engine.setPresenter(self)
        notifications.model = self
        alarms.model = self
        notifications.configure()
        alarms.startObserving()
        // A time-zone or clock change moves every absolute trigger relative
        // to the wall clock the user sees; rebuild the schedule from scratch.
        timeChangeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setNeedsReschedule() }
        }
    }

    // MARK: - Scene lifecycle

    /// Every path back to the foreground — cold launch, return from the
    /// background, return from the app switcher or Control Center — runs the
    /// same activation: reconcile what the system delivered, absorb what is
    /// stale, and only then start ticking. Ticking first would replay every
    /// delivered fire as a duplicate and stamp over the real ones.
    ///
    /// `.inactive` stops the tick loop as well as `.background` does. While
    /// inactive the app is not frontmost, so a scheduled notification for the
    /// same moment shows as a banner; a tick presenting it too is a
    /// duplicate, and a tick silencing an alarm in that window strands it.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isActive = true
            activationTask?.cancel()
            activationTask = Task { await self.activate() }
        case .inactive:
            isActive = false
            activationTask?.cancel()
            stopTicking()
        case .background:
            isActive = false
            activationTask?.cancel()
            stopTicking()
            scheduleBackgroundRefresh()
            handOffUnacknowledgedTakeover()
            Task { await self.rescheduleEverything() }
        @unknown default:
            break
        }
    }

    private func activate() async {
        _ = await notifications.requestAuthorizationIfNeeded()
        await alarms.requestAuthorizationIfNeeded()
        guard !Task.isCancelled else { return }
        await reconcile()
        // The scene may have left the foreground while that ran (a permission
        // dialog alone does it); the next activation will tick.
        guard !Task.isCancelled, isActive else { return }
        startTicking()
    }

    /// Reads what the system delivered while the app was away, folds it into
    /// engine state, absorbs anything stale, fires anything genuinely current,
    /// and re-schedules the future.
    func reconcile() async {
        let now = Date()
        let fires = await notifications.deliveredExternalFires()
        engine.recordExternalFires(fires)
        await alarms.reconcile(now: now)
        // Anything still overdue past the grace window fell due while nothing
        // could deliver it (a cleared notification, a slot beyond the budget
        // horizon). Its moment has passed: absorb, don't replay.
        engine.absorbBacklogFromDowntime()
        engine.tick()
        await rescheduleEverything()
    }

    // MARK: - Rescheduling

    private var rescheduleGeneration = 0
    private var rescheduleChain: Task<Void, Never>?

    /// Brings every scheduled notification and alarm in line with current
    /// engine state, and returns once that is done.
    ///
    /// Passes are serialised and coalesced: a pass never overlaps another (an
    /// older pass could otherwise re-add requests a newer one had just
    /// cleared), and any pass superseded before it starts is skipped, since
    /// the newer one rebuilds from the latest state anyway. Each pass runs
    /// under a background-task assertion, so a pass started on the way to
    /// the background — or from a notification action or alarm intent that
    /// launched the app in the background — is not cut off by suspension,
    /// leaving the app with nothing scheduled for days.
    func rescheduleEverything() async {
        rescheduleGeneration += 1
        let generation = rescheduleGeneration
        let previous = rescheduleChain
        let task = Task { @MainActor in
            await previous?.value
            guard generation == self.rescheduleGeneration else { return }
            let assertion = BackgroundAssertion(name: "Pauselet reschedule")
            defer { assertion.end() }
            await self.runReschedulePass()
        }
        rescheduleChain = task

        // Wait until the chain is quiet, so a caller that must not return
        // before the schedule is armed (an intent, a notification response)
        // really does wait, even if its own pass was superseded.
        var awaited = task
        while true {
            await awaited.value
            guard let latest = rescheduleChain, latest != awaited else { break }
            awaited = latest
        }
    }

    private func runReschedulePass() async {
        let reminders = engine.reminders
        let settings = engine.settings
        let now = Date()
        let carried = await alarms.sync(reminders: reminders, settings: settings, now: now)
        await notifications.refill(
            reminders: reminders, settings: settings, now: now, alarmsCarrying: carried
        )
    }

    /// Fire-and-forget wrapper for call sites inside synchronous UI actions.
    /// Coalesced with every other pending reschedule.
    func setNeedsReschedule() {
        Task { await self.rescheduleEverything() }
    }

    // MARK: - Ticking (foreground only)

    private static let tickInterval: TimeInterval = 5

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.tickInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.engine.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        engine.tick()
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - ReminderPresenting

    func present(_ reminder: Reminder, settings: ReminderCore.Settings) {
        route(reminder, settings: settings, isPreview: false)
    }

    /// Shows `reminder` exactly as it would appear when it fires, without
    /// touching schedule or history. Buttons on previewed surfaces only close
    /// them.
    func preview(_ reminder: Reminder) {
        route(reminder, settings: engine.settings, isPreview: true)
    }

    private func route(_ reminder: Reminder, settings: ReminderCore.Settings, isPreview: Bool) {
        switch reminder.priority {
        case .subtle:
            showSubtle(reminder, settings: settings, isPreview: isPreview)
        case .normal, .important:
            // A real notification even in the foreground, so it lands in
            // Notification Center exactly as it would have in the background.
            if isPreview {
                notifications.postPreview(reminder, settings: settings)
            } else {
                notifications.postImmediate(reminder, settings: settings)
            }
        case .critical:
            // The AlarmKit alarm for this same moment may be sounding the
            // system alert; the in-app takeover replaces it — and so must be
            // as audible as the alarm was: the piercing route ignores the
            // Ring/Silent switch, as the editor promises for this tier.
            if !isPreview {
                alarms.stopIfAlerting(reminder.id)
            }
            if settings.playsSound(for: .critical) {
                Sounds.play(named: Sounds.criticalSound(for: reminder), route: .piercing)
            }
            showTakeover(reminder, isPreview: isPreview)
        }
    }

    func dismissAll() {
        takeoverQueue.removeAll()
        subtleQueue.removeAll()
        subtleDismissTask?.cancel()
        subtleDismissTask = nil
        takeover = nil
        subtleCard = nil
    }

    // MARK: - Critical takeover

    private func showTakeover(_ reminder: Reminder, isPreview: Bool) {
        if let current = takeover {
            if isPreview {
                takeover = nil
            } else if current.reminder.id == reminder.id {
                // Already on screen for this reminder (an alarm and a tick can
                // race to present the same fire); nothing to add.
                return
            } else {
                takeoverQueue.append((reminder, Date()))
                return
            }
        }
        takeover = TakeoverItem(reminder: reminder, isPreview: isPreview)
    }

    /// Presents the takeover because the user tapped an alarm's "Open" button.
    /// They explicitly asked to see it, so it replaces whatever is up.
    func presentAlarmTakeover(reminderID: UUID) {
        guard let reminder = engine.reminder(withID: reminderID) else { return }
        alarms.stopIfAlerting(reminderID)
        takeover = TakeoverItem(reminder: reminder, isPreview: false)
    }

    /// A takeover left unacknowledged when the app leaves the foreground
    /// would otherwise exist only inside a suspended process — and not at all
    /// if iOS ends that process. Hand the occurrence to the lock screen as a
    /// time-sensitive notification, whose buttons feed the same engine.
    private func handOffUnacknowledgedTakeover() {
        guard let takeover, !takeover.isPreview, handedOffTakeoverID != takeover.id else { return }
        handedOffTakeoverID = takeover.id
        notifications.postImmediate(takeover.reminder, settings: engine.settings)
    }

    enum TakeoverAction {
        case complete
        case snooze
    }

    func acknowledgeTakeover(_ item: TakeoverItem, action: TakeoverAction) {
        if !item.isPreview {
            switch action {
            case .complete: engine.complete(id: item.reminder.id)
            case .snooze: engine.snooze(id: item.reminder.id)
            }
            alarms.stopIfAlerting(item.reminder.id)
        }
        advanceTakeoverQueue(afterAcknowledging: item.reminder.id)
        setNeedsReschedule()
    }

    /// Closes the takeover and shows the next queued one that is still fresh.
    /// Stale entries are dropped and recorded as missed — acknowledging one
    /// overlay after falling asleep must not hand the user the next, and the
    /// next. Policy lives in `ReminderEngine.shouldPresentQueued`.
    private func advanceTakeoverQueue(afterAcknowledging acknowledgedID: UUID) {
        let now = Date()
        var dropped: [Reminder] = []
        takeoverQueue.removeAll { entry in
            let keep = ReminderEngine.shouldPresentQueued(
                reminderID: entry.reminder.id,
                queuedAt: entry.queuedAt,
                acknowledgedID: acknowledgedID,
                now: now
            )
            if !keep { dropped.append(entry.reminder) }
            return !keep
        }
        engine.recordMissedPresentations(dropped)

        takeover = nil
        if !takeoverQueue.isEmpty {
            let next = takeoverQueue.removeFirst()
            takeover = TakeoverItem(reminder: next.reminder, isPreview: false)
        }
    }

    // MARK: - Subtle card

    private func showSubtle(
        _ reminder: Reminder, settings: ReminderCore.Settings, isPreview: Bool
    ) {
        if subtleCard != nil {
            if isPreview {
                closeSubtleCard()
            } else {
                subtleQueue.append(reminder)
                return
            }
        }
        displaySubtle(reminder, settings: settings, isPreview: isPreview)
    }

    private func displaySubtle(
        _ reminder: Reminder, settings: ReminderCore.Settings, isPreview: Bool
    ) {
        let seconds = max(2, reminder.displaySeconds ?? settings.subtleDisplaySeconds)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            subtleCard = SubtleCardItem(
                reminder: reminder, dismissAfterSeconds: seconds, isPreview: isPreview
            )
        }
        subtleDismissTask?.cancel()
        subtleDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismissSubtleAndAdvance()
        }
    }

    /// The user tapped the card's checkmark (`completed`) or it timed out.
    func acknowledgeSubtle(completed: Bool) {
        if let card = subtleCard, completed, !card.isPreview {
            engine.complete(id: card.reminder.id)
            setNeedsReschedule()
        }
        dismissSubtleAndAdvance()
    }

    private func dismissSubtleAndAdvance() {
        closeSubtleCard()
        if !subtleQueue.isEmpty {
            let next = subtleQueue.removeFirst()
            displaySubtle(next, settings: engine.settings, isPreview: false)
        }
    }

    private func closeSubtleCard() {
        subtleDismissTask?.cancel()
        subtleDismissTask = nil
        withAnimation(.easeOut(duration: 0.2)) {
            subtleCard = nil
        }
    }

    // MARK: - Notification responses

    /// Routes a tapped notification action back to the engine, mirroring the
    /// macOS `NotificationPresenter` mapping, and returns once the follow-up
    /// schedule is armed (the response may have launched the app in the
    /// background, where nothing runs after the handler returns).
    func handleNotificationResponse(
        reminderID: UUID, action: NotificationScheduler.ResponseAction
    ) async {
        switch action {
        case .complete: engine.complete(id: reminderID)
        case .snooze: engine.snooze(id: reminderID)
        case .dismiss: engine.dismiss(id: reminderID)
        }
        // Acting on the lock-screen copy of an unacknowledged takeover
        // answers the takeover too.
        if action != .dismiss, let takeover, !takeover.isPreview,
           takeover.reminder.id == reminderID {
            alarms.stopIfAlerting(reminderID)
            advanceTakeoverQueue(afterAcknowledging: reminderID)
        }
        await rescheduleEverything()
    }

    // MARK: - Alarm callbacks (from App Intents and alarmUpdates)

    /// The system alarm's Stop button: the user said "done" without opening
    /// the app. The fire is recorded first so history and adherence see it.
    /// Returns once the next occurrence is armed — the intent runs in a
    /// background launch that can be suspended the moment it returns.
    func handleAlarmStopped(reminderID: UUID) async {
        if let fire = alarms.expectedFire(for: reminderID) {
            engine.recordExternalFire(
                id: reminderID, at: fire.stampDate, deliveredAt: fire.fireDate
            )
        }
        engine.complete(id: reminderID)
        await rescheduleEverything()
    }

    /// The system alarm's "Open" button.
    func handleAlarmOpened(reminderID: UUID) {
        if let fire = alarms.expectedFire(for: reminderID) {
            engine.recordExternalFire(
                id: reminderID, at: fire.stampDate, deliveredAt: fire.fireDate
            )
        }
        presentAlarmTakeover(reminderID: reminderID)
    }

    /// An alarm started alerting while the app is frontmost: silence the
    /// system alert and show the real takeover instead.
    func handleAlarmAlerting(reminderID: UUID) {
        guard isActive else { return }
        guard let reminder = engine.reminder(withID: reminderID) else { return }
        alarms.stopIfAlerting(reminderID)
        // The tick will stamp and present it within seconds; presenting here
        // just avoids a blank gap. Dedupe happens in showTakeover.
        engine.tick()
        if takeover?.reminder.id != reminder.id {
            showTakeover(reminder, isPreview: false)
        }
    }

    // MARK: - Background refresh

    static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundRefreshIdentifier, using: nil
        ) { task in
            let completion = OnceFlag()
            // The next request is submitted before any work, so an overrun
            // can neither throttle future refreshes nor break the chain.
            let work = Task { @MainActor in
                let model = AppModel.shared
                model.scheduleBackgroundRefresh()
                await model.reconcile()
                if completion.claim() { task.setTaskCompleted(success: true) }
            }
            task.expirationHandler = {
                work.cancel()
                if completion.claim() { task.setTaskCompleted(success: false) }
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Keeps the app alive long enough to finish a scheduling pass once it has
/// left the foreground. iOS grants a short window on request; without asking,
/// the process can be suspended mid-pass with half the schedule missing.
@MainActor
private final class BackgroundAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: release the assertion rather than be killed. The
            // pass that was running will be redone at the next foreground.
            Task { @MainActor [weak self] in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// A claim that exactly one of several racing parties wins.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
