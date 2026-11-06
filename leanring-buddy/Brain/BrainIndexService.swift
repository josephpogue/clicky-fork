//
//  BrainIndexService.swift
//  leanring-buddy
//
//  Keeps the brain index for the search folders in Settings and answers the question flow's passage lookups.
//  Owned by the app-brain-settings slice. With no folders listed the brain is off: nothing is read, no helper starts.
//

import ClickyCore
import Foundation

final class BrainIndexService: @unchecked Sendable {
    static let shared = BrainIndexService()

    /// Guards every field below; never held across the index work or an await.
    private let lock = NSLock()
    private var coalescer = BrainServiceRefreshCoalescer()
    private var waitersByRun: [(run: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isBrainOnCopy = false
    private var index: BrainIndex?
    private var lastSummary: BrainIndexUpdateSummary?
    private var firstUnreadableFolderPath: String?
    private var cachedProjectNames: [String]?
    private var currentSearchFolderPaths: [String] = []
    /// The folders the last COMPLETED update covered (written to `folders.json` so the helper can say a folder is still
    /// being indexed). Nil until the first write reads it back from the file.
    private var indexedFolderPaths: [String]?
    /// False after the folder list file could not be written (twice) and the stale file could not be trusted:
    /// passages stop being attached until a write succeeds, because the helper can no longer follow the list.
    private var folderListFileIsCurrent = true
    /// The folders the Claude helper was launched with at the last `toolServer()`. A passage is attached only for a
    /// folder in this list AND in Settings now, the same rule the helper applies to `read_brain_file`. Nil while no
    /// helper was launched (ChatGPT has none): the current list alone.
    private var helperLaunchFolders: [URL]?

    /// Index updates run here, on one dedicated thread, never on Swift's cooperative pool: an update is minutes of
    /// synchronous SQLite and file work for a big folder, and blocking pool threads that long starves every other
    /// task in the app (timers, streaming) as well as the tests that share the process.
    private let indexUpdateQueue = DispatchQueue(label: "clicky.brain-index-update", qos: .utility)

    /// Called on the main actor each time the status line changes, so Settings shows it live.
    @MainActor var onStatusChange: ((BrainServiceStatus?) -> Void)?

    /// True when Settings lists at least one search folder. A lock-guarded copy, updated on the main actor whenever the
    /// list is read, so any thread may ask.
    var isBrainOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isBrainOnCopy
    }

    /// The status line for the current state; nil when there are no folders.
    var currentStatus: BrainServiceStatus? {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked()
    }

    /// Builds or refreshes the index off the main thread: at launch, at session Start and when the folder list changes.
    func refreshInBackground() {
        Task { @MainActor in
            _ = self.requestRefreshOnMain()
        }
    }

    /// The same, started synchronously from the main actor (Settings calls it right after the list changes).
    @MainActor
    func folderListDidChange() {
        _ = requestRefreshOnMain()
    }

    /// Brings the index up to date at session Start (by modification time, well under a second when little changed).
    /// Start waits for it at most `BrainServiceStartWait.defaultSeconds`: a first build of a big folder keeps running
    /// and later questions use what it has written (their passages are filtered by the current folder list, so a
    /// stale index never shows a removed folder). Never throws, never hangs; a failed refresh only leaves the old index.
    func refreshForSessionStart() async {
        let run = await MainActor.run { self.requestRefreshOnMain() }
        await BrainServiceStartWait.waitUntilDone { [self] in
            await waitForCompletion(of: run)
        }
    }

    /// The passages for one question; empty while the brain is off or nothing clears the floor.
    func passages(forQuestion question: String, frontAppName: String?, frontWindowTitle: String?) async -> [BrainPassage] {
        guard isBrainOn, isFolderListFileCurrent() else { return [] }
        let projectNames = await projectNamesForPassages()
        return await Task.detached(priority: .userInitiated) { [self] () -> [BrainPassage] in
            guard let index = openIndex() else { return [] }
            // The list as Settings has it right now, read at question time: a folder removed a moment ago is out
            // even while a build still holds its rows. A folder added since the helper started is out too, because
            // the helper refuses to read it (a passage the model cannot open is worse than none).
            let currentSearchFolders = foldersTheSessionMayUse()
            do {
                return try index.passages(
                    forQuestion: question, frontAppName: frontAppName, frontWindowTitle: frontWindowTitle,
                    projectNames: projectNames, searchFolders: currentSearchFolders)
            } catch {
                return []
            }
        }.value
    }

    /// How a provider starts the helper; nil while the brain is off or the helper is missing from the bundle.
    func toolServer() -> BrainToolServer? {
        let folderPaths = lockedFolderPaths()
        guard !folderPaths.isEmpty,
              let helperFolder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let helperURL = helperFolder.appendingPathComponent("ClickyBrainTools", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return nil }
        let searchFolders = BrainServiceFolders.expand(paths: folderPaths)
        lock.lock()
        helperLaunchFolders = searchFolders
        lock.unlock()
        return BrainToolServer(
            executableURL: helperURL,
            arguments: BrainToolServer.helperArguments(
                indexDatabaseURL: AppDataLocations.standard().brainIndexDatabaseURL, searchFolders: searchFolders))
    }

    /// Called when a session starts with a provider that has no helper (ChatGPT): its passages follow the current list.
    func forgetHelperLaunchFolders() {
        lock.lock()
        helperLaunchFolders = nil
        lock.unlock()
    }

    /// The current Settings list, narrowed to the folders the running helper was launched with when there is one.
    private func foldersTheSessionMayUse() -> [URL] {
        let currentSearchFolders = BrainServiceFolders.expand(paths: lockedFolderPaths())
        lock.lock()
        let launchFolders = helperLaunchFolders
        lock.unlock()
        guard let launchFolders else { return currentSearchFolders }
        return BrainServiceFolderListFile.foldersInBoth(startList: launchFolders, currentList: currentSearchFolders)
    }

    private func isFolderListFileCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return folderListFileIsCurrent
    }

    /// The maps the instructions name: the knowledge base index under the notes folder and any indexed `registry.md`.
    func mapPaths() async -> [String] {
        guard isBrainOn else { return [] }
        let (folderPaths, notesFolder) = await MainActor.run { () -> ([String], URL?) in
            (AppSettings.shared.brainSearchFolderPaths, Self.notesFolderURL())
        }
        return await Task.detached(priority: .userInitiated) { [self] () -> [String] in
            let currentSearchFolders = BrainServiceFolders.expand(paths: lockedFolderPaths())
            let fileReader = BrainFileReader(searchFolders: currentSearchFolders)
            // A registry of a folder removed in Settings is not named, even while its row is still indexed.
            let registryPaths = ((try? openIndex()?.indexedFiles(named: "registry.md")) ?? []).filter {
                (try? fileReader.resolveReadableFile($0)) != nil
            }
            return BrainServiceMapPaths.make(
                notesFolder: notesFolder, searchFolders: BrainServiceFolders.expand(paths: folderPaths),
                registryPaths: registryPaths)
        }.value
    }

    // MARK: - Refresh

    /// Reads the folder list, then starts a run, joins one or queues one. Returns the run that covers this list.
    @MainActor
    private func requestRefreshOnMain() -> Int {
        let folderPaths = AppSettings.shared.brainSearchFolderPaths
        lock.lock()
        isBrainOnCopy = !folderPaths.isEmpty
        currentSearchFolderPaths = folderPaths
        let request = coalescer.request(folders: folderPaths)
        lock.unlock()
        // Before any build starts or queues, so a removal reaches a running session's helper at once.
        writeFolderListFile(folderPaths: folderPaths)
        publishStatus()
        if request.shouldStartNow { startRun(folderPaths: folderPaths) }
        return request.run
    }

    /// `<data>/brain-index/folders.json`: the current list and the folders the last completed update covered, for the
    /// helper to re-read on every tool call. Written at every list change, every refresh and every finished update.
    /// With the brain off and no index folder yet, nothing is created. A write that fails is retried once; when it
    /// still fails the stale file is removed (the helper then uses its launch list) and no passages are attached
    /// until a write succeeds.
    private func writeFolderListFile(folderPaths: [String]) {
        let databaseURL = AppDataLocations.standard().brainIndexDatabaseURL
        let listFileURL = BrainServiceFolderListFile.url(besideIndexDatabase: databaseURL)
        if folderPaths.isEmpty,
           !FileManager.default.fileExists(atPath: databaseURL.deletingLastPathComponent().path) { return }
        let indexedFolders = indexedFoldersForListFile(listFileURL: listFileURL, databaseURL: databaseURL)
        let succeeded = BrainServiceFolderListFile.writeRetryingOnce(
            folders: BrainServiceFolders.expand(paths: folderPaths), indexedFolders: indexedFolders, to: listFileURL,
            log: { NSLog("%@", $0) })
        lock.lock()
        folderListFileIsCurrent = succeeded
        lock.unlock()
    }

    /// What the last completed update covered. In this launch it is remembered; before the first update of this
    /// launch it is read back from the file (a bare list from the first wave counts as covered, as that service
    /// indexed what it listed), and with no index database on disk nothing is covered.
    private func indexedFoldersForListFile(listFileURL: URL, databaseURL: URL) -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        if indexedFolderPaths == nil {
            if FileManager.default.fileExists(atPath: databaseURL.path),
               let listing = BrainServiceFolderListFile.readListing(from: listFileURL) {
                indexedFolderPaths = listing.indexedFolders ?? listing.folders
            } else {
                indexedFolderPaths = []
            }
        }
        return (indexedFolderPaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    private func startRun(folderPaths: [String]) {
        Task.detached(priority: .utility) { [self] in
            var folderPathsToRun = folderPaths
            while true {
                let outcome = await runIndexUpdateOnItsOwnThread(folderPaths: folderPathsToRun)
                lock.lock()
                if let outcome {
                    lastSummary = outcome.summary
                    firstUnreadableFolderPath = outcome.firstUnreadableFolderPath
                    cachedProjectNames = nil
                    indexedFolderPaths = outcome.coveredFolderPaths
                }
                let folderPathsNow = currentSearchFolderPaths
                let nextRun = coalescer.finishRun()
                let finishedWaiters = waitersByRun.filter { coalescer.hasCompleted(run: $0.run) }
                waitersByRun.removeAll { coalescer.hasCompleted(run: $0.run) }
                lock.unlock()
                // The update is committed: tell the helper which folders it now covers, before any waiter is released.
                if outcome != nil { writeFolderListFile(folderPaths: folderPathsNow) }
                for waiter in finishedWaiters { waiter.continuation.resume() }
                await publishStatusOnMain()
                guard let nextRun else { return }
                folderPathsToRun = nextRun.folders
            }
        }
    }

    private struct RunOutcome {
        var summary: BrainIndexUpdateSummary
        var firstUnreadableFolderPath: String?
        /// Every folder of the run's list (an unreadable one is named in the status line, not claimed as pending).
        var coveredFolderPaths: [String]
    }

    private func runIndexUpdateOnItsOwnThread(folderPaths: [String]) async -> RunOutcome? {
        await withCheckedContinuation { (continuation: CheckedContinuation<RunOutcome?, Never>) in
            indexUpdateQueue.async { [self] in
                continuation.resume(returning: runIndexUpdate(folderPaths: folderPaths))
            }
        }
    }

    /// One index update. Never throws: on error the old index stays and the old status stays. An empty list empties
    /// the index (a folder that is gone from the list must not stay searchable).
    private func runIndexUpdate(folderPaths: [String]) -> RunOutcome? {
        // Brain off and no index file on disk: nothing to empty, and no file is created.
        if folderPaths.isEmpty,
           !FileManager.default.fileExists(atPath: AppDataLocations.standard().brainIndexDatabaseURL.path) {
            return nil
        }
        guard let index = openIndex() else { return nil }
        let folders = BrainServiceFolders.expand(paths: folderPaths)
        let unreadable = BrainServiceFolders.firstUnreadable(folders)
        do {
            let summary = try index.update(searchFolders: BrainServiceFolders.readable(folders))
            return RunOutcome(
                summary: summary, firstUnreadableFolderPath: unreadable?.path, coveredFolderPaths: folders.map(\.path))
        } catch {
            return nil
        }
    }

    private func waitForCompletion(of run: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if coalescer.hasCompleted(run: run) {
                lock.unlock()
                continuation.resume()
            } else {
                waitersByRun.append((run, continuation))
                lock.unlock()
            }
        }
    }

    // MARK: - Index and status

    private func openIndex() -> BrainIndex? {
        lock.lock()
        defer { lock.unlock() }
        if let index { return index }
        let databaseURL = AppDataLocations.standard().brainIndexDatabaseURL
        try? FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        index = try? BrainIndex(databaseURL: databaseURL)
        return index
    }

    private func lockedFolderPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return currentSearchFolderPaths
    }

    /// Project page names of the notes folder Save uses, cached until the next refresh.
    private func projectNamesForPassages() async -> [String] {
        lock.lock()
        let cached = cachedProjectNames
        lock.unlock()
        if let cached { return cached }
        let notesFolder = await MainActor.run { Self.notesFolderURL() }
        let names = await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let notesFolder else { return [] }
            return VaultProjects.list(vaultRoot: notesFolder)
        }.value
        lock.lock()
        cachedProjectNames = names
        lock.unlock()
        return names
    }

    /// The notes folder Save really uses (CLICKY_VAULT_ROOT wins over the Settings choice).
    @MainActor
    private static func notesFolderURL() -> URL? {
        VaultRootResolver.resolve(
            notesFolderSetting: AppSettings.shared.notesFolderPath, environment: ProcessInfo.processInfo.environment)
    }

    /// Caller holds the lock.
    private func statusLocked() -> BrainServiceStatus? {
        BrainServiceStatus.make(
            hasFolders: !currentSearchFolderPaths.isEmpty,
            isRefreshing: coalescer.runningFolders != nil,
            lastSummary: lastSummary,
            firstUnreadableFolderPath: firstUnreadableFolderPath,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    @MainActor
    private func publishStatus() {
        onStatusChange?(currentStatus)
    }

    private func publishStatusOnMain() async {
        await MainActor.run { self.publishStatus() }
    }
}
