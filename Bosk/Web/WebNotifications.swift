import AppKit
import BoskCore
import UserNotifications
import WebKit

/// Website notifications (the page's `Notification` API and a service worker's
/// `showNotification`), shown as Mac notifications. WebKit has no public API for them on macOS,
/// so this uses its private C API (a notification provider) and private delegate calls.
/// A macOS update can remove them: then sites cannot show notifications, and nothing else breaks.
///
/// Private windows get no notifications: WebKit denies the permission in a data store
/// that is not saved to disk, before it asks Bosk.
@MainActor
enum WebNotifications {
    // MARK: Answers

    /// The user's answer for each origin (`SiteOrigin`), saved: a site asks only once.
    private static let answersKey = "BoskNotificationPermissions"

    static func answer(forOrigin origin: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: answersKey) as? [String: Bool])?[origin]
    }

    /// "Off" stops new notifications at once. "On" works when the page loads again,
    /// because the page keeps the answer it got.
    static func set(_ answer: Bool, forOrigin origin: String) {
        var answers = UserDefaults.standard.dictionary(forKey: answersKey) as? [String: Bool] ?? [:]
        answers[origin] = answer
        UserDefaults.standard.set(answers, forKey: answersKey)
    }

    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme, let host = url.host(), !host.isEmpty else { return nil }
        return SiteOrigin.key(scheme: scheme, host: host, port: url.port)
    }

    /// Asks the user, once for each site. The page can ask only from a click, so its tab is on screen.
    static func requestPermission(for origin: WKSecurityOrigin, in tab: Tab) async -> Bool {
        let key = SiteOrigin.key(scheme: origin.protocol, host: origin.host, port: origin.port)
        if let answer = answer(forOrigin: key) { return answer }
        guard api != nil, !tab.isPrivate, let window = tab.store?.window else { return false }
        let allowed = await PageDialogs.confirm("Allow “\(origin.host)” to show notifications?", host: nil, in: window,
                                                confirmTitle: "Allow", cancelTitle: "Don’t Allow")
        set(allowed, forOrigin: key)
        // macOS asks once if Bosk can show notifications at all. A web app's helper asks for itself.
        if allowed, tab.store?.isWebApp != true {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        return allowed
    }

    // MARK: WebKit

    private static let api = WebKitNotificationAPI()
    /// The manager of the service worker notifications: one for the app.
    private static let workerManager = api?.workerManager()
    private static let storeDelegate = DataStoreDelegate()
    private static var installedOnce = false
    /// WKNotificationProviderV0: version and client info, then 7 callbacks. Kept for the app's life.
    private static let provider: UnsafeMutablePointer<UnsafeRawPointer?> = {
        let provider = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 9)
        provider.initialize(repeating: nil, count: 9)
        provider[2] = unsafeBitCast(showCallback, to: UnsafeRawPointer.self)
        provider[3] = unsafeBitCast(cancelCallback, to: UnsafeRawPointer.self)
        return provider
    }()

    /// Each new web view configuration has its own process pool, with its own notification
    /// manager, so each web view sets the provider on its pool. Setting it again on a pool
    /// changes nothing. (A saved list of pools could keep the address of a pool that is gone.)
    static func install(on webView: WKWebView) {
        guard let api, let page = api.page(webView), let workerManager else { return }
        if !installedOnce {
            installedOnce = true
            api.setProvider(workerManager, provider)
            // The saved answers, so a page knows them before it asks (`Notification.permission`).
            WKWebsiteDataStore.default().perform(NSSelectorFromString("set_delegate:"), with: storeDelegate)
        }
        api.setProvider(api.contextManager(api.pageContext(page)), provider)
    }

    /// The browser windows' tabs and the saved web apps' tabs.
    private static var allTabs: [Tab] { ((NSApp.delegate as? AppDelegate)?.allTabs ?? []) + WebAppHost.shared.tabs }

    /// The manager that has the tab's notifications. Nil when the tab sleeps or is gone.
    private static func manager(ofTab id: UUID?, api: WebKitNotificationAPI) -> UnsafeRawPointer? {
        let tab = allTabs.first { $0.id == id }
        return tab?.webView.flatMap(api.page).map { api.contextManager(api.pageContext($0)) }
    }

    // WebKit calls the provider on the main thread. Its pointers are valid only during the call.
    private static let showCallback: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeRawPointer?) -> Void = { page, notification, _ in
        nonisolated(unsafe) let page = page, notification = notification
        MainActor.assumeIsolated { show(notification, page: page) }
    }

    private static let cancelCallback: @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void = { notification, _ in
        nonisolated(unsafe) let notification = notification
        MainActor.assumeIsolated {
            guard let api else { return }
            let identifier = identifier(of: notification, api: api)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            for session in WebAppHost.shared.sessions { session.removeNotification(identifier) }
            shown[identifier] = nil
        }
    }

    /// The shown notifications, by identifier, until Bosk quits: WebKit's IDs are new each launch.
    private struct Shown {
        var webKitID: UInt64
        var isPersistent: Bool
        var tabID: UUID?
    }
    private static var shown: [String: Shown] = [:]

    private static func origin(of notification: UnsafeRawPointer, api: WebKitNotificationAPI) -> String? {
        guard let origin = api.securityOrigin(notification),
              let scheme = api.string(api.copyProtocol(origin)), let host = api.string(api.copyHost(origin)) else { return nil }
        return SiteOrigin.key(scheme: scheme, host: host, port: Int(api.port(origin)))
    }

    /// A notification with a tag replaces the site's earlier one with the same tag, as in Chrome.
    private static func identifier(of notification: UnsafeRawPointer, api: WebKitNotificationAPI) -> String {
        let tag = api.string(api.copyTag(notification)) ?? ""
        if !tag.isEmpty, let origin = origin(of: notification, api: api) { return "web.\(origin).\(tag)" }
        return "web.\(api.id(notification))"
    }

    private static func show(_ notification: UnsafeRawPointer, page: UnsafeRawPointer?) {
        guard let api, let origin = origin(of: notification, api: api),
              answer(forOrigin: origin) == true else { return }
        let identifier = identifier(of: notification, api: api)
        let isPersistent = api.isPersistent(notification)
        let tab = page.flatMap { page in allTabs.first { $0.webView.flatMap(api.page) == page } }
        shown[identifier] = Shown(webKitID: api.id(notification), isPersistent: isPersistent, tabID: tab?.id)

        let content = UNMutableNotificationContent()
        let host = URL(string: origin)?.host() ?? origin
        content.title = api.string(api.copyTitle(notification)) ?? ""
        if content.title.isEmpty { content.title = host }
        content.subtitle = host
        content.body = api.string(api.copyBody(notification)) ?? ""
        content.sound = .default
        content.userInfo = ["origin": origin]
        let id = api.id(notification)
        let tabID = tab?.id
        // A saved web app shows its notifications itself, with its own name and icon. A service
        // worker's notification has no page: it goes to the web app open on the same site.
        let webApp = tab.flatMap(WebAppHost.shared.session(for:))
            ?? (tab == nil ? WebAppHost.shared.sessions.first { self.origin(of: $0.tab?.url) == origin } : nil)
        if let webApp {
            webApp.notify(identifier: identifier, title: content.title, subtitle: content.subtitle, body: content.body)
            if let manager = isPersistent ? workerManager : manager(ofTab: tabID, api: api) { api.didShow(manager, id) }
            return
        }
        Task {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            // The page's `onshow`. The tab can be gone after the wait.
            if let manager = isPersistent ? workerManager : manager(ofTab: tabID, api: api) { api.didShow(manager, id) }
        }
    }

    /// The user clicked a notification: show its tab, then tell the page (`onclick`,
    /// or the service worker's `notificationclick`).
    static func clicked(identifier: String, origin: String?) {
        let delegate = NSApp.delegate as? AppDelegate
        let record = shown[identifier]
        let tabs = allTabs.filter { !$0.isPrivate }
        // The tab that showed it, or else one open on the same site (after a reload or a relaunch).
        let tab = tabs.first { $0.id == record?.tabID } ?? tabs.first { self.origin(of: $0.url) == origin }
        // A web app's helper is already in front: it got the click.
        if let tab, tab.store?.isWebApp != true {
            delegate?.showTab(id: tab.id)
            NSApp.activate()
        }
        guard let api, let record,
              let manager = record.isPersistent ? workerManager : manager(ofTab: record.tabID, api: api) else { return }
        api.didClick(manager, record.webKitID)
    }

    nonisolated static func isWebNotification(_ identifier: String) -> Bool { identifier.hasPrefix("web.") }
}

/// Gives WebKit the saved answers. WebKit can call it off the main thread, so it reads
/// UserDefaults (safe on any thread), not `WebNotifications`.
private final class DataStoreDelegate: NSObject {
    @objc func notificationPermissionsForWebsiteDataStore(_ dataStore: WKWebsiteDataStore) -> NSDictionary {
        UserDefaults.standard.dictionary(forKey: "BoskNotificationPermissions") as NSDictionary? ?? [:]
    }
}

/// The private C functions of WebKit for notifications. Nil when one is missing.
private struct WebKitNotificationAPI {
    typealias Ref = UnsafeRawPointer
    let setProvider: @convention(c) (Ref, Ref) -> Void
    let pageContext: @convention(c) (Ref) -> Ref
    let contextManager: @convention(c) (Ref) -> Ref
    let workerManager: @convention(c) () -> Ref
    let didShow: @convention(c) (Ref, UInt64) -> Void
    let didClick: @convention(c) (Ref, UInt64) -> Void
    let id: @convention(c) (Ref) -> UInt64
    let isPersistent: @convention(c) (Ref) -> Bool
    let copyTitle: @convention(c) (Ref) -> Ref?
    let copyBody: @convention(c) (Ref) -> Ref?
    let copyTag: @convention(c) (Ref) -> Ref?
    let securityOrigin: @convention(c) (Ref) -> Ref?
    let copyProtocol: @convention(c) (Ref) -> Ref?
    let copyHost: @convention(c) (Ref) -> Ref?
    let port: @convention(c) (Ref) -> UInt16
    private let copyCFString: @convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>?
    private let release: @convention(c) (Ref) -> Void
    private let pageRef: @convention(c) (WKWebView, Selector) -> Ref?
    private static let pageRefSelector = NSSelectorFromString("_pageRefForTransitionToWKWebView")

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW) else { return nil }
        func load<T>(_ name: String) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
        // The type must be as tested, or a call with other types can crash.
        guard let method = class_getInstanceMethod(WKWebView.self, Self.pageRefSelector),
              let types = method_getTypeEncoding(method), String(cString: types) == "^{OpaqueWKPage=}16@0:8",
              let setProvider: @convention(c) (Ref, Ref) -> Void = load("WKNotificationManagerSetProvider"),
              let pageContext: @convention(c) (Ref) -> Ref = load("WKPageGetContext"),
              let contextManager: @convention(c) (Ref) -> Ref = load("WKContextGetNotificationManager"),
              let workerManager: @convention(c) () -> Ref = load("WKNotificationManagerGetSharedServiceWorkerNotificationManager"),
              let didShow: @convention(c) (Ref, UInt64) -> Void = load("WKNotificationManagerProviderDidShowNotification"),
              let didClick: @convention(c) (Ref, UInt64) -> Void = load("WKNotificationManagerProviderDidClickNotification"),
              let id: @convention(c) (Ref) -> UInt64 = load("WKNotificationGetID"),
              let isPersistent: @convention(c) (Ref) -> Bool = load("WKNotificationGetIsPersistent"),
              let copyTitle: @convention(c) (Ref) -> Ref? = load("WKNotificationCopyTitle"),
              let copyBody: @convention(c) (Ref) -> Ref? = load("WKNotificationCopyBody"),
              let copyTag: @convention(c) (Ref) -> Ref? = load("WKNotificationCopyTag"),
              let securityOrigin: @convention(c) (Ref) -> Ref? = load("WKNotificationGetSecurityOrigin"),
              let copyProtocol: @convention(c) (Ref) -> Ref? = load("WKSecurityOriginCopyProtocol"),
              let copyHost: @convention(c) (Ref) -> Ref? = load("WKSecurityOriginCopyHost"),
              let port: @convention(c) (Ref) -> UInt16 = load("WKSecurityOriginGetPort"),
              let copyCFString: @convention(c) (CFAllocator?, Ref) -> Unmanaged<CFString>? = load("WKStringCopyCFString"),
              let release: @convention(c) (Ref) -> Void = load("WKRelease") else { return nil }
        self.setProvider = setProvider
        self.pageContext = pageContext
        self.contextManager = contextManager
        self.workerManager = workerManager
        self.didShow = didShow
        self.didClick = didClick
        self.id = id
        self.isPersistent = isPersistent
        self.copyTitle = copyTitle
        self.copyBody = copyBody
        self.copyTag = copyTag
        self.securityOrigin = securityOrigin
        self.copyProtocol = copyProtocol
        self.copyHost = copyHost
        self.port = port
        self.copyCFString = copyCFString
        self.release = release
        self.pageRef = unsafeBitCast(method_getImplementation(method), to: (@convention(c) (WKWebView, Selector) -> Ref?).self)
    }

    func page(_ webView: WKWebView) -> Ref? { pageRef(webView, Self.pageRefSelector) }

    /// Takes a copied WebKit string (a "Copy" function's result) and releases it.
    func string(_ copied: Ref?) -> String? {
        guard let copied else { return nil }
        defer { release(copied) }
        return copyCFString(nil, copied)?.takeRetainedValue() as String?
    }
}

/// Clicks on Mac notifications. Website notifications also show while Bosk is in front, as in
/// Chrome. Extension notifications keep the old behavior: they show only when Bosk is not in front.
final class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationClickHandler()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        WebNotifications.isWebNotification(notification.request.identifier) ? [.banner, .list, .sound] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        let origin = response.notification.request.content.userInfo["origin"] as? String
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run {
            guard WebNotifications.isWebNotification(identifier) else { return }
            WebNotifications.clicked(identifier: identifier, origin: origin)
        }
    }
}
