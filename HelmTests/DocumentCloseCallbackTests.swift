import XCTest
import AppKit

final class DocumentCloseCallbackTests: XCTestCase
{
  @MainActor final class Delegate: NSObject {
    var calls = 0
    var allowed: Bool?
    var document: NSDocument?
    var context: UnsafeMutableRawPointer?
    @objc func reply(_ document: NSDocument, shouldClose: Bool,
                     contextInfo: UnsafeMutableRawPointer?) {
      calls += 1; self.document = document
      allowed = shouldClose; context = contextInfo
    }
  }
  @MainActor func testCancelReplyPreservesDocumentAndContextWithoutClosing() {
    let document = NSDocument(), delegate = Delegate()
    let context = UnsafeMutableRawPointer(bitPattern: 1234)
    HelmReplyToDocumentClose(delegate, #selector(Delegate.reply(_:shouldClose:contextInfo:)),
                             document, false, context)
    XCTAssertEqual(delegate.calls, 1)
    XCTAssertEqual(delegate.allowed, false)
    XCTAssertTrue(delegate.document === document)
    XCTAssertEqual(delegate.context, context)
  }
  @MainActor func testApprovedReplyAndMissingCallbackAreSafe() {
    let document = NSDocument(), delegate = Delegate()
    HelmReplyToDocumentClose(delegate, #selector(Delegate.reply(_:shouldClose:contextInfo:)),
                             document, true, nil)
    XCTAssertEqual(delegate.allowed, true)
    HelmReplyToDocumentClose(nil, nil, document, false, nil)
    HelmReplyToDocumentClose(delegate, NSSelectorFromString("unknownCloseReply:"), document, false, nil)
    XCTAssertEqual(delegate.calls, 1)
  }
}
