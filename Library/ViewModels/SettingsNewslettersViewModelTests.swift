import Foundation
import XCTest
import ReactiveSwift
import Prelude
@testable import KsApi
@testable import Library
import ReactiveExtensions_TestHelpers

internal final class SettingsNewslettersViewModelTests: TestCase {
  let vm = SettingsNewslettersViewModel()

  let currentUser = TestObserver<User, Never>()

  internal override func setUp() {
    super.setUp()
    self.vm.outputs.currentUser.observe(self.currentUser.observer)
  }

  func testCurrentUserEmits_OnViewDidLoad() {

    let user = User.template

    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: user))

    self.currentUser.assertValueCount(0)

    self.vm.inputs.viewDidLoad()
    self.currentUser.assertValueCount(1, "currentUser should emit after viewDidLoad.")
  }

  func testCurrentUserEmits_WhenDelegateIsCalled() {

    let user = User.template
    AppEnvironment.login(AccessTokenEnvelope(accessToken: "deadbeef", user: user))

    self.vm.inputs.didUpdate(user: user)
    self.currentUser.assertValueCount(1, "currentUser should emit after user updates.")
  }
}
