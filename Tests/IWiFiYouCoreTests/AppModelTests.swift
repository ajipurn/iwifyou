import IWiFiYouCore
import Testing
@testable import iwifyou

@MainActor
@Test func rejectedApplyKeepsLastReadSnapshotAndRequiresRefresh() async {
    let model = AppModel(demo: true)
    model.selectedChannel = .fixed(6)
    #expect(model.canApply)

    model.fail(RouterError.rejected, lastKnown: .demo)
    #expect(model.statusText == "Permintaan ditolak")
    #expect(model.state.snapshot == .demo)
    #expect(!model.canApply)
    #expect(!model.canSelectChannel)

    await model.refresh()
    model.selectedChannel = .fixed(6)
    #expect(model.canApply)
}

@MainActor
@Test func invalidSessionDoesNotLookLikeDisconnectedNetwork() {
    let model = AppModel(demo: true)
    model.fail(RouterError.invalidSession, lastKnown: .demo)
    #expect(model.statusText == "Permintaan ditolak")
    guard case .rejected(_, let reason) = model.state else {
        Issue.record("Token rejection should retain request context")
        return
    }
    #expect(reason.contains("Token sesi"))
    #expect(!model.canApply)
}

@MainActor
@Test func expiredAdminSessionShowsLoginPrompt() {
    let model = AppModel(demo: true)
    model.fail(RouterError.loginRequired, lastKnown: .demo)
    #expect(model.statusText == "Perlu login")
    #expect(!model.canApply)
    guard case .needsLogin = model.state else {
        Issue.record("Expired admin session should ask for login")
        return
    }
}

@MainActor
@Test func adminSessionLockShowsSpecificStatus() {
    let model = AppModel(demo: true)
    model.fail(RouterError.adminSessionInUse)
    #expect(model.statusText == "Sesi admin dipakai")
    #expect(!model.canApply)
    #expect(!model.canSelectChannel)
}
