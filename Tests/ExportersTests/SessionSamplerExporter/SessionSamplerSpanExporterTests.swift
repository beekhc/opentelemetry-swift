/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import OpenTelemetryApi
import OpenTelemetrySdk
@testable import SessionSamplerExporter
@testable import Sessions
import PersistenceExporter
import XCTest

class SessionSamplerSpanExporterTests: XCTestCase {

  class SpanExporterMock: SpanExporter {
    let onExport: ([SpanData], TimeInterval?) -> SpanExporterResultCode
    let onFlush: (TimeInterval?) -> SpanExporterResultCode
    let onShutdown: (TimeInterval?) -> Void

    init(onExport: @escaping ([SpanData], TimeInterval?) -> SpanExporterResultCode,
         onFlush: @escaping (TimeInterval?) -> SpanExporterResultCode = { _ in .success },
         onShutdown: @escaping (TimeInterval?) -> Void = { _ in }) {
      self.onExport = onExport
      self.onFlush = onFlush
      self.onShutdown = onShutdown
    }

    @discardableResult func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
      return onExport(spans, explicitTimeout)
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
      return onFlush(explicitTimeout)
    }

    func shutdown(explicitTimeout: TimeInterval?) {
      onShutdown(explicitTimeout)
    }
  }

  var temporaryDirectory: URL!
  var sessionManager: SessionManager!

  override func setUp() {
    super.setUp()
    // Create temporary directory
    temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

    // Create session manager
    sessionManager = SessionManager(configuration: SessionConfig(sessionTimeout: 1800))
  }

  override func tearDown() {
    // Clean up temporary directory
    try? FileManager.default.removeItem(at: temporaryDirectory)
    super.tearDown()
  }

  func testExportSpans_withoutKeepSession_spansAreNotExported() throws {
    let exportExpectation = expectation(description: "spans exported")
    exportExpectation.isInverted = true

    let mockSpanExporter = SpanExporterMock(onExport: { spans, _ in
      exportExpectation.fulfill()
      return .success
    })

    let samplerExporter = SessionSamplerSpanExporter(
      spanExporter: mockSpanExporter,
      sessionManager: sessionManager,
      baseStorageURL: temporaryDirectory,
      performancePreset: .instantDataDelivery
    )

    let instrumentationScopeName = "TestExporter"
    let instrumentationScopeVersion = "1.0.0"
    let tracerProviderSDK = TracerProviderSdk()
    let tracer = tracerProviderSDK.get(instrumentationName: instrumentationScopeName, instrumentationVersion: instrumentationScopeVersion) as! TracerSdk

    let spanProcessor = SimpleSpanProcessor(spanExporter: samplerExporter)
    tracerProviderSDK.addSpanProcessor(spanProcessor)

    // Create a span without calling keepSession
    let span = tracer.spanBuilder(spanName: "TestSpan").setSpanKind(spanKind: .client).startSpan()
    span.end()
    spanProcessor.shutdown()

    // Wait to ensure export doesn't happen
    waitForExpectations(timeout: 2, handler: nil)
  }

  func testExportSpans_withKeepSession_spansAreExported() throws {
    let exportExpectation = expectation(description: "spans exported")

    let mockSpanExporter = SpanExporterMock(onExport: { spans, _ in
      if spans.contains(where: { $0.name == "TestSpan" }) {
        exportExpectation.fulfill()
      }
      return .success
    })

    // Use a custom preset with zero delays for immediate export in tests
    let testPreset = PersistencePerformancePreset(
      maxFileSize: 4 * 1_024 * 1_024,
      maxDirectorySize: 512 * 1_024 * 1_024,
      maxFileAgeForWrite: 0,
      minFileAgeForRead: 0,  // No age requirement - export immediately
      maxFileAgeForRead: 18 * 60 * 60,
      maxObjectsInFile: 500,
      maxObjectSize: 256 * 1_024,
      synchronousWrite: true,
      initialExportDelay: 0,  // Start export immediately
      defaultExportDelay: 0,
      minExportDelay: 0,
      maxExportDelay: 0.1,
      exportDelayChangeRate: 0.1
    )

    let samplerExporter = SessionSamplerSpanExporter(
      spanExporter: mockSpanExporter,
      sessionManager: sessionManager,
      baseStorageURL: temporaryDirectory,
      performancePreset: testPreset
    )

    let instrumentationScopeName = "TestExporter"
    let instrumentationScopeVersion = "1.0.0"
    let tracerProviderSDK = TracerProviderSdk()
    let tracer = tracerProviderSDK.get(instrumentationName: instrumentationScopeName, instrumentationVersion: instrumentationScopeVersion) as! TracerSdk

    let spanProcessor = SimpleSpanProcessor(spanExporter: samplerExporter)
    tracerProviderSDK.addSpanProcessor(spanProcessor)

    // Create a session first
    _ = sessionManager.getSession()

    // Mark session to be kept
    samplerExporter.keepSession()

    // Create a span
    let span = tracer.spanBuilder(spanName: "TestSpan").setSpanKind(spanKind: .client).startSpan()
    span.end()

    // Force flush to trigger export
    _ = samplerExporter.flush(explicitTimeout: nil)

    spanProcessor.shutdown()

    waitForExpectations(timeout: 3, handler: nil)
  }

  func testKeepSession_canBeCalledMultipleTimes() throws {
    let mockSpanExporter = SpanExporterMock(onExport: { _, _ in .success })

    let samplerExporter = SessionSamplerSpanExporter(
      spanExporter: mockSpanExporter,
      sessionManager: sessionManager,
      baseStorageURL: temporaryDirectory
    )

    // Should not crash when called multiple times
    samplerExporter.keepSession()
    samplerExporter.keepSession()
    samplerExporter.keepSession()
  }


  func testCleanupOldSessions() throws {
    let mockSpanExporter = SpanExporterMock(onExport: { _, _ in .success })

    let samplerExporter = SessionSamplerSpanExporter(
      spanExporter: mockSpanExporter,
      sessionManager: sessionManager,
      baseStorageURL: temporaryDirectory
    )

    // Should not crash
    samplerExporter.cleanupOldSessions(olderThan: 7 * 24 * 60 * 60)
  }
}
