import XCTest
@testable import FalconCore

final class DiagnosticsSignatureTests: XCTestCase {
    private let redactor = DiagnosticsRedactor(salt: Data(repeating: 1, count: 32), homePath: "/Users/tester")

    private func signature(_ message: String, error: (any Error)? = nil, area: String = "IMAP",
                           file: String = "FalconCore/AccountSyncer.swift", function: String = "loop()") -> String {
        let redacted = redactor.redact(message)
        return DiagnosticsSignature.make(area: area, code: DiagnosticsSignature.code(for: error, message: redacted), file: file,
                                         function: function)
    }

    private func dynamicPart(_ signature: String) -> String {
        String(signature.split(separator: "@").first ?? "")
    }

    func testContractExample() {
        let error = FalconError.network("server closed session: Account exceeded command or bandwidth limits.")
        XCTAssertEqual(signature("ana@example.com: \(error.localizedDescription)", error: error),
                       "IMAP.throttled@AccountSyncer.swift:loop")
    }

    func testSameFailureWithDifferentValuesGroupsTogether() {
        let a = signature("UID 4711 in folder 12 not returned after 3 attempts for ana@example.com")
        let b = signature("UID 98 in folder 7 not returned after 1 attempts for bob@example.org")
        XCTAssertEqual(a, b)
        XCTAssertFalse(dynamicPart(a).contains(where: \.isNumber), a)
    }

    func testUnclassifiedMessagesUseTheirFirstWords() {
        let a = signature(#"Could not read the original message "Invoice 42" to attach it."#, area: "Alert", file: "AppModel.swift",
                          function: "errorMessage")
        let b = signature(#"Could not read the original message "Lunch" to attach it."#, area: "Alert", file: "AppModel.swift",
                          function: "errorMessage")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "Alert.couldNotReadTheOriginal@AppModel.swift:errorMessage")
    }

    func testSignaturesNeverCarryNumbersOrIDsFromValues() {
        let messages = [
            "HTTP 503: Service Unavailable at 2026-09-24T10:11:12Z",
            "Could not finish an action from the last session: UID 12345 missing",
            "Mailbox 7F3A9C1B-1111-2222-3333-444455556666 was rebuilt",
            "Error 0x8badf00d in thread 17",
            "550 5.1.1 recipient 42 rejected",
        ]
        for message in messages {
            let s = signature(message)
            XCTAssertFalse(dynamicPart(s).contains(where: \.isNumber), "\(message) → \(s)")
            XCTAssertEqual(s, signature(message), "stable across calls")
        }
    }

    func testCodesFromErrors() {
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.notAuthenticated, message: ""), "notSignedIn")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.http(503, "busy"), message: ""), "serverError")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.http(429, "slow down"), message: ""), "tooManyRequests")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.protocolError("authentication failed: [AUTHENTICATIONFAILED] Invalid credentials (Failure)"), message: ""), "auth")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.protocolError("SMTP authentication failed: 535-5.7.8 Username and Password not accepted"), message: ""), "auth")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.protocolError("Recipient bob@x.org rejected: 550 no such user"), message: ""), "recipientRejected")
        XCTAssertEqual(DiagnosticsSignature.code(for: FalconError.network("connection closed by peer"), message: ""), "connectionClosed")
        XCTAssertEqual(DiagnosticsSignature.code(for: URLError(.notConnectedToInternet), message: ""), "offline")
        XCTAssertEqual(DiagnosticsSignature.code(for: URLError(.timedOut), message: ""), "timeout")
        XCTAssertEqual(DiagnosticsSignature.code(for: CocoaError(.fileReadNoSuchFile), message: ""), "fileMissing")
        XCTAssertEqual(DiagnosticsSignature.code(for: POSIXError(.ECONNRESET), message: ""), "connectionReset")
        XCTAssertEqual(DiagnosticsSignature.code(for: CancellationError(), message: ""), "cancelled")
        struct OddError: Error {}
        XCTAssertEqual(DiagnosticsSignature.code(for: OddError(), message: "strange"), "OddError")
    }

    func testCrashSignatures() {
        XCTAssertEqual(DiagnosticsSignature.make(area: "Crash", code: DiagnosticsSignature.crashCode(exception: "EXC_BAD_ACCESS", signal: "SIGSEGV"),
                                                 place: "FalconMail"), "Crash.EXC_BAD_ACCESS.SIGSEGV@FalconMail")
        XCTAssertEqual(DiagnosticsSignature.make(area: "Crash", code: "EXC_CRASH.SIGABRT", place: "libc++abi.dylib"),
                       "Crash.EXC_CRASH.SIGABRT@libcabi.dylib")
    }

    /// A crash report's symbols, down to the type and function every build shares.
    func testSymbolsAreReadDownToTheirTypeAndFunction() {
        let cases: [(String?, String?)] = [
            ("-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]", "NSAssertionHandler.handleFailureInMethod"),
            ("+[NSException raise:format:]", "NSException.raise"),
            ("-[NSView(NSConstraintBasedLayout) _layoutSubtreeWithOldSize:]", "NSView._layoutSubtreeWithOldSize"),
            ("-[_TtC10FalconMail11AppDelegate applicationDidFinishLaunching:]", "AppDelegate.applicationDidFinishLaunching"),
            ("-[__NSArrayM objectAtIndexedSubscript:]", "NSArrayM.objectAtIndexedSubscript"),
            ("closure #1 in AppModel.openMessage(id:)", "AppModel.openMessage"),
            ("implicit closure #2 in closure #1 in MessageList.body.getter", "MessageList.body.getter"),
            ("specialized Array.subscript.getter", "Array.subscript.getter"),
            ("partial apply for closure #3 in Store.save(_:)", "Store.save"),
            ("protocol witness for View.body.getter in conformance MessageList", "MessageList.body.getter"),
            ("generic specialization <Swift.Int> of Swift._ArrayBuffer._checkInoutAndNativeTypeCheckedBounds(_:wasNativeTypeChecked:)",
             "Swift._ArrayBuffer._checkInoutAndNativeTypeCheckedBounds"),
            ("Swift._assertionFailure(_: Swift.StaticString, _: Swift.String, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never",
             "Swift._assertionFailure"),
            ("@objc AppDelegate.application(_:open:)", "AppDelegate.application"),
            ("static FalconCore.AccountStore.shared.getter", "AccountStore.shared.getter"),
            ("WebCore::Document::updateStyleIfNeeded()", "WebCore.Document.updateStyleIfNeeded"),
            ("__exceptionPreprocess", "exceptionPreprocess"),
            ("_CF_forwarding_prep_0", "CF_forwarding_prep"),
            ("???", nil), ("", nil), (nil, nil),
        ]
        for (symbol, function) in cases {
            XCTAssertEqual(CrashIdentity.function(symbol), function, symbol ?? "nil")
        }
    }

    /// A Swift closure's symbol writes its own type before the function it is in, and a thunk
    /// only passes a call on: once `Sendable`, `closure`, `defer` and `callee_guaranteed` stood
    /// in for the function.
    func testClosuresAreReadAsTheFunctionTheyAreInAndThunksNameNothing() {
        let cases: [(String, String?)] = [
            ("closure #1 @Sendable () -> () in AppModel.refresh()", "AppModel.refresh"),
            ("closure #1 (Swift.String) -> Swift.Bool in MessageList.filter(_:)", "MessageList.filter"),
            ("closure #2 @MainActor (Swift.Result<(), Swift.Error>) -> () in closure #1 in Outbox.send(_:)", "Outbox.send"),
            ("$defer #1 () in Store.save()", "Store.save"),
            ("(1) suspend resume partial function for closure #1 @Sendable () async -> () in AppModel.refresh()", "AppModel.refresh"),
            ("__35-[NSWindow _changeKeyAndMainLimitedOK:]_block_invoke", "NSWindow._changeKeyAndMainLimitedOK"),
            ("thunk for @escaping @callee_guaranteed () -> ()", nil),
            ("reabstraction thunk helper from @escaping @callee_guaranteed () -> () to @escaping @callee_unowned @convention(block) () -> ()", nil),
            ("partial apply for thunk for @escaping @callee_guaranteed @Sendable @async () -> ()", nil),
        ]
        for (symbol, function) in cases {
            XCTAssertEqual(CrashIdentity.function(symbol), function, symbol)
        }
    }

    /// The words of a reason as a signature and title keep them.
    private func words(_ reason: String, at function: String? = nil) -> [String] {
        let place = CrashIdentity.Place(binary: "CoreFoundation", function: function, own: false)
        return CrashIdentity.words(reason, place: place).words
    }

    /// A crash's reason, down to the first words of its first clause: nothing quoted, numbered or
    /// pathed, and no word left dangling at the end.
    func testAReasonIsReadDownToItsFirstWords() {
        XCTAssertEqual(words("Invalid parameter not satisfying: row >= 0"), ["Invalid", "parameter", "not", "satisfying", "row"])
        XCTAssertFalse(CrashIdentity.words("Invalid parameter not satisfying: row >= 0").cut)
        XCTAssertEqual(words("no account for <addr:1a2b3c4d> in ~/Library/x"), ["no", "account"])
        XCTAssertEqual(words("-[NSNull length]: unrecognized selector sent to instance 0x6000037a4ce0"),
                       ["NSNull", "length", "unrecognized", "selector", "sent", "to", "instance"])
        let long = CrashIdentity.words("Could not find the row for the index in the table")
        XCTAssertEqual(long.words, ["Could", "not", "find", "the", "row"], "seven words at most, none left dangling")
        XCTAssertTrue(long.cut)
        XCTAssertEqual(words("Could not open 'Invoice ACME.pdf' for 3 seconds"), ["Could", "not", "open", "for", "seconds"])
        XCTAssertEqual(words("12 34 5678"), [])
        XCTAssertEqual(CrashIdentity.camelCase(["Invalid", "parameter", "not"]), "invalidParameterNot")
        XCTAssertEqual(CrashIdentity.camelCase(["NSArrayM", "objectAtIndex"]), "NSArrayMObjectAtIndex")
        let (exception, reason) = CrashIdentity.reason(inApplicationSpecificInformation: [
            "abort() called",
            "*** Terminating app due to uncaught exception 'NSRangeException', reason: 'index 3 beyond bounds'",
        ])
        XCTAssertEqual(exception, "NSRangeException")
        XCTAssertEqual(reason, "index 3 beyond bounds")
        XCTAssertEqual(CrashIdentity.reason(inApplicationSpecificInformation: ["Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range"]).reason,
                       "Index out of range")
        XCTAssertNil(CrashIdentity.reason(inApplicationSpecificInformation: ["Fatal error"]).reason)
        XCTAssertNil(CrashIdentity.reason(inApplicationSpecificInformation: ["abort() called"]).reason)
    }

    /// Five words cut a reason off wherever they ended, `Range out` and `Database schema is newer
    /// than`. Its first clause is read now, with the method it names left out when that is the
    /// crash's place already, and a reason longer than the words kept says so.
    func testAReasonReadsAsAPhrase() {
        XCTAssertEqual(words("*** -[__NSCFString substringWithRange:]: Range {10, 5} out of bounds; string length 3", at: "NSString.substringWithRange"),
                       ["Range", "out", "of", "bounds"])
        XCTAssertEqual(words("*** -[__NSArrayM objectAtIndexedSubscript:]: index 3 beyond bounds [0 .. 2]", at: "NSArrayM.objectAtIndexedSubscript"),
                       ["index", "beyond", "bounds"])
        XCTAssertEqual(words("*** -[__NSArrayM objectAtIndexedSubscript:]: index 3 beyond bounds [0 .. 2]", at: "NSArrayM.removeObject"),
                       ["NSArrayM", "objectAtIndexedSubscript", "index", "beyond", "bounds"], "another place: the method says where")
        let schema = CrashIdentity.words("Database schema is newer than this build supports (v12 > v10)")
        XCTAssertEqual(schema.words, ["Database", "schema", "is", "newer", "than", "this", "build"])
        XCTAssertTrue(schema.cut, "the reason goes on")
        XCTAssertEqual(CrashIdentity.words("The operation couldn’t be completed. (Cocoa error 4.)").words, ["The", "operation", "couldn’t", "be", "completed"])
    }

    // MARK: Titles

    func testTitlesForTheContractExamples() {
        XCTAssertEqual(DiagnosticsTitle.make(kind: .warning, area: "IMAP", code: "throttled"),
                       "The mail server paused the connection: too many requests")
        XCTAssertEqual(DiagnosticsTitle.make(kind: .error, area: "SMTP", code: "auth"),
                       "Sending a message failed: the server refused the password")
        XCTAssertEqual(DiagnosticsTitle.make(kind: .error, area: "Archive", code: "diskFull"),
                       "Archiving mail failed: this Mac is out of disk space")
        XCTAssertEqual(DiagnosticsTitle.make(kind: .error, area: "Alert", code: "offline"),
                       "FalconMail showed an error: this Mac is offline")
        XCTAssertEqual(DiagnosticsTitle.make(kind: .crash, area: "crash", code: "EXC_BAD_ACCESS.SIGSEGV"),
                       "FalconMail crashed: it used memory it should not have")
        XCTAssertEqual(DiagnosticsTitle.make(kind: .launch, area: "launch", code: "unclean"),
                       "FalconMail started again after it quit unexpectedly")
    }

    func testTitlesAreShortPlainAndFreeOfValues() {
        let areas = ["IMAP", "SMTP", "Actions", "Rules", "Mute", "Archive", "Import", "Drafts", "SignIn", "OAuth", "Update",
                     "Install", "Alert", "Sync", "Signatures", "SomethingNew"]
        let codes = ["throttled", "auth", "offline", "dns", "timeout", "noMailbox", "corrupt", "serverError", "notSignedIn",
                     "couldNotReadTheOriginal", "unknown"]
        for kind in DiagnosticsKind.allCases {
            for area in areas {
                for code in codes {
                    let title = DiagnosticsTitle.make(kind: kind, area: area, code: code)
                    XCTAssertLessThanOrEqual(title.count, 120)
                    XCTAssertFalse(title.contains(where: \.isNumber), title)
                    XCTAssertFalse(title.contains("<"), title)
                    XCTAssertEqual(title.first?.isUppercase, true, title)
                    XCTAssertEqual(title, DiagnosticsTitle.make(kind: kind, area: area, code: code))
                }
            }
        }
    }

    // MARK: Fitting context

    func testContextIsCutToSizeKeepingTheStart() {
        let frames = JSONValue.array((0..<2_000).map { .object(["imageOffset": .int(Int64($0)), "symbol": .string("frame \($0)")]) })
        let value = JSONValue.object(["threads": .array([frames, frames]), "exception": .string("EXC_BAD_ACCESS")])
        let fitted = value.fitted(to: DiagnosticsEvent.maxContextBytes)
        XCTAssertLessThanOrEqual(fitted.serialised.count, DiagnosticsEvent.maxContextBytes)
        XCTAssertEqual(fitted["truncated"], .bool(true))
        XCTAssertEqual(fitted["exception"], .string("EXC_BAD_ACCESS"))
        XCTAssertEqual(fitted["threads"]?.arrayValue?.first?.arrayValue?.first?["imageOffset"], .int(0))
        XCTAssertEqual(value.fitted(to: 1_000_000), value, "what fits is left alone")
    }

    func testEventHoldsFieldsToTheirLimits() {
        let event = DiagnosticsEvent(kind: .error, signature: "A.b@C.swift:1", title: String(repeating: "t", count: 300), area: "A",
                                     firstAt: Date(), message: String(repeating: "m", count: 5_000),
                                     context: .object(["big": .string(String(repeating: "x", count: 40_000))]))
        XCTAssertEqual(event.title.count, 120)
        XCTAssertEqual(event.message.count, 2_000)
        XCTAssertLessThanOrEqual(event.context.serialised.count, DiagnosticsEvent.maxContextBytes)
        let json = String(decoding: try! DiagnosticsJSON.encoder.encode(event), as: UTF8.self)
        XCTAssertTrue(json.contains(#""account":null"#), "the contract spells out a null account")
    }

    func testStableIDsAreUUIDs() {
        let a = DiagnosticsEvent.stableID("ips:install:incident")
        XCTAssertEqual(a, DiagnosticsEvent.stableID("ips:install:incident"))
        XCTAssertNotEqual(a, DiagnosticsEvent.stableID("ips:install:other"))
        XCTAssertNotNil(UUID(uuidString: a))
    }
}
