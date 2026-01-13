/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetrySdk
import Sessions
import PersistenceExporter

/// A log exporter that uses session-based sampling.
/// Only exports logs for sessions where `keepSession()` was called.
/// Export begins immediately when a session is marked to be kept.
public class SessionSamplerLogExporter: LogRecordExporter {

  // MARK: - Dependencies

  private let wrappedExporter: LogRecordExporter
  private let sessionManager: SessionManager
  private let baseStorageURL: URL
  private let performancePreset: PersistencePerformancePreset

  // MARK: - Session State

  private let lock = NSRecursiveLock()
  private var sessionExporters: [String: PersistenceLogExporterDecorator] = [:]
  private var keptSessionIds: Set<String> = []
  private var sessionObserver: NSObjectProtocol?
  private var processedSessionIds: Set<String> = []

  // MARK: - Initialization

  public init(
    logExporter: LogRecordExporter,
    sessionManager: SessionManager = SessionManagerProvider.getInstance(),
    baseStorageURL: URL,
    performancePreset: PersistencePerformancePreset = .default
  ) {
    self.wrappedExporter = logExporter
    self.sessionManager = sessionManager
    self.baseStorageURL = baseStorageURL
    self.performancePreset = performancePreset

    try? FileManager.default.createDirectory(
      at: baseStorageURL,
      withIntermediateDirectories: true
    )

    sessionObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name(SessionConstants.sessionEventNotification),
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

  public func keepSession() {
    lock.lock()
    let currentSession = sessionManager.peekSession()
    let exporter = currentSession.flatMap { sessionExporters[$0.id] }

    if let session = currentSession {
      keptSessionIds.insert(session.id)
    }
    lock.unlock()

    // Trigger immediate export now that exportCondition is true
    _ = exporter?.forceFlush(explicitTimeout: nil)
  }

  public func cleanupOldSessions(olderThan interval: TimeInterval) {
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

  // MARK: - LogRecordExporter Protocol

  public func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
    lock.lock()
    defer { lock.unlock() }

    guard let currentSession = sessionManager.peekSession() else {
      return .failure
    }

    guard let exporter = try? getOrCreateSessionExporter(for: currentSession) else {
      return .failure
    }

    return exporter.export(logRecords: logRecords, explicitTimeout: explicitTimeout)
  }

  public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.lock()
    defer { lock.unlock() }

    if let currentSession = sessionManager.peekSession(),
       let exporter = sessionExporters[currentSession.id] {
      _ = exporter.forceFlush(explicitTimeout: explicitTimeout)
    }

    return wrappedExporter.forceFlush(explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) {
    lock.lock()
    let allSessionIds = Array(sessionExporters.keys)
    lock.unlock()

    for sessionId in allSessionIds {
      handleSessionEnd(sessionId: sessionId)
    }

    wrappedExporter.shutdown(explicitTimeout: explicitTimeout)
  }

  // MARK: - Private Session Management

  private func getOrCreateSessionExporter(for session: Session) throws -> PersistenceLogExporterDecorator {
    if let exporter = sessionExporters[session.id] {
      return exporter
    }

    let sessionStorageURL = baseStorageURL.appendingPathComponent(session.id)

    try FileManager.default.createDirectory(
      at: sessionStorageURL,
      withIntermediateDirectories: true
    )

    let sessionId = session.id
    let exporter = try PersistenceLogExporterDecorator(
      logRecordExporter: wrappedExporter,
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

  private func handleSessionTransition(newSession: Session) {
    guard let previousSessionId = newSession.previousId else {
      return
    }

    handleSessionEnd(sessionId: previousSessionId)
  }

  private func handleSessionEnd(sessionId: String) {
    lock.lock()

    guard !processedSessionIds.contains(sessionId) else {
      lock.unlock()
      return
    }
    processedSessionIds.insert(sessionId)

    let shouldKeep = keptSessionIds.contains(sessionId)
    let exporter = sessionExporters[sessionId]
    let sessionStorageURL = baseStorageURL.appendingPathComponent(sessionId)

    sessionExporters.removeValue(forKey: sessionId)
    keptSessionIds.remove(sessionId)

    lock.unlock()

    if shouldKeep {
      _ = exporter?.forceFlush(explicitTimeout: nil)
    } else {
      try? FileManager.default.removeItem(at: sessionStorageURL)
    }
  }
}
