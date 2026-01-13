# PersistenceExporter Analysis

## Overview

The **PersistenceExporter** is a decorator pattern implementation that adds filesystem persistence to any OpenTelemetry exporter. It's designed for environments where network connectivity is unreliable (e.g., mobile apps).

## 1. How It Hooks In

The PersistenceExporter uses the **Decorator Pattern** to wrap existing exporters:

```
┌─────────────────────────────────────────────────────────┐
│  Application / OpenTelemetry SDK                        │
└────────────────┬────────────────────────────────────────┘
                 │
                 │ export(spans/logs/metrics)
                 ▼
┌─────────────────────────────────────────────────────────┐
│  PersistenceSpanExporterDecorator                       │
│  (or PersistenceLogExporterDecorator,                   │
│   PersistenceMetricExporterDecorator)                   │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │ PersistenceExporterDecorator<T>            │        │
│  │  - Serializes to JSON                      │        │
│  │  - Writes to disk via FileWriter           │        │
│  │  - Returns success immediately             │        │
│  └────────────────────────────────────────────┘        │
│                                                          │
│  ┌────────────────────────────────────────────┐        │
│  │ DataExportWorker (background)              │        │
│  │  - Reads persisted files via FileReader    │        │
│  │  - Deserializes JSON                       │        │
│  │  - Exports to wrapped exporter             │        │
│  │  - Deletes files on success                │        │
│  └────────────────────────────────────────────┘        │
└─────────────────┬───────────────────────────────────────┘
                  │
                  │ export(values) - async, when ready
                  ▼
┌─────────────────────────────────────────────────────────┐
│  Wrapped Exporter (OTLP, Zipkin, etc.)                  │
│  - Sends data to backend                                │
└─────────────────────────────────────────────────────────┘
```

**Initialization example** (PersistenceSpanExporterDecorator.swift:31-42):
```swift
let spanExporter = ... // your actual exporter (OTLP, Zipkin, etc.)
let persistenceTraceExporter = try PersistenceSpanExporterDecorator(
  spanExporter: spanExporter,
  storageURL: tracesSubdirectoryURL,
  exportCondition: { true }, // optional: check network connectivity
  performancePreset: .default)
```

## 2. Where It Stores Data

**Storage Location**: `/Library/Caches/<storageURL subdirectory>` (Directory.swift:48-65)

- Uses iOS/macOS system caches directory
- Excluded from iTunes and iCloud backups automatically
- System may delete data under heavy space pressure
- Each signal type (traces, logs, metrics) uses a separate subdirectory

**File Structure**:
```
/Library/Caches/
└── <your-app-identifier>/
    ├── traces/
    │   ├── 123456789000  ← timestamp in ms since reference date
    │   ├── 123456790000
    │   └── 123456791000
    ├── logs/
    │   └── ...
    └── metrics/
        └── ...
```

**File Naming** (FilesOrchestrator.swift:159-163): Filenames are timestamps in milliseconds since reference date (e.g., `123456789000`)

## 3. Data Format

**JSON with special structure** (PersistenceExporterDecorator.swift:97-107):

When writing (encoding):
```
[SpanData1, SpanData2, SpanData3],
[SpanData4, SpanData5],
[SpanData6],
```

- Each batch is a JSON array of signals
- Each array is followed by a comma
- Multiple batches are appended to the same file

When reading (decoding, PersistenceExporterDecorator.swift:29-47):
```
[                           ← prefix added
[SpanData1, SpanData2],     ← original data
[SpanData3, SpanData4],     ← original data
null]                       ← suffix added
```
- Wraps the comma-separated arrays with `[` prefix and `null]` suffix to create valid JSON
- Decodes as `[[T.SignalType]?]` then flattens

**Storage Limits** (PersistencePerformancePreset.swift:110-122):
- Max file size: 4MB (default)
- Max directory size: 512MB (default)
- Max objects per file: 500 (default)
- Max object size: 256KB (default)

## 4. When It Sends Data

The **DataExportWorker** runs a periodic export loop on a background queue:

```
┌──────────────────────────────────────────────────────────┐
│  DataExportWorker Loop (background thread)               │
│                                                           │
│  1. Wait for delay (initially 5s)                        │
│  2. Check exportCondition() → network available?         │
│  3. FileReader.readNextBatch() → get oldest file         │
│  4. Export to wrapped exporter                           │
│  5. If success:                                          │
│     - Delete file                                        │
│     - Decrease delay (min 1s)                            │
│  6. If failure:                                          │
│     - Keep file for retry                                │
│     - Increase delay (max 20s)                           │
│  7. Schedule next export                                 │
│  8. Repeat                                               │
└──────────────────────────────────────────────────────────┘
```

**Export Timing** (DataExportWorker.swift:44-72):

**Default preset (`lowRuntimeImpact`)** (PersistencePerformancePreset.swift:110-122):
- Initial delay: 5s (postpone to not impact app launch)
- Default delay: 5s
- Min delay: 1s (on success)
- Max delay: 20s (on failure)
- Delay change rate: 0.1 (10% adjustment)

**File age requirements** (PersistencePerformancePreset.swift:112-113):
- Files are written for up to 4.75s
- Files must be at least 5.25s old before export (ensures write is complete)

**Instant delivery preset** (PersistencePerformancePreset.swift:124-139):
- Initial delay: 0.5s
- Default delay: 3s
- Files written for up to 2.75s
- Synchronous writes (blocks until data is on disk)

**File lifecycle** (FilesOrchestrator.swift:82-103):
1. File created with current timestamp as name
2. Data appended until file reaches limits (age/size/object count)
3. File becomes eligible for export when old enough (minFileAgeForRead)
4. DataExportWorker exports oldest files first
5. File deleted on successful export
6. Files older than 18 hours deleted without export (obsolete)

**Manual flush** (PersistenceExporterDecorator.swift:109-112):
```swift
persistenceExporter.flush()
```
- Flushes pending writes
- Exports all remaining files synchronously
- Useful before app termination

## Architecture Diagram

```
Write Path (Synchronous from SDK perspective):
═══════════════════════════════════════════════
SDK → PersistenceExporter.export(values)
  → JSONEncoder.encode(values)
  → FileWriter.write(data)
  → Queue.async →  FilesOrchestrator.getWritableFile()
  → File.append(data)
  → Return SUCCESS to SDK (data safely queued)


Export Path (Asynchronous background):
═══════════════════════════════════════
DataExportWorker (periodic timer)
  → exportCondition() check
  → FileReader.readNextBatch()
  → FilesOrchestrator.getReadableFile() (oldest eligible)
  → File.read()
  → JSONDecoder.decode()
  → WrappedExporter.export(values)
  → If success: delete file, decrease delay
  → If failure: keep file, increase delay
  → Schedule next export
```

## Key Implementation Details

- **Thread Safety**: Uses dedicated serial DispatchQueues (FileWriter.swift:20, DataExportWorker.swift:21)
- **Error Handling**: Failures in export cause retry with backoff, not data loss
- **Space Management**: Auto-purges oldest files when directory exceeds 512MB (FilesOrchestrator.swift:123-143)
- **Performance**: Asynchronous writes by default to avoid blocking SDK
- **Reliability**: Data persisted before reporting success to SDK

## Component Descriptions

### PersistenceExporterDecorator (Generic Core)
**File**: `Sources/Exporters/Persistence/PersistenceExporterDecorator.swift`

The generic decorator that wraps any exporter conforming to `DecoratedExporter` protocol. Uses Swift generics to support any signal type that conforms to `Codable` (SpanData, ReadableLogRecord, MetricData).

Key responsibilities:
- JSON encoding of signal batches
- Writing to disk via FileWriter
- Coordinating FileWriter and DataExportWorker
- Choosing sync vs async writes based on performance preset

### Specialized Decorators
**Files**:
- `Sources/Exporters/Persistence/PersistenceSpanExporterDecorator.swift`
- `Sources/Exporters/Persistence/PersistenceLogExporterDecorator.swift`
- `Sources/Exporters/Persistence/PersistenceMetricExporterDecorator.swift`

Type-specific wrappers that implement the standard OpenTelemetry exporter interfaces (SpanExporter, LogRecordExporter, MetricExporter) while delegating to the generic PersistenceExporterDecorator.

### FileWriter & OrchestratedFileWriter
**File**: `Sources/Exporters/Persistence/Storage/FileWriter.swift`

Handles writing data to disk:
- Async writes (default): queues write operations on background thread
- Sync writes: blocks until data is written and synchronized to disk
- Uses FilesOrchestrator to get writable file handles

### FileReader & OrchestratedFileReader
**File**: `Sources/Exporters/Persistence/Storage/FileReader.swift`

Handles reading persisted data:
- Returns batches from oldest eligible files
- Tracks which files have been read
- Provides batch-by-batch or all-remaining-batches modes

### FilesOrchestrator
**File**: `Sources/Exporters/Persistence/Storage/FilesOrchestrator.swift`

Central coordinator for file lifecycle management:
- Creates new files with timestamp-based names
- Reuses files until they reach age/size/count limits
- Provides readable files (oldest first, meeting age requirements)
- Purges old files when directory size exceeds limit
- Deletes obsolete files (older than 18 hours)

### DataExportWorker
**File**: `Sources/Exporters/Persistence/Export/DataExportWorker.swift`

Background worker that exports persisted data:
- Runs periodic export loop on background queue
- Implements adaptive delay based on success/failure
- Checks exportCondition before attempting export
- Manages retry logic with exponential backoff

### Directory & File Abstractions
**File**: `Sources/Exporters/Persistence/Storage/Directory.swift`

Filesystem abstractions:
- Creates subdirectories in `/Library/Caches`
- Provides file creation and enumeration
- Handles iOS/macOS filesystem specifics

### PersistencePerformancePreset
**File**: `Sources/Exporters/Persistence/PersistencePerformancePreset.swift`

Configuration for storage and export behavior:

**Storage configuration**:
- File size limits
- Directory size limits
- File age thresholds
- Object count limits
- Sync vs async write mode

**Export configuration**:
- Initial export delay
- Min/max export delays
- Delay change rate for adaptive scheduling

**Predefined presets**:
- `lowRuntimeImpact` (default): Optimized for battery life and performance
- `instantDataDelivery`: Optimized for quick data delivery (useful for short-lived app extensions)

## Usage Examples

### Basic Usage (Spans)
```swift
import OpenTelemetrySdk

// Create your actual exporter
let otlpExporter = OtlpHttpTraceExporter(endpoint: "https://api.example.com/v1/traces")

// Wrap it with persistence
let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("otel-traces")
)

// Use it in your tracer provider
let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: SimpleSpanProcessor(spanExporter: persistenceExporter))
    .build()
```

### With Network Condition Check
```swift
import Network

let monitor = NWPathMonitor()
let queue = DispatchQueue.global(qos: .background)
monitor.start(queue: queue)

let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    exportCondition: {
        // Only export when network is available
        monitor.currentPath.status == .satisfied
    },
    performancePreset: .default
)
```

### Instant Delivery Mode
```swift
// For app extensions or scenarios requiring quick delivery
let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    performancePreset: .instantDataDelivery
)
```

### Custom Performance Preset
```swift
let customPreset = PersistencePerformancePreset(
    maxFileSize: 2 * 1024 * 1024,        // 2MB files
    maxDirectorySize: 100 * 1024 * 1024,  // 100MB total
    maxFileAgeForWrite: 3.0,              // Write to file for 3s
    minFileAgeForRead: 3.5,               // Export after 3.5s
    maxFileAgeForRead: 12 * 60 * 60,      // Delete after 12h
    maxObjectsInFile: 250,                // Max 250 objects per file
    maxObjectSize: 128 * 1024,            // Max 128KB per object
    synchronousWrite: false,              // Async writes
    initialExportDelay: 3.0,              // Start exporting after 3s
    defaultExportDelay: 3.0,              // Default 3s between exports
    minExportDelay: 0.5,                  // Min 0.5s on success
    maxExportDelay: 30.0,                 // Max 30s on failure
    exportDelayChangeRate: 0.2            // 20% adjustment
)

let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    performancePreset: customPreset
)
```

### Flushing Before App Termination
```swift
// In your app delegate or scene delegate
func applicationWillTerminate(_ application: UIApplication) {
    // Flush any pending data
    persistenceExporter.flush()

    // Give it a moment to complete
    Thread.sleep(forTimeInterval: 1.0)
}
```

### Manual-Only Export Mode (Cache Everything Until Explicitly Instructed)

You can configure the PersistenceExporter to cache all data and only send it when you explicitly call `flush()`:

**Simple Implementation**:
```swift
// Create a flag to control exports
var shouldExport = false

let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    exportCondition: {
        // Return false to prevent automatic exports
        return shouldExport
    },
    performancePreset: .default
)

// Data will be cached but not sent automatically

// Later, when you want to send all cached data:
shouldExport = true
persistenceExporter.flush()  // Sends all cached data synchronously
shouldExport = false  // Prevent automatic exports again
```

**Thread-Safe Implementation**:
```swift
import Foundation

class ExportController {
    private var _shouldExport = false
    private let lock = NSLock()

    var shouldExport: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldExport
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shouldExport = newValue
        }
    }
}

let controller = ExportController()

let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    exportCondition: { controller.shouldExport }
)

// To trigger export:
controller.shouldExport = true
persistenceExporter.flush()
controller.shouldExport = false
```

**Simplest Form (Never Auto-Export)**:
```swift
let persistenceExporter = try PersistenceSpanExporterDecorator(
    spanExporter: otlpExporter,
    storageURL: storageURL,
    exportCondition: { false },  // Always prevent automatic export
    performancePreset: .default
)

// Whenever you want to send data:
persistenceExporter.flush()
```

**How It Works**:

1. **exportCondition Controls Automatic Exports** (DataExportWorker.swift:49-50):
   - The `exportCondition` closure is checked before each automatic export attempt
   - When it returns `false`, no batch is read or exported
   - The background worker continues running but does nothing

2. **flush() Bypasses exportCondition** (DataExportWorker.swift:84-94):
   - The `flush()` method does NOT check `exportCondition`
   - It directly reads and exports all remaining batches
   - Returns `true` if successful
   - Blocks the calling thread until complete

**Important Considerations**:

1. **Background Worker Overhead**: The DataExportWorker continues its periodic loop, but the delay will increase to `maxExportDelay` (20s by default) since it's not finding work. This is minimal overhead.

2. **File Age Limits**: Files older than 18 hours will be deleted as obsolete (FilesOrchestrator.swift:148-150), even if never exported. Customize this if needed:
   ```swift
   let customPreset = PersistencePerformancePreset(
       maxFileSize: 4 * 1024 * 1024,
       maxDirectorySize: 512 * 1024 * 1024,
       maxFileAgeForWrite: 4.75,
       minFileAgeForRead: 5.25,
       maxFileAgeForRead: 365 * 24 * 60 * 60,  // Keep for 1 year instead of 18 hours
       maxObjectsInFile: 500,
       maxObjectSize: 256 * 1024,
       synchronousWrite: false,
       initialExportDelay: 5,
       defaultExportDelay: 5,
       minExportDelay: 1,
       maxExportDelay: 20,
       exportDelayChangeRate: 0.1
   )
   ```

3. **flush() Blocks**: The `flush()` method is synchronous and will block the calling thread until all files are exported. Plan accordingly if you have a lot of cached data.

4. **Directory Size Limits**: Even in manual-only mode, the directory size limit (512MB by default) still applies. Old files will be purged to stay within this limit (FilesOrchestrator.swift:123-143).

**Use Cases**:
- User-initiated sync (e.g., "Sync Now" button)
- Export only when on WiFi and plugged in
- Batch upload at specific times (e.g., end of day)
- Privacy-conscious apps where users control when data leaves the device

## Reference Files

### Main Implementation
- `Sources/Exporters/Persistence/PersistenceExporterDecorator.swift` - Core decorator (lines 1-123)
- `Sources/Exporters/Persistence/PersistenceSpanExporterDecorator.swift` - Spans specialization (lines 1-65)
- `Sources/Exporters/Persistence/PersistenceLogExporterDecorator.swift` - Logs specialization
- `Sources/Exporters/Persistence/PersistenceMetricExporterDecorator.swift` - Metrics specialization
- `Sources/Exporters/Persistence/Export/DataExportWorker.swift` - Background export loop (lines 1-109)
- `Sources/Exporters/Persistence/Storage/FilesOrchestrator.swift` - File lifecycle management (lines 1-192)
- `Sources/Exporters/Persistence/Storage/FileWriter.swift` - Write operations (lines 1-51)
- `Sources/Exporters/Persistence/Storage/FileReader.swift` - Read operations (lines 1-70)
- `Sources/Exporters/Persistence/Storage/Directory.swift` - Filesystem abstractions (lines 1-66)
- `Sources/Exporters/Persistence/PersistencePerformancePreset.swift` - Configuration (lines 1-141)
- `Sources/Exporters/Persistence/README.md` - Official documentation (lines 1-31)

### Tests
- `Tests/ExportersTests/PersistenceExporter/` - Comprehensive test coverage
