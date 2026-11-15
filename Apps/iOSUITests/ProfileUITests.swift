import XCTest

/// The Profil on iPhone, on the fakes signed in with Apple: Settings' account row opens it, it shows the
/// Compte and Sécurité cards, and the account ID row says it was copied. Debug fakes only.
@MainActor
final class ProfileUITests: XCTestCase {
    private static let launchTimeout: TimeInterval = 60
    private static let uiTimeout: TimeInterval = 15

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-useFakes", "YES", "-fakeSignIn", "apple", "-sheet", "settings"]
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Scrolls until `id` is on screen.
    private func reveal(_ id: String) -> XCUIElement {
        let target = element(id)
        var tries = 0
        while !(target.exists && target.isHittable), tries < 6 {
            app.swipeUp()
            tries += 1
        }
        return target
    }

    /// The account row, once the fake sign-in has reached Settings (signed out it says "Not Signed In").
    private func openProfile() {
        let row = element("account.current")
        XCTAssertTrue(row.waitForExistence(timeout: Self.launchTimeout), "Settings without its account row")
        let signedIn = NSPredicate(format: "NOT (label CONTAINS[c] 'Not Signed In')")
        expectation(for: signedIn, evaluatedWith: row)
        waitForExpectations(timeout: Self.uiTimeout)
        row.tap()
        XCTAssertTrue(element("profile.account").waitForExistence(timeout: Self.uiTimeout), "Profil not opened")
    }

    func testAccountRowOpensProfileWithAccountAndSecurity() throws {
        openProfile()
        XCTAssertTrue(element("profile.methodBadge").exists)
        XCTAssertTrue(element("profile.account.id").exists)
        XCTAssertTrue(element("profile.account.sync").exists)
        XCTAssertTrue(reveal("profile.security").exists)
        XCTAssertTrue(reveal("profile.security.signIn").exists)
        XCTAssertTrue(reveal("profile.security.signOut").exists)
        XCTAssertTrue(reveal("profile.security.delete").exists)

        app.swipeDown()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "profile"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testIDRowSaysCopied() throws {
        openProfile()
        let id = element("profile.account.id")
        let before = id.label
        id.tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: id)
        waitForExpectations(timeout: Self.uiTimeout)
    }

    /// Travel Documents rows open the Travel Documents page over the Profil.
    func testDocumentsRowOpensTravelDocuments() throws {
        openProfile()
        let row = reveal("profile.security.documents")
        XCTAssertTrue(row.exists, "Profil without its Travel Documents row")
        row.tap()
        // Only the Travel Documents page has this row.
        XCTAssertTrue(app.staticTexts["Delete All Travel Documents"].firstMatch.waitForExistence(timeout: Self.uiTimeout),
                      "Travel Documents not opened")
    }
}
