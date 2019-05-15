import KsApi
import LiveStream
import Prelude
import ReactiveSwift
import Result

public protocol ProjectPamphletViewModelInputs {
  /// Call when "Back this project" is tapped
  func backThisProjectTapped()

  /// Call with the project given to the view controller.
  func configureWith(projectOrParam: Either<Project, Param>, refTag: RefTag?)

  /// Call when the view loads.
  func viewDidLoad()

  /// Call after the view loads and passes the initial TopConstraint constant.
  func initial(topConstraint: CGFloat)

  func viewDidAppear(animated: Bool)

  /// Call when the view will appear, and pass the animated parameter.
  func viewWillAppear(animated: Bool)

  /// Call when the view will transition to a new trait collection.
  func willTransition(toNewCollection collection: UITraitCollection)
}

public protocol ProjectPamphletViewModelOutputs {
  /// Emits a project that should be used to configure all children view controllers.
  var configureChildViewControllersWithProjectAndLiveStreams: Signal<(Project, [LiveStreamEvent],
    RefTag?), NoError> { get }

  /// Emits a project and refTag to be used to navigate to the reward selection screen
  var goToRewards: Signal<(Project, RefTag?), NoError> { get }

  /// Return this value from the view's `prefersStatusBarHidden` method.
  var prefersStatusBarHidden: Bool { get }

  /// Emits two booleans that determine if the navigation bar should be hidden, and if it should be animated.
  var setNavigationBarHiddenAnimated: Signal<(Bool, Bool), NoError> { get }

  /// Emits when the `setNeedsStatusBarAppearanceUpdate` method should be called on the view.
  var setNeedsStatusBarAppearanceUpdate: Signal<(), NoError> { get }

  /// Emits a float to update topLayoutConstraints constant.
  var topLayoutConstraintConstant: Signal<CGFloat, NoError> { get }

  var projectStateOutput: Signal<(ProjectStateCTAType, String?), NoError> { get }

  var projectAndBacking: Signal <(Project, Backing), NoError> { get }

}

public protocol ProjectPamphletViewModelType {
  var inputs: ProjectPamphletViewModelInputs { get }
  var outputs: ProjectPamphletViewModelOutputs { get }
}

public final class ProjectPamphletViewModel: ProjectPamphletViewModelType, ProjectPamphletViewModelInputs,
ProjectPamphletViewModelOutputs {

  public init() {

    let freshProjectAndLiveStreamsAndRefTag = self.configDataProperty.signal.skipNil()
      .takePairWhen(Signal.merge(
        self.viewDidLoadProperty.signal.mapConst(true),
        self.viewDidAppearAnimated.signal.filter(isTrue).mapConst(false)
      ))
      .map(unpack)
      .switchMap { projectOrParam, refTag, shouldPrefix in
        fetchProjectAndLiveStreams(projectOrParam: projectOrParam, shouldPrefix: shouldPrefix)
          .map { project, liveStreams in
            (project, liveStreams, refTag.map(cleanUp(refTag:)))
        }
    }

    let user = viewDidLoadProperty.signal
      .switchMap { _ in
        AppEnvironment.current.apiService.fetchUserSelf()
          .prefix(SignalProducer([AppEnvironment.current.currentUser].compact()))
          .demoteErrors()
    }

    self.goToRewards = freshProjectAndLiveStreamsAndRefTag
      .takeWhen(self.backThisProjectTappedProperty.signal)
      .map { project, _, refTag in
        return (project, refTag)
    }

    let project = freshProjectAndLiveStreamsAndRefTag
      .map { project, _, _ in project }

    let projectAndUser = Signal.combineLatest(project, user)

    let projectAndBackingEvent = projectAndUser
      .switchMap { project, backer in
        AppEnvironment.current.apiService.fetchBacking(forProject: project, forUser: backer)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .retry(upTo: 3)
          .map { (project, $0) }
          .materialize()
    }

    self.projectAndBacking = projectAndBackingEvent.values()

    self.projectStateOutput = Signal.combineLatest(project, user)
      .map { project, user in projectStateButton(backer: user, project: project) }

    self.configureChildViewControllersWithProjectAndLiveStreams = freshProjectAndLiveStreamsAndRefTag
      .map { project, liveStreams, refTag in (project, liveStreams ?? [], refTag) }

    self.prefersStatusBarHiddenProperty <~ self.viewWillAppearAnimated.signal.mapConst(true)

    self.setNeedsStatusBarAppearanceUpdate = Signal.merge(
      self.viewWillAppearAnimated.signal.ignoreValues(),
      self.willTransitionToCollectionProperty.signal.ignoreValues()
    )

    self.setNavigationBarHiddenAnimated = Signal.merge(
      self.viewDidLoadProperty.signal.mapConst((true, false)),
      self.viewWillAppearAnimated.signal.skip(first: 1).map { (true, $0) }
    )

    self.topLayoutConstraintConstant = self.initialTopConstraintProperty.signal.skipNil()
      .takePairWhen(self.willTransitionToCollectionProperty.signal.skipNil())
      .map(topLayoutConstraintConstant(initialTopConstraint:traitCollection:))

    let cookieRefTag = freshProjectAndLiveStreamsAndRefTag
      .map { project, _, refTag in
        cookieRefTagFor(project: project) ?? refTag
      }
      .take(first: 1)

    Signal.combineLatest(freshProjectAndLiveStreamsAndRefTag,
                         cookieRefTag,
                         self.viewDidAppearAnimated.signal.ignoreValues()
      )
      .map { (project: $0.0, liveStreamEvents: $0.1, refTag: $0.2, cookieRefTag: $1, _: $2) }
      .filter { _, liveStreamEvents, _, _, _ in liveStreamEvents != nil }
      .take(first: 1)
      .observeValues { project, liveStreamEvents, refTag, cookieRefTag, _ in
        AppEnvironment.current.koala.trackProjectShow(project,
                                                      liveStreamEvents: liveStreamEvents,
                                                      refTag: refTag,
                                                      cookieRefTag: cookieRefTag)
    }

    Signal.combineLatest(cookieRefTag.skipNil(), freshProjectAndLiveStreamsAndRefTag.map(first))
      .take(first: 1)
      .map(cookieFrom(refTag:project:))
      .skipNil()
      .observeValues { AppEnvironment.current.cookieStorage.setCookie($0) }
  }

  private let backThisProjectTappedProperty = MutableProperty(())
  public func backThisProjectTapped() {
    self.backThisProjectTappedProperty.value = ()
  }

  private let configDataProperty = MutableProperty<(Either<Project, Param>, RefTag?)?>(nil)
  public func configureWith(projectOrParam: Either<Project, Param>, refTag: RefTag?) {
    self.configDataProperty.value = (projectOrParam, refTag)
  }

  fileprivate let viewDidLoadProperty = MutableProperty(())
  public func viewDidLoad() {
    self.viewDidLoadProperty.value = ()
  }

  fileprivate let initialTopConstraintProperty = MutableProperty<CGFloat?>(nil)
  public func initial(topConstraint: CGFloat) {
    self.initialTopConstraintProperty.value = topConstraint
  }

  fileprivate let viewDidAppearAnimated = MutableProperty(false)
  public func viewDidAppear(animated: Bool) {
    self.viewDidAppearAnimated.value = animated
  }

  fileprivate let viewWillAppearAnimated = MutableProperty(false)
  public func viewWillAppear(animated: Bool) {
    self.viewWillAppearAnimated.value = animated
  }

  fileprivate let willTransitionToCollectionProperty =
    MutableProperty<UITraitCollection?>(nil)
  public func willTransition(toNewCollection collection: UITraitCollection) {
    self.willTransitionToCollectionProperty.value = collection
  }

  public let configureChildViewControllersWithProjectAndLiveStreams: Signal<(Project, [LiveStreamEvent],
    RefTag?), NoError>
  fileprivate let prefersStatusBarHiddenProperty = MutableProperty(false)
  public var prefersStatusBarHidden: Bool {
    return self.prefersStatusBarHiddenProperty.value
  }

  public let goToRewards: Signal<(Project, RefTag?), NoError>
  public let setNavigationBarHiddenAnimated: Signal<(Bool, Bool), NoError>
  public let setNeedsStatusBarAppearanceUpdate: Signal<(), NoError>
  public let topLayoutConstraintConstant: Signal<CGFloat, NoError>

  public let projectStateOutput: Signal<(ProjectStateCTAType, String?), NoError>
  public let projectAndBacking: Signal<(Project, Backing), NoError>

  public var inputs: ProjectPamphletViewModelInputs { return self }
  public var outputs: ProjectPamphletViewModelOutputs { return self }
}

private let cookieSeparator = "?"
private let escapedCookieSeparator = "%3F"

private func topLayoutConstraintConstant(initialTopConstraint: CGFloat,
                                         traitCollection: UITraitCollection) -> CGFloat {
  guard !traitCollection.isRegularRegular else {
    return 0.0
  }
   return traitCollection.isVerticallyCompact ? 0.0 : initialTopConstraint
}

// Extracts the ref tag stored in cookies for a particular project. Returns `nil` if no such cookie has
// been previously set.
private func cookieRefTagFor(project: Project) -> RefTag? {

  return AppEnvironment.current.cookieStorage.cookies?
    .filter { cookie in cookie.name == cookieName(project) }
    .first
    .map(refTagName(fromCookie:))
    .flatMap(RefTag.init(code:))
}

// Derives the name of the ref cookie from the project.
private func cookieName(_ project: Project) -> String {
  return "ref_\(project.id)"
}

// Tries to extract the name of the ref tag from a cookie. It has to do double work in case the cookie
// is accidentally encoded with a `%3F` instead of a `?`.
private func refTagName(fromCookie cookie: HTTPCookie) -> String {

  return cleanUp(refTagString: cookie.value)
}

// Tries to remove cruft from a ref tag.
private func cleanUp(refTag: RefTag) -> RefTag {
  return RefTag(code: cleanUp(refTagString: refTag.stringTag))
}

// Tries to remove cruft from a ref tag string.
private func cleanUp(refTagString: String) -> String {

  let secondPass = refTagString.components(separatedBy: escapedCookieSeparator)
  if let name = secondPass.first, secondPass.count == 2 {
    return String(name)
  }

  let firstPass = refTagString.components(separatedBy: cookieSeparator)
  if let name = firstPass.first, firstPass.count == 2 {
    return String(name)
  }

  return refTagString
}

// Constructs a cookie from a ref tag and project.
private func cookieFrom(refTag: RefTag, project: Project) -> HTTPCookie? {

  let timestamp = Int(AppEnvironment.current.scheduler.currentDate.timeIntervalSince1970)

  var properties: [HTTPCookiePropertyKey: Any] = [:]
  properties[.name]    = cookieName(project)
  properties[.value]   = "\(refTag.stringTag)\(cookieSeparator)\(timestamp)"
  properties[.domain]  = URL(string: project.urls.web.project)?.host
  properties[.path]    = URL(string: project.urls.web.project)?.path
  properties[.version] = 0
  properties[.expires] = AppEnvironment.current.dateType
    .init(timeIntervalSince1970: project.dates.deadline).date

  return HTTPCookie(properties: properties)
}

private func projectStateButton(backer: User, project: Project) -> (ProjectStateCTAType, String?) {
  let projectIsBacked = project.personalization.isBacking
  let projectRewardTitle = project.personalization.backing?.reward?.title

  switch project.state {
  case .live:
    return projectIsBacked! ? (ProjectStateCTAType.manage, projectRewardTitle ) : (ProjectStateCTAType.pledge, projectRewardTitle)
  case .canceled, .failed, .suspended, .successful:
    return projectIsBacked! ? (ProjectStateCTAType.viewBacking, projectRewardTitle) : (ProjectStateCTAType.viewRewards, projectRewardTitle)
  default:
    return (ProjectStateCTAType.viewRewards, projectRewardTitle)
  }
}

private func fetchProjectAndLiveStreams(projectOrParam: Either<Project, Param>, shouldPrefix: Bool)
  -> SignalProducer<(Project, [LiveStreamEvent]?), NoError> {

    let param = projectOrParam.ifLeft({ Param.id($0.id) }, ifRight: id)

    let projectAndLiveStreams = AppEnvironment.current.apiService.fetchProject(param: param)
      .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
      .demoteErrors()
      .flatMap { project -> SignalProducer<(Project, [LiveStreamEvent]?), NoError> in

        AppEnvironment.current.liveStreamService
          .fetchEvents(forProjectId: project.id, uid: AppEnvironment.current.currentUser?.id)
          .ksr_delay(AppEnvironment.current.apiDelayInterval, on: AppEnvironment.current.scheduler)
          .flatMapError { _ in SignalProducer(error: SomeError()) }
          .timeout(after: 5, raising: SomeError(), on: AppEnvironment.current.scheduler)
          .materialize()
          .map { (project, .some($0.value?.liveStreamEvents ?? [])) }
          .take(first: 1)
    }

    if let project = projectOrParam.left, shouldPrefix {
      return projectAndLiveStreams.prefix(value: (project, nil))
    }
    return projectAndLiveStreams
}

public enum ProjectStateCTAType {
  case pledge
  case manage
  case viewBacking
  case viewRewards

  public var buttonTitle: String {
    switch self {
    case .pledge:
      return "Back this project"
    case .manage:
      return "Manage"
    case .viewBacking:
      return "View your pledge"
    case .viewRewards:
      return "View rewards"
    }
  }

  public var buttonBackgroundColor: UIColor {
    switch self {
    case .pledge:
      return .ksr_green_500
    case .manage:
      return .ksr_blue
    case .viewBacking, .viewRewards:
      return .ksr_soft_black
    }
  }

  public var stackViewIsHidden: Bool {
    switch self {
    case .pledge, .viewBacking, .viewRewards:
      return true
    case .manage:
      return false
    }
  }
}
