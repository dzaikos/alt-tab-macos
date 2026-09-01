import XCTest

final class WindowAdmissionResolverTests: XCTestCase {
    private func physical(wid: CGWindowID = 1, width: CGFloat = 800, height: CGFloat = 600,
                          level: CGWindowLevel = 0, parentWid: CGWindowID = 0) -> PhysicalSurface {
        PhysicalSurface(wid: wid, pid: 7, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            level: level, parentWid: parentWid)
    }

    private func semantic(title: String? = "Document", subrole: String? = kAXStandardWindowSubrole,
                          role: String? = kAXWindowRole, isMain: Bool? = false) -> SemanticSurface {
        SemanticSurface(title: title, subrole: subrole, role: role, isMain: isMain)
    }

    func testWidZeroIsRejected() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(wid: 0), semantic()), .reject(.invalidWindowId))
    }

    func testSheetRepresentsParentBeforeAttentionCanAcceptIt() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(parentWid: 9), semantic(), evidence: .attention),
            .represent(parentWid: 9, .attachedSurface))
    }

    func testExactAttentionAcceptsAxUnavailableNonZeroLevelSurface() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(width: 20, height: 20, level: 101), nil,
            evidence: .attention), .destination(.exactAttention))
    }

    func testMainWindowAcceptsUnknownSubroleAtAnyLevel() {
        let s = semantic(title: nil, subrole: kAXUnknownSubrole, isMain: true)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(width: 1, height: 1, level: 3), s),
            .destination(.mainWindow))
    }

    func testStandardWindowDoesNotDependOnLevelOrSize() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(width: 1, height: 1, level: 3), semantic()),
            .destination(.conventionalWindow))
    }

    func testStandardSubroleSurvivesMissingRole() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(level: 2), semantic(role: nil)),
            .destination(.conventionalWindow))
    }

    func testTitledDialogIsDestination() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(level: 1), semantic(subrole: kAXDialogSubrole)),
            .destination(.conventionalWindow))
    }

    func testUntitledDialogRemainsLatent() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), semantic(title: "", subrole: kAXDialogSubrole)),
            .latent(.untitledDialog))
    }

    func testFloatingPanelIsRejected() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), semantic(subrole: kAXFloatingWindowSubrole)),
            .reject(.auxiliarySurface))
    }

    func testMainFloatingPanelIsRejected() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), semantic(subrole: kAXFloatingWindowSubrole, isMain: true)),
            .reject(.auxiliarySurface))
    }

    func testAttentionDoesNotTurnFloatingPanelIntoDestination() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), semantic(subrole: kAXFloatingWindowSubrole),
            evidence: .attention), .reject(.auxiliarySurface))
    }

    func testNonMainCustomRootAtFloatingLevelIsAuxiliary() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(level: 3), semantic(subrole: kAXUnknownSubrole)),
            .reject(.auxiliarySurface))
    }

    func testCustomRootWithUnknownMainFlagAtFloatingLevelIsAuxiliary() {
        let s = semantic(subrole: kAXUnknownSubrole, isMain: nil)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(level: 3), s), .reject(.auxiliarySurface))
    }

    func testSteamLikeCustomRootNeedsNoAppException() {
        let s = semantic(title: "Steam", subrole: kAXUnknownSubrole)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), s), .destination(.customWindowRoot))
    }

    func testPowerPointLikePresentationNeedsNoAppException() {
        let s = semantic(title: "Slide Show", subrole: kAXUnknownSubrole, isMain: true)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(level: 3), s), .destination(.mainWindow))
    }

    func testCustomRootAtExactSizeBoundaryIsDestination() {
        let s = semantic(subrole: kAXUnknownSubrole)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(width: 100, height: 50), s),
            .destination(.customWindowRoot))
    }

    func testUndersizedCustomRootRemainsLatent() {
        let s = semantic(subrole: kAXUnknownSubrole)
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(width: 99, height: 50), s),
            .latent(.undersizedCustomSurface))
    }

    func testNonWindowRoleIsRejected() {
        XCTAssertEqual(WindowAdmissionResolver.resolve(physical(), semantic(subrole: kAXUnknownSubrole, role: kAXButtonRole)),
            .reject(.nonWindowRole))
    }

    func testLevelZeroAndSubstantialNonZeroLevelAcquireSemantics() {
        XCTAssertTrue(WindowAdmissionResolver.shouldAcquireSemantics(physical(width: 1, height: 1)))
        XCTAssertTrue(WindowAdmissionResolver.shouldAcquireSemantics(physical(level: 3)))
    }

    func testSmallNonZeroLevelAndAttachedSurfacesSkipOrdinaryAcquisition() {
        XCTAssertFalse(WindowAdmissionResolver.shouldAcquireSemantics(physical(width: 20, height: 20, level: 3)))
        XCTAssertFalse(WindowAdmissionResolver.shouldAcquireSemantics(physical(parentWid: 2)))
    }

    func testMutableEvidenceIsReevaluatedWithoutLatching() {
        let p = physical()
        XCTAssertEqual(WindowAdmissionResolver.resolve(p, semantic()), .destination(.conventionalWindow))
        XCTAssertEqual(WindowAdmissionResolver.resolve(p, semantic(title: nil, subrole: kAXUnknownSubrole)),
            .latent(.unsupportedSemantics))
        XCTAssertEqual(WindowAdmissionResolver.resolve(p, semantic(title: nil, subrole: kAXUnknownSubrole, isMain: true)),
            .destination(.mainWindow))
    }
}

final class ApplicationAdmissionResolverTests: XCTestCase {
    func testOrdinaryApplicationIsAdmittedDuringDiscovery() {
        XCTAssertTrue(ApplicationAdmissionResolver.accepts(isXpc: false, isZombie: false,
            isKnownUserFacingException: false, evidence: .discovery))
    }

    func testUnengagedXpcProcessIsNotAdmittedDuringDiscovery() {
        XCTAssertFalse(ApplicationAdmissionResolver.accepts(isXpc: true, isZombie: false,
            isKnownUserFacingException: false, evidence: .discovery))
    }

    func testExactAttentionAdmitsItsXpcOwner() {
        XCTAssertTrue(ApplicationAdmissionResolver.accepts(isXpc: true, isZombie: false,
            isKnownUserFacingException: false, evidence: .attention))
    }

    func testKnownUserFacingXpcExceptionStillWorksDuringDiscovery() {
        XCTAssertTrue(ApplicationAdmissionResolver.accepts(isXpc: true, isZombie: false,
            isKnownUserFacingException: true, evidence: .discovery))
    }

    func testZombieIsRejectedEvenWhenAttentionNamesIt() {
        XCTAssertFalse(ApplicationAdmissionResolver.accepts(isXpc: false, isZombie: true,
            isKnownUserFacingException: false, evidence: .attention))
    }
}

final class WindowlessApplicationResolverTests: XCTestCase {
    private func accepts(isRegular: Bool = false, isTerminated: Bool = false,
                         hasPlaceholder: Bool = false, hasWindow: Bool = false) -> Bool {
        WindowlessApplicationResolver.shouldCreate(isRegular: isRegular, isTerminated: isTerminated,
            hasExistingPlaceholder: hasPlaceholder, hasNonPhantomWindow: hasWindow)
    }

    func testRegularWindowlessApplicationGetsPlaceholder() {
        XCTAssertTrue(accepts(isRegular: true))
    }

    func testAccessoryApplicationNeverGetsPlaceholder() {
        XCTAssertFalse(accepts())
    }

    func testExistingPlaceholderRealWindowAndTerminationPreventPlaceholder() {
        XCTAssertFalse(accepts(isRegular: true, hasPlaceholder: true))
        XCTAssertFalse(accepts(isRegular: true, hasWindow: true))
        XCTAssertFalse(accepts(isRegular: true, isTerminated: true))
    }
}
