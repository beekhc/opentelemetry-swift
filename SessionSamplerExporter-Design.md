# SessionSamplerExporter Design

## Overview

The **SessionSamplerExporter** is a session-aware exporter that selectively exports telemetry data based on whether a session should be kept or dropped. It integrates with the existing `SessionManager` and only exports data for sessions where `keepSession()` was called.

## Key Features

- **Immediate export on keepSession()**: Data starts exporting as soon as you decide to keep a session, not when the session ends
- **Session-based sampling**: Only export telemetry for sessions you care about
- **Automatic cleanup**: Sessions not marked as kept are deleted, saving storage space
- **Integrates with existing SessionManager**: Works seamlessly with OpenTelemetry's session infrastructure

## Use Cases

- **Error-driven sampling**: Only keep telemetry for sessions where an error occurred
- **Performance sampling**: Keep sessions that exceeded performance thresholds
- **User-initiated reporting**: Keep sessions where the user reported a problem
- **Conditional debugging**: Keep sessions based on runtime conditions
- **Privacy-preserving telemetry**: Users can opt-in to share specific sessions

## Requirements

1. Wrap/configure PersistenceExporter
2. Integrate with existing SessionManager
3. Prevent data export until session finishes
4. Provide `keepSession()` method to mark sessions for export
5. Export cached telemetry only for kept sessions
6. Drop telemetry for sessions not marked as kept
7. Support all signal types (spans, logs, metrics)

## Integration with Existing Session Infrastructure

### Existing Components

The project already has:

1. **SessionManager** (`Sources/Instrumentation/Sessions/SessionManager.swift`):
   - `getSession()` - Returns current session, creates or extends as needed
   - `peekSession()` - Returns current session without extending
   - Automatically manages session expiration and renewal
   - Persists sessions to UserDefaults

2. **Session** (`Sources/Instrumentation/Sessions/Session.swift`):
   - `id: String` - Unique session identifier
   - `startTime: Date` - When session started
   - `expireTime: Date` - When session expires
   - `previousId: String?` - Previous session ID
   - `isExpired() -> Bool` - Check if expired
   - `endTime: Date?` - Calculated end time for expired sessions
   - `duration: TimeInterval?` - Session duration

3. **SessionEventNotification** (`Sources/Instrumentation/Sessions/SessionConstants.swift`):
   - Posted when a new session starts
   - Contains the new Session as the notification object
   - Previous session end is handled via `SessionEventInstrumentation.addSession(session:eventType:)`

4. **SessionEventInstrumentation** (`Sources/Instrumentation/Sessions/SessionEventInstrumentation.swift`):
   - `addSession(session:eventType:)` - Called for .start and .end events
   - Creates log records for session lifecycle events

### How SessionSamplerExporter Integrates

The SessionSamplerExporter will:

1. **Subscribe to session events** via:
   - Listen to `SessionEventNotification` for new session starts
   - Monitor SessionEventInstrumentation for session ends (via custom callback mechanism)

2. **Track session state**:
   - Current session ID from notification
   - Keep/drop flag per session
   - Per-session PersistenceExporter instances

3. **Detect session transitions**:
   - When SessionEventNotification fires → new session starting
   - Previous session has ended (can be determined from notification payload)
   - Export or drop previous session's data based on keep flag

## Architecture

### Design Approach: Per-Session Storage Directories

Each session gets its own PersistenceExporter with a dedicated storage directory. This provides:

- **Clean isolation**: Each session's data is completely separate
- **Simple lifecycle**: Use existing PersistenceExporter flush() and directory deletion
- **No timestamp parsing**: Don't need to figure out which files belong to which session
- **Atomic operations**: Can delete or export entire sessions at once

```
Storage Structure:
/Library/Caches/
└── <base-storage-path>/
    ├── session-abc123/
    │   ├── 123456789000
    │   ├── 123456790000
    │   └── 123456791000
    ├── session-def456/
    │   ├── 123456792000
    │   └── 123456793000
    └── session-ghi789/
        └── 123456794000
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│  OpenTelemetry SDK                                      │
└────────────────┬────────────────────────────────────────┘
                 │
                 │ export(spans/logs/metrics)
                 ▼
┌─────────────────────────────────────────────────────────┐
│  SessionSamplerExporter                                 │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │  Session Tracking                          │        │
│  │  - Current session ID                      │        │
│  │  - Keep/drop flag per session              │        │
│  │  - SessionEventNotification listener       │        │
│  └────────────────────────────────────────────┘        │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │  PersistenceExporter (per session)         │        │
│  │  - Session-specific storage directory      │        │
│  │  - exportCondition: check if kept          │        │
│  │  - Auto-exports when keepSession() called  │        │
│  └────────────────────────────────────────────┘        │
└─────────────────┬───────────────────────────────────────┘
                  │
                  │ export (only for kept sessions)
                  ▼
┌─────────────────────────────────────────────────────────┐
│  Wrapped Exporter (OTLP, Zipkin, etc.)                  │
└─────────────────────────────────────────────────────────┘

         ┌─────────────────────────┐
         │  SessionManager         │
         │  (existing)             │
         │  - getSession()         │
         │  - peekSession()        │
         └───────┬─────────────────┘
                 │
                 │ SessionEventNotification
                 ▼
         SessionSamplerExporter
```

### Session Lifecycle Flow

```
1. App starts → SessionManager initialized

2. First telemetry arrives:
   ├─> SessionSamplerExporter.export() called
   ├─> Check current session (via SessionManager.peekSession())
   ├─> Create PersistenceExporter for this session if doesn't exist
   └─> Write telemetry to session-specific storage

3. keepSession() called (e.g., error occurs, user reports problem, performance threshold exceeded):
   ├─> App calls sessionSamplerExporter.keepSession()
   ├─> Adds session ID to keptSessionIds set
   ├─> PersistenceExporter's exportCondition now returns true
   ├─> DataExportWorker begins automatic export cycle
   └─> Data starts exporting to server immediately

4. Session expires (user inactive):
   ├─> SessionManager.getSession() detects expiration
   ├─> SessionEventInstrumentation.addSession(previousSession, .end) called
   ├─> SessionEventNotification posted with new session
   ├─> SessionSamplerExporter receives notification
   ├─> Previous session ID extracted
   ├─> Check if previous session was kept
   ├─> If kept: flush PersistenceExporter → export any remaining data
   └─> If not kept: delete session directory → drop data

5. New session begins:
   ├─> New session has its own ID (not in keptSessionIds)
   ├─> Next telemetry creates new PersistenceExporter for new session
   ├─> New session's data is not exported (unless keepSession() is called)
   └─> Cycle repeats
```

## Implementation Design

**Note**: Each SessionSamplerExporter directly wraps the corresponding public `Persistence*ExporterDecorator` class. There is no generic core - instead, three separate implementations that share the same pattern.

### Implementation Pattern (Shared by all three exporters)

Each exporter follows this pattern:

```swift
import Foundation
import OpenTelemetrySdk
import Sessions
import PersistenceExporter

public class SessionSampler[Span|Log|Metric]Exporter: [Span|LogRecord|Metric]Exporter {

    // MARK: - Dependencies

    /// The actual exporter to send data to
    private let wrappedExporter: [Span|LogRecord|Metric]Exporter

    /// Session manager for tracking current session
    private let sessionManager: SessionManager

    /// Base directory for all session storage
    private let baseStorageURL: URL

    /// Performance preset for PersistenceExporter
    private let performancePreset: PersistencePerformancePreset

    // MARK: - Session State

    /// Lock for thread-safe access to session state
    private let lock = NSRecursiveLock()

    /// Map of session ID to its Persistence*ExporterDecorator
    private var sessionExporters: [String: Persistence[Span|Log|Metric]ExporterDecorator] = [:]

    /// Set of session IDs that should be kept (exported)
    private var keptSessionIds: Set<String> = []

    /// Notification observer for session events
    private var sessionObserver: NSObjectProtocol?

    /// Set of session IDs that have already been processed (exported or dropped)
    private var processedSessionIds: Set<String> = []

    // MARK: - Initialization

    public init(
        [span|log|metric]Exporter: [Span|LogRecord|Metric]Exporter,
        sessionManager: SessionManager = SessionManagerProvider.getInstance(),
        baseStorageURL: URL,
        performancePreset: PersistencePerformancePreset = .default
    ) {
        self.wrappedExporter = [span|log|metric]Exporter
        self.sessionManager = sessionManager
        self.baseStorageURL = baseStorageURL
        self.performancePreset = performancePreset

        // Ensure base directory exists
        try? FileManager.default.createDirectory(
            at: baseStorageURL,
            withIntermediateDirectories: true
        )

        // Register for session change notifications
        sessionObserver = NotificationCenter.default.addObserver(
            forName: SessionEventNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let newSession = notification.object as? Session else { return }
            self?.handleSessionTransition(newSession: newSession)
        }
    }

    deinit {
        if let observer = sessionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Mark the current session to be kept and start exporting data immediately.
    /// Once called, the PersistenceExporter begins automatic export cycle.
    /// This method is thread-safe and can be called multiple times per session.
    func keepSession() {
        lock.lock()
        defer { lock.unlock() }

        if let currentSession = sessionManager.peekSession() {
            keptSessionIds.insert(currentSession.id)
            // Note: PersistenceExporter's exportCondition closure will now return true
            // for this session, enabling automatic export
        }
    }

    /// Export [spans|logs|metrics] to the current session's persistence layer.
    /// Creates a new session exporter if needed.
    /// Implements the [Span|LogRecord|Metric]Exporter protocol.
    public func export([spans|logRecords|metrics]: [[SpanData|ReadableLogRecord|MetricData]], explicitTimeout: TimeInterval?) -> [SpanExporterResultCode|ExportResult] {
        lock.lock()
        defer { lock.unlock() }

        guard let currentSession = sessionManager.peekSession() else {
            return .failure
        }

        // Get or create exporter for this session
        guard let exporter = try? getOrCreateSessionExporter(for: currentSession) else {
            return .failure
        }

        return exporter.export([spans|logRecords|metrics]: [spans|logRecords|metrics], explicitTimeout: explicitTimeout)
    }

    /// Flush current session's pending writes
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        if let currentSession = sessionManager.peekSession(),
           let exporter = sessionExporters[currentSession.id] {
            exporter.flush()
        }
    }

    /// Shutdown and export/drop all sessions
    func shutdown() {
        lock.lock()
        let allSessionIds = Array(sessionExporters.keys)
        lock.unlock()

        for sessionId in allSessionIds {
            handleSessionEnd(sessionId: sessionId)
        }
    }

    /// Clean up old kept session directories (call periodically or on app start)
    func cleanupOldSessions(olderThan interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        let cutoffDate = Date().addingTimeInterval(-interval)
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: baseStorageURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }

        for sessionURL in contents {
            guard let attributes = try? fileManager.attributesOfItem(atPath: sessionURL.path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  modificationDate < cutoffDate else {
                continue
            }

            try? fileManager.removeItem(at: sessionURL)
        }
    }

    // MARK: - Private Session Management

    /// Get existing or create new Persistence[Span|Log|Metric]ExporterDecorator for a session.
    /// Must be called within lock.
    private func getOrCreateSessionExporter(for session: Session) throws -> Persistence[Span|Log|Metric]ExporterDecorator {
        if let exporter = sessionExporters[session.id] {
            return exporter
        }

        // Create new exporter for this session
        let sessionStorageURL = baseStorageURL.appendingPathComponent(session.id)

        try FileManager.default.createDirectory(
            at: sessionStorageURL,
            withIntermediateDirectories: true
        )

        // Create exportCondition that checks if this session should be kept
        // The closure captures sessionId and reads keptSessionIds dynamically
        let sessionId = session.id
        let exporter = try Persistence[Span|Log|Metric]ExporterDecorator(
            [span|log|metric]Exporter: wrappedExporter,
            storageURL: sessionStorageURL,
            exportCondition: { [weak self] in
                guard let self = self else { return false }
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.keptSessionIds.contains(sessionId)
            },
            performancePreset: performancePreset
        )

        sessionExporters[session.id] = exporter
        return exporter
    }

    /// Handle session transition when new session starts.
    /// This is called when SessionEventNotification fires.
    private func handleSessionTransition(newSession: Session) {
        // The new session has started, which means the previous session has ended
        // The previousId in the new session tells us which session just ended
        guard let previousSessionId = newSession.previousId else {
            return // First session ever, no previous session to process
        }

        handleSessionEnd(sessionId: previousSessionId)
    }

    /// Handle session end: export if kept, drop if not kept.
    private func handleSessionEnd(sessionId: String) {
        lock.lock()

        // Prevent duplicate processing
        guard !processedSessionIds.contains(sessionId) else {
            lock.unlock()
            return
        }
        processedSessionIds.insert(sessionId)

        let shouldKeep = keptSessionIds.contains(sessionId)
        let exporter = sessionExporters[sessionId]
        let sessionStorageURL = baseStorageURL.appendingPathComponent(sessionId)

        // Clean up in-memory state
        sessionExporters.removeValue(forKey: sessionId)
        keptSessionIds.remove(sessionId)

        lock.unlock()

        // Perform export or cleanup (outside lock to avoid blocking)
        if shouldKeep {
            // Flush any remaining data for this session
            // Note: Most data should already be exported since keepSession() was called
            // and automatic export has been running
            exporter?.flush()
            // PersistenceExporter will have deleted files after successful export
            // The session directory will be empty or nearly empty after flush
        } else {
            // Drop this session's data immediately
            try? FileManager.default.removeItem(at: sessionStorageURL)
        }
    }
}

enum SessionSamplerError: Error {
    case noActiveSession
}
```

### Concrete Implementations

**Note**: Each implementation follows the pattern shown above, but with its specific signal type and PersistenceExporter. No generic core is needed - each is a complete, standalone implementation.

#### SessionSamplerSpanExporter

Wraps a `SpanExporter` and creates `PersistenceSpanExporterDecorator` instances per session:

```swift
public class SessionSamplerSpanExporter: SpanExporter {
    private let wrappedExporter: SpanExporter
    private let sessionManager: SessionManager
    private let baseStorageURL: URL
    private let performancePreset: PersistencePerformancePreset
    private let lock = NSRecursiveLock()
    private var sessionExporters: [String: PersistenceSpanExporterDecorator] = [:]
    private var keptSessionIds: Set<String> = []
    private var processedSessionIds: Set<String> = []
    private var sessionObserver: NSObjectProtocol?

    public init(
        spanExporter: SpanExporter,
        sessionManager: SessionManager = SessionManagerProvider.getInstance(),
        baseStorageURL: URL,
        performancePreset: PersistencePerformancePreset = .default
    ) {
        self.wrappedExporter = spanExporter
        self.sessionManager = sessionManager
        self.baseStorageURL = baseStorageURL
        self.performancePreset = performancePreset

        try? FileManager.default.createDirectory(at: baseStorageURL, withIntermediateDirectories: true)

        sessionObserver = NotificationCenter.default.addObserver(
            forName: SessionEventNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let newSession = notification.object as? Session else { return }
            self?.handleSessionTransition(newSession: newSession)
        }
    }

    public func keepSession() { /* ...implementation from pattern... */ }
    public func cleanupOldSessions(olderThan interval: TimeInterval) { /* ... */ }

    // MARK: - SpanExporter Protocol
    public func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode { /* ... */ }
    public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { /* ... */ }
    public func shutdown(explicitTimeout: TimeInterval?) { /* ... */ }

    // Private methods following the pattern above
    private func getOrCreateSessionExporter(for session: Session) throws -> PersistenceSpanExporterDecorator { /* ... */ }
    private func handleSessionTransition(newSession: Session) { /* ... */ }
    private func handleSessionEnd(sessionId: String) { /* ... */ }
}
```

#### SessionSamplerLogExporter

Same pattern as `SessionSamplerSpanExporter` but for logs:

```swift
public class SessionSamplerLogExporter: LogRecordExporter {
    private let wrappedExporter: LogRecordExporter
    private let sessionManager: SessionManager
    private let baseStorageURL: URL
    private let performancePreset: PersistencePerformancePreset
    private let lock = NSRecursiveLock()
    private var sessionExporters: [String: PersistenceLogExporterDecorator] = [:]
    private var keptSessionIds: Set<String> = []
    private var processedSessionIds: Set<String> = []
    private var sessionObserver: NSObjectProtocol?

    // Implementation follows same pattern as SessionSamplerSpanExporter
    // but uses PersistenceLogExporterDecorator
}
```

#### SessionSamplerMetricExporter

Same pattern as `SessionSamplerSpanExporter` but for metrics:

```swift
public class SessionSamplerMetricExporter: MetricExporter {
    private let wrappedExporter: MetricExporter
    private let sessionManager: SessionManager
    private let baseStorageURL: URL
    private let performancePreset: PersistencePerformancePreset
    private let lock = NSRecursiveLock()
    private var sessionExporters: [String: PersistenceMetricExporterDecorator] = [:]
    private var keptSessionIds: Set<String> = []
    private var processedSessionIds: Set<String> = []
    private var sessionObserver: NSObjectProtocol?

    // Implementation follows same pattern as SessionSamplerSpanExporter
    // but uses PersistenceMetricExporterDecorator
}

// MARK: - Log Exporter Specialization

public class SessionSamplerLogExporter: LogRecordExporter {

    private struct LogDecoratedExporter: DecoratedExporter {
        typealias SignalType = ReadableLogRecord

        private let logExporter: LogRecordExporter

        init(logExporter: LogRecordExporter) {
            self.logExporter = logExporter
        }

        func export(values: [ReadableLogRecord]) -> DataExportStatus {
            _ = logExporter.export(logRecords: values)
            return DataExportStatus(needsRetry: false)
        }
    }

    private let sampler: SessionSamplerExporter<LogDecoratedExporter>
    private let wrappedExporter: LogRecordExporter

    public init(
        logExporter: LogRecordExporter,
        sessionManager: SessionManager = SessionManagerProvider.getInstance(),
        baseStorageURL: URL,
        performancePreset: PersistencePerformancePreset = .default
    ) {
        self.wrappedExporter = logExporter

        self.sampler = SessionSamplerExporter<LogDecoratedExporter>(
            wrappedExporter: LogDecoratedExporter(logExporter: logExporter),
            sessionManager: sessionManager,
            baseStorageURL: baseStorageURL,
            performancePreset: performancePreset
        )
    }

    public func keepSession() {
        sampler.keepSession()
    }

    public func cleanupOldSessions(olderThan interval: TimeInterval) {
        sampler.cleanupOldSessions(olderThan: interval)
    }

    // MARK: - LogRecordExporter Protocol

    public func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        do {
            try sampler.export(values: logRecords)
            return .success
        } catch {
            return .failure
        }
    }

    public func flush(explicitTimeout: TimeInterval?) -> ExportResult {
        sampler.flush()
        return wrappedExporter.flush(explicitTimeout: explicitTimeout)
    }

    public func shutdown(explicitTimeout: TimeInterval?) {
        sampler.shutdown()
        wrappedExporter.shutdown(explicitTimeout: explicitTimeout)
    }
}

// MARK: - Metric Exporter Specialization

public class SessionSamplerMetricExporter: MetricExporter {

    private struct MetricDecoratedExporter: DecoratedExporter {
        typealias SignalType = MetricData

        private let metricExporter: MetricExporter

        init(metricExporter: MetricExporter) {
            self.metricExporter = metricExporter
        }

        func export(values: [MetricData]) -> DataExportStatus {
            _ = metricExporter.export(metrics: values)
            return DataExportStatus(needsRetry: false)
        }
    }

    private let sampler: SessionSamplerExporter<MetricDecoratedExporter>
    private let wrappedExporter: MetricExporter

    public init(
        metricExporter: MetricExporter,
        sessionManager: SessionManager = SessionManagerProvider.getInstance(),
        baseStorageURL: URL,
        performancePreset: PersistencePerformancePreset = .default
    ) {
        self.wrappedExporter = metricExporter

        self.sampler = SessionSamplerExporter<MetricDecoratedExporter>(
            wrappedExporter: MetricDecoratedExporter(metricExporter: metricExporter),
            sessionManager: sessionManager,
            baseStorageURL: baseStorageURL,
            performancePreset: performancePreset
        )
    }

    public func keepSession() {
        sampler.keepSession()
    }

    public func cleanupOldSessions(olderThan interval: TimeInterval) {
        sampler.cleanupOldSessions(olderThan: interval)
    }

    // MARK: - MetricExporter Protocol

    public func export(metrics: [MetricData], shouldCancel: (() -> Bool)?) -> ExportResult {
        do {
            try sampler.export(values: metrics)
            return .success
        } catch {
            return .failure
        }
    }

    public func flush() -> ExportResult {
        sampler.flush()
        return wrappedExporter.flush()
    }

    public func shutdown() -> ExportResult {
        sampler.shutdown()
        return wrappedExporter.shutdown()
    }
}
```

## Usage Examples

### Basic Usage with Error Tracking

```swift
import OpenTelemetrySdk

// 1. SessionManager is already initialized (via SessionManagerProvider)
// No need to create or configure it

// 2. Create base exporter
let otlpExporter = OtlpHttpTraceExporter(endpoint: "https://api.example.com/v1/traces")

// 3. Wrap with SessionSamplerExporter
let samplerExporter = SessionSamplerSpanExporter(
    spanExporter: otlpExporter,
    baseStorageURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("otel-session-spans")
)

// 4. Configure tracer provider
let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: SimpleSpanProcessor(spanExporter: samplerExporter))
    .build()

// 5. In your error handler
func handleError(_ error: Error) {
    // Mark this session to be kept - export starts immediately
    samplerExporter.keepSession()

    // Log the error
    print("Error occurred: \(error)")

    // Note: Telemetry is now being exported in the background
    // No need to wait until session ends
}

// 6. Periodic cleanup (e.g., on app launch)
samplerExporter.cleanupOldSessions(olderThan: 7 * 24 * 60 * 60) // 7 days
```

### Custom SessionManager Configuration

```swift
// Configure SessionManager with custom timeout
let customSessionManager = SessionManager(
    configuration: SessionConfig(sessionTimeout: 30 * 60) // 30 minute sessions
)
SessionManagerProvider.register(sessionManager: customSessionManager)

// SessionSamplerExporter will automatically use the registered SessionManager
let samplerExporter = SessionSamplerSpanExporter(
    spanExporter: otlpExporter,
    baseStorageURL: storageURL
)
```

### Performance-Based Sampling

```swift
class PerformanceMonitor {
    let samplerExporter: SessionSamplerSpanExporter

    func onSlowOperation(duration: TimeInterval) {
        if duration > 5.0 { // Keep sessions with operations > 5s
            samplerExporter.keepSession()
            // Export begins immediately - performance data available for analysis
        }
    }
}
```

### User-Initiated Problem Reporting

```swift
class FeedbackViewController: UIViewController {
    let samplerExporter: SessionSamplerSpanExporter

    @IBAction func reportProblem() {
        // User reported a problem, keep this session's telemetry
        samplerExporter.keepSession()

        // Export starts immediately - support team will have data soon
        // Show feedback form
        showFeedbackForm()
    }
}
```

### Multi-Signal Integration

```swift
// All samplers share the same SessionManager (via SessionManagerProvider)
let spanSampler = SessionSamplerSpanExporter(
    spanExporter: otlpSpanExporter,
    baseStorageURL: baseURL.appendingPathComponent("spans")
)

let logSampler = SessionSamplerLogExporter(
    logExporter: otlpLogExporter,
    baseStorageURL: baseURL.appendingPathComponent("logs")
)

let metricSampler = SessionSamplerMetricExporter(
    metricExporter: otlpMetricExporter,
    baseStorageURL: baseURL.appendingPathComponent("metrics")
)

// Keep all signal types for the same session
func handleCriticalError() {
    spanSampler.keepSession()
    logSampler.keepSession()
    metricSampler.keepSession()
}
```

### Conditional Debug Mode

```swift
// Automatically keep sessions when debug mode is enabled
class AppDelegate: UIApplicationDelegate {
    func applicationDidBecomeActive(_ application: UIApplication) {
        if UserDefaults.standard.bool(forKey: "DebugModeEnabled") {
            spanSampler.keepSession()
        }
    }
}
```

## Design Considerations

### Thread Safety

- All mutable state protected by `NSRecursiveLock`
- Session transitions handled atomically
- Export and cleanup performed outside locks to avoid blocking
- NotificationCenter observer runs on arbitrary thread, protected by lock

### Session Transition Detection

**How we detect session end:**

1. SessionEventNotification fires with new Session object
2. New session contains `previousId` field
3. `previousId` identifies the session that just ended
4. We process the previous session (export or drop)

**First session case:**
- `previousId` is nil
- No previous session to process
- Normal operation continues

**Edge case: Telemetry during transition:**
- Session end processing happens asynchronously
- New telemetry might arrive before cleanup completes
- New telemetry will go to new session (correct behavior)
- Previous session's exporter might still be flushing (okay)

### Storage Management

**Session directory lifecycle:**

1. Created on first telemetry for that session
2. Files accumulate as telemetry is generated
3. On session end:
   - If kept: flush() exports all files, PersistenceExporter deletes them
   - If dropped: entire directory deleted immediately
4. Empty/nearly-empty kept session directories remain
5. Periodic cleanup removes old directories

**Storage location:**
- Uses `/Library/Caches` like PersistenceExporter
- Subject to system purging under space pressure
- Each signal type should use separate subdirectory

### Performance Preset Recommendations

For session sampling, consider a preset optimized for session duration:

```swift
let sessionPreset = PersistencePerformancePreset(
    maxFileSize: 4 * 1024 * 1024,
    maxDirectorySize: 100 * 1024 * 1024,  // Lower per-session limit
    maxFileAgeForWrite: 4.75,
    minFileAgeForRead: 5.25,
    maxFileAgeForRead: 24 * 60 * 60,      // Sessions typically < 24h (default 18h)
    maxObjectsInFile: 500,
    maxObjectSize: 256 * 1024,
    synchronousWrite: false,               // true for very short sessions
    initialExportDelay: 5,
    defaultExportDelay: 5,
    minExportDelay: 1,
    maxExportDelay: 20,
    exportDelayChangeRate: 0.1
)
```

### Export Behavior

**When does export happen?**
- **Immediately when keepSession() is called**: The PersistenceExporter's exportCondition becomes true, triggering automatic export cycle
- **Continuously during the session**: DataExportWorker exports files as they become eligible (based on file age)
- **On session end**: Final flush() to export any remaining data

**Benefits of immediate export:**
- Reduces end-of-session flush time
- Data is available sooner on the server
- Lower risk of data loss if app crashes
- Session directory cleaned up progressively during session

**Export failures:**
- PersistenceExporter's retry mechanism handles transient failures
- Failed exports retry with exponential backoff
- On session end, final flush() attempts to export remaining data
- Session directory remains if exports fail (cleaned up by periodic cleanup)

### SessionManager.peekSession() Usage

We use `peekSession()` instead of `getSession()` because:

- `getSession()` extends session expiry on every call
- `peekSession()` just reads current session without side effects
- Exporting telemetry shouldn't extend the session
- Prevents artificial session extension from telemetry generation

### Integration with Existing Processors

The SessionSamplerExporter complements existing session processors:

- **SessionSpanProcessor**: Adds session.id attribute to spans
- **SessionLogRecordProcessor**: Adds session.id attribute to logs
- **SessionSamplerExporter**: Controls which sessions are exported

These work together:
```swift
// Add session attributes to all telemetry
let sessionSpanProcessor = SessionSpanProcessor(sessionManager: sessionManager)

// Control which sessions are exported
let sessionSamplerExporter = SessionSamplerSpanExporter(
    spanExporter: otlpExporter,
    baseStorageURL: storageURL
)

// Combine both
let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: sessionSpanProcessor)
    .add(spanProcessor: SimpleSpanProcessor(spanExporter: sessionSamplerExporter))
    .build()
```

## Implementation Status

### Completed
- [x] Implement `SessionSamplerSpanExporter` using public APIs
- [x] Implement `SessionSamplerLogExporter` using public APIs
- [x] Implement `SessionSamplerMetricExporter` using public APIs
- [x] Add basic keep/drop behavior tests
- [x] Add cleanup tests
- [x] Test integration with existing SessionManager
- [x] Test that keepSession() can be called multiple times
- [x] Build succeeds with no errors
- [x] All tests pass

### Not Implemented
- [ ] Thread safety tests
- [ ] Session transition tests
- [ ] Document performance characteristics
- [ ] Add integration tests with real PersistenceExporter
- [ ] Test with short-lived sessions
- [ ] Test with rapid session transitions
- [ ] Test memory usage with many sessions

### Implementation Notes
- No generic `SessionSamplerExporter<T>` core was created. Instead, three separate implementations were created that each wrap the corresponding public `Persistence*ExporterDecorator` class.
- This approach was chosen to use only public APIs without requiring modifications to existing classes.
- Tests require calling `sessionManager.getSession()` to create a session before exporting data.

## Open Questions

1. **Should keepSession() be retroactive?**
   - Current design: Only affects current session
   - Alternative: Keep last N sessions retroactively?
   - Consideration: Would need to prevent cleanup of recent sessions

2. **Should we provide session query API?**
   - e.g., `isCurrentSessionKept()`, `getCurrentSessionId()`
   - Current design: No public query API
   - Consider: Debugging and testing use cases

3. **Should export be async with callbacks?**
   - Current design: Sync flush() in response to notification
   - Alternative: Background queue with completion callbacks
   - Trade-off: Simpler vs. non-blocking

4. **How to handle rapid session transitions?**
   - If user toggles app quickly, many sessions may end
   - Current design: Process each sequentially
   - Consider: Batch processing or limits

5. **Should we support "always keep last N sessions"?**
   - e.g., Keep last 5 sessions even without keepSession() call
   - Current design: No, explicit keep only
   - Consider: Ring buffer of recent sessions

6. **Should cleanup be automatic?**
   - Current design: Manual `cleanupOldSessions()` call
   - Alternative: Automatic periodic cleanup
   - Consider: Background timer vs. manual control

## Future Enhancements

1. **Export progress callbacks**: Notify when session export completes
2. **Session metadata**: Attach metadata to sessions (error counts, duration, etc.)
3. **Sampling rate**: Automatically keep N% of sessions
4. **Remote sampling**: Server-side decision on keep/drop
5. **Compression**: Compress session data before export
6. **Session replay**: Re-export dropped sessions if needed later
7. **Analytics dashboard**: Track kept/dropped ratios, export success rates
8. **Session grouping**: Link related sessions together
9. **Partial session export**: Export subset of telemetry from a session
10. **Session attributes in exported data**: Include session metadata in exported telemetry

## Relationship to Existing Components

```
┌─────────────────────────────────────────────────────────┐
│  SessionManager (existing)                              │
│  - Manages session lifecycle                            │
│  - Posts SessionEventNotification                       │
│  - Calls SessionEventInstrumentation.addSession()       │
└────────────┬────────────────────────────────────────────┘
             │
             │ SessionEventNotification
             ▼
┌─────────────────────────────────────────────────────────┐
│  SessionSamplerExporter (new)                           │
│  - Listens to notifications                             │
│  - Creates per-session PersistenceExporters             │
│  - Exports or drops based on keepSession() calls        │
└────────────┬────────────────────────────────────────────┘
             │
             │ uses
             ▼
┌─────────────────────────────────────────────────────────┐
│  PersistenceExporter (existing)                         │
│  - Manages file storage and export                      │
│  - Retries on failure                                   │
│  - Respects exportCondition                             │
└─────────────────────────────────────────────────────────┘
```

This design integrates cleanly with the existing session infrastructure without requiring modifications to SessionManager or related components.
