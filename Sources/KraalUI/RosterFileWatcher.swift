// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 zzjcool
//
// Watches the saved-machine roster on disk (issue #69).
//
// `endpoints.json` is shared by every herdr process on the account, so "somebody
// else changed it" is the normal case, not an edge case: another terminal, a
// second Kraal window, `herdr update` rewriting the file. Watching it is the only
// way the sidebar can notice without the user reopening Settings.
//
// A plain kqueue watch on one path is not enough, for two reasons that are each a
// classic bug in this kind of code:
//
//  1. **An atomic write replaces the inode.** herdr does not edit the file in
//     place: `store_to_path` writes `.endpoints-<pid>-<n>.tmp` and `rename(2)`s it
//     over the original (`src/client/endpoint/catalog.rs:349-370`). After the
//     rename the descriptor we hold refers to a file with no name left; it reports
//     the rename once and then never again. Measured here: watching the old fd
//     across four `rename(2)` replacements reported exactly one event, while
//     re-opening after each event reported all of them. So the file arm is
//     re-opened and re-mounted after every event.
//  2. **The file may not exist yet.** A fresh account has no
//     `~/.local/state/herdr/client/`, and `open(2)` on a missing path cannot be
//     watched at all. So the directory is watched as well, and when the directory
//     is missing too, the nearest existing ancestor is watched instead; the arms
//     are recomputed after each event, so the watch walks down as the directories
//     appear.
//
// Both arms stay mounted in the steady state: the file arm catches an in-place
// rewrite (a hand-edited roster), the directory arm catches creation,
// rename-into-place and deletion. Watching the directory also covers
// `endpoint-selection.json`, which herdr stores next to the roster and which
// decides the `selected` flag `machine list --json` reports.
//
// Every event is debounced, because one write produces several (measured: three
// per atomic replacement).
//
// Not tied to the roster: it takes a path and a callback, so it can be tested
// without herdr, a daemon, or an app. Losing an event while re-arming costs one
// notification, never a stale result — the reload the notification schedules
// reads the file itself.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reports that one path changed, and keeps reporting after the file is replaced.
final class RosterFileWatcher: @unchecked Sendable {
    private let path: String
    /// The directory holding `path`; the arm to use when the file does not exist.
    private let directory: String
    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "kraal.roster-file-watch")
    private let onChange: @Sendable () -> Void

    /// Guards everything below. Events arrive on `queue`; `stop()` arrives on
    /// whichever thread is tearing the owner down, and `deinit` on whichever one
    /// drops the last reference.
    private let lock = NSLock()
    private var stopped = false
    private var started = false
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    /// Whether the directory arm has ever reached the real directory. Until it
    /// has, we are watching some ancestor and every event there is noise from
    /// unrelated files (`$HOME` is busy), so notifications are held back.
    private var descended = false
    /// The debounced notification waiting to run, if any.
    private var pending: DispatchWorkItem?

    init(path: String, debounce: TimeInterval = 0.25, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.directory = (path as NSString).deletingLastPathComponent
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Whether the file arm is currently mounted. Exposed so the "the file did not
    /// exist yet, then it did" case can be asserted instead of inferred.
    var isWatchingFile: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileSource != nil
    }

    /// The path the directory arm watches right now — the real directory, or an
    /// ancestor while the tree is still being created.
    var watchedDirectory: String {
        lock.lock()
        defer { lock.unlock() }
        return nearestExistingAncestor(directory)
    }

    /// Arms both watches. Idempotent: a second call does nothing, so an owner can
    /// call it from a retry path without leaking descriptors.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !started else { return }
        started = true
        rearmLocked()
    }

    /// Cancels the watches and any pending notification. Safe to call twice, and
    /// from `deinit`.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let sources = [fileSource, directorySource].compactMap { $0 }
        fileSource = nil
        directorySource = nil
        let work = pending
        pending = nil
        lock.unlock()

        work?.cancel()
        // The cancel handlers close the descriptors, on `queue`, after whatever
        // handler is running returns.
        for source in sources {
            source.cancel()
        }
    }

    // MARK: - Arming

    /// Mounts one arm on its current best path, or returns nil when even the
    /// fallback cannot be opened.
    ///
    /// `O_EVTONLY` asks for an event-only descriptor: it does not consume the
    /// process's read descriptors, and it needs no read permission on the file.
    /// It is Darwin-only, so other platforms fall back to a plain descriptor.
    private func arm(_ target: Arm) -> DispatchSourceFileSystemObject? {
        let path = target == .file ? self.path : nearestExistingAncestor(directory)
        #if canImport(Darwin)
        let descriptor = open(path, O_EVTONLY)
        #else
        let descriptor = open(path, O_RDONLY)
        #endif
        guard descriptor >= 0 else { return nil }
        // `.write` covers an in-place rewrite and an entry appearing in a watched
        // directory; `.delete` and `.rename` are what an atomic replacement looks
        // like from the old inode's side; `.extend` catches an append.
        let mask: DispatchSource.FileSystemEvent = target == .file
            ? [.write, .delete, .rename, .extend]
            : [.write, .delete, .rename]
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: mask,
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.fired() }
        // Closing here rather than in `stop()` ties the descriptor's lifetime to the
        // source's, which is the pairing libdispatch expects, and means the close
        // happens even if the owner is already gone.
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    private enum Arm {
        case file
        case directory
    }

    /// Recomputes both arms. Called with `lock` held.
    ///
    /// Both, every time, and unconditionally. The file arm has to be re-opened
    /// after a `.rename`/`.delete` because the descriptor now points at an
    /// unlinked inode (trap 1 in the file header); the directory arm has to be
    /// re-opened because the file may have appeared while the file arm could not
    /// be mounted, and because the watched directory can itself be replaced.
    private func rearmLocked() {
        fileSource?.cancel()
        fileSource = arm(.file)
        directorySource?.cancel()
        directorySource = arm(.directory)
        // Assigned, not latched: if the directory is removed (herdr's state tree
        // wiped and rebuilt) the watch climbs to an ancestor again, and the
        // notifications it would produce from there are unrelated files. Tracking
        // the current state instead of remembering that it once descended keeps
        // those out.
        descended = nearestExistingAncestor(directory) == directory
    }

    /// The closest ancestor of `path` that exists, or `path` itself when it does.
    ///
    /// `open(2)` fails on a missing directory, and a fresh account has no
    /// `~/.local/state/herdr/client/` yet. Watching the nearest existing parent
    /// gives that case an event at all; the re-arm in `fired` then walks down.
    /// One call jumps the whole remaining depth, so a `mkdir -p` burst that skips
    /// several levels still lands on the real directory.
    private func nearestExistingAncestor(_ path: String) -> String {
        var candidate = path
        while !FileManager.default.fileExists(atPath: candidate) {
            let parent = (candidate as NSString).deletingLastPathComponent
            // `deletingLastPathComponent` on "/" returns "/", so this terminates
            // even for a path that does not exist anywhere.
            if parent.isEmpty || parent == candidate { return candidate }
            candidate = parent
        }
        return candidate
    }

    // MARK: - Events

    private func fired() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        // Re-arm before scheduling. After a `.delete`/`.rename` the descriptor we
        // were just woken for is already useless, and waiting for the debounce to
        // rebuild it would drop every event in between.
        rearmLocked()
        let work = makeWorkItemLocked()
        lock.unlock()
        if let work {
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
    }

    /// How many times a not-yet-descended watch retries before giving up on one
    /// event.
    ///
    /// Needed because the descent can outrun its own notification: `mkdir -p a/b/c`
    /// produces one event on `a`'s parent and nothing more from a watch that is
    /// still mounted three levels up, since `b` and `c` appeared in the same tick.
    /// Each retry re-reads the nearest existing ancestor, so the watch walks down
    /// on its own instead of waiting for an event that will never come. Bounded so
    /// a path that never appears cannot keep the queue busy forever.
    private static let descentRetries = 8

    /// Replaces any waiting notification, so a burst of events produces one call.
    /// Called with `lock` held.
    private func makeWorkItemLocked(retry: Int = 0) -> DispatchWorkItem? {
        guard !stopped else { return nil }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            self.pending = nil
            // Re-arm once more, now that the burst has settled. This is what makes
            // the descent converge: an event on an ancestor may have arrived while
            // only part of the tree existed.
            self.rearmLocked()
            if !self.descended, retry < Self.descentRetries {
                let next = self.makeWorkItemLocked(retry: retry + 1)
                self.lock.unlock()
                if let next {
                    self.queue.asyncAfter(deadline: .now() + self.debounce, execute: next)
                }
                return
            }
            let report = self.descended
            self.lock.unlock()
            guard report else { return }
            self.onChange()
        }
        pending = work
        return work
    }
}
