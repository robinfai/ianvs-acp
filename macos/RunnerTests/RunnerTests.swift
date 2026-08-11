import Cocoa
import Foundation
import FlutterMacOS
import LocalAuthentication
import Security
import XCTest
@testable import ACP_Client

class RunnerTests: XCTestCase {
  private var service: String!
  private var securityClient: FakeKeychainSecurityClient!
  private var store: KeychainSecretStore!

  override func setUp() {
    super.setUp()
    service = "\(KeychainSecretStore.productionService).tests.\(UUID().uuidString)"
    securityClient = FakeKeychainSecurityClient()
    store = KeychainSecretStore(service: service, securityClient: securityClient)
  }

  override func tearDown() {
    store = nil
    securityClient = nil
    service = nil
    super.tearDown()
  }

  func testBundleIdentifierIsProductionIdentifier() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ianvs.acp")
  }

  func testMainWindowUsesUnifiedFullSizeChrome() {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    window.configureWindowChrome()

    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.titleVisibility, .hidden)
    XCTAssertTrue(window.titlebarAppearsTransparent)
    XCTAssertEqual(window.titlebarSeparatorStyle, .none)
    XCTAssertEqual(window.toolbarStyle, .unified)
    XCTAssertEqual(
      window.toolbar?.identifier,
      MainFlutterWindow.chromeToolbarIdentifier
    )
    XCTAssertFalse(window.toolbar?.showsBaselineSeparator ?? true)
    XCTAssertFalse(window.toolbar?.allowsUserCustomization ?? true)
    XCTAssertFalse(window.toolbar?.autosavesConfiguration ?? true)
  }

  func testRegisteredDeepLinkScheme() {
    let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
      as? [[String: Any]]
    let schemes = urlTypes?.flatMap {
      $0["CFBundleURLSchemes"] as? [String] ?? []
    }

    XCTAssertTrue(schemes?.contains("ianvs-acp") == true)
  }

  func testStableReferenceUsesSha256Account() throws {
    let first = try store.put(
      namespace: "agent/Codex/env",
      key: "OPENAI_API_KEY",
      value: "first"
    )
    let second = try store.put(
      namespace: "agent/Codex/env",
      key: "OPENAI_API_KEY",
      value: "second"
    )
    let account = try account(from: first)

    XCTAssertEqual(first, second)
    XCTAssertEqual(account.count, 64)
    XCTAssertNotNil(account.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    XCTAssertEqual(try store.get(account: account), "second")
  }

  func testAccountSeparatesNamespaceAndKeyComponents() throws {
    let firstReference = try store.put(namespace: "ab", key: "c", value: "first")
    let secondReference = try store.put(namespace: "a", key: "bc", value: "second")
    let firstAccount = try account(from: firstReference)
    let secondAccount = try account(from: secondReference)

    XCTAssertNotEqual(firstReference, secondReference)
    XCTAssertEqual(try store.get(account: firstAccount), "first")
    XCTAssertEqual(try store.get(account: secondAccount), "second")
  }

  func testPutReadUpdateAndDeleteGenericPassword() throws {
    let reference = try store.put(
      namespace: "agent/Test/header",
      key: "Authorization",
      value: "Bearer first"
    )
    let account = try account(from: reference)

    XCTAssertEqual(try store.get(account: account), "Bearer first")
    let updatedReference = try store.put(
      namespace: "agent/Test/header",
      key: "Authorization",
      value: "Bearer second"
    )
    XCTAssertEqual(updatedReference, reference)
    XCTAssertEqual(try store.get(account: account), "Bearer second")

    try store.delete(account: account)
    XCTAssertNil(try store.get(account: account))
    XCTAssertNoThrow(try store.delete(account: account))
  }

  func testQueriesUseDataProtectionAndNonSynchronizingAccessibility() throws {
    let reference = try store.put(namespace: "namespace", key: "key", value: "value")
    let account = try account(from: reference)
    _ = try store.get(account: account)
    try store.delete(account: account)

    let addQuery = try XCTUnwrap(securityClient.addQueries.first)
    let queries = securityClient.updateQueries
      + [addQuery]
      + securityClient.copyQueries
      + securityClient.deleteQueries
    let dataProtectionQueries = queries.filter {
      $0[kSecUseDataProtectionKeychain] as? Bool == true
    }
    XCTAssertFalse(dataProtectionQueries.isEmpty)
    for query in dataProtectionQueries {
      XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
      XCTAssertEqual(query[kSecAttrService] as? String, service)
      XCTAssertEqual(query[kSecAttrAccount] as? String, account)
      XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
      XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    }
    XCTAssertEqual(
      addQuery[kSecAttrAccessible] as? String,
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    )
    let copyQuery = try XCTUnwrap(securityClient.copyQueries.first)
    XCTAssertEqual(copyQuery[kSecReturnData] as? Bool, true)
    XCTAssertEqual(copyQuery[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
    XCTAssertEqual(
      (copyQuery[kSecUseAuthenticationContext] as? LAContext)?
        .interactionNotAllowed,
      true
    )

    let standardQueries = queries.filter { $0[kSecUseDataProtectionKeychain] == nil }
    XCTAssertFalse(standardQueries.isEmpty)
    for query in standardQueries {
      XCTAssertEqual(query[kSecClass] as? String, kSecClassGenericPassword as String)
      XCTAssertEqual(query[kSecAttrService] as? String, service)
      XCTAssertEqual(query[kSecAttrAccount] as? String, account)
      XCTAssertEqual(query[kSecAttrSynchronizable] as? Bool, false)
    }
  }

  func testFallsBackToStandardKeychainWhenDataProtectionEntitlementIsMissing() throws {
    securityClient.updateStatuses = [errSecMissingEntitlement]

    let reference = try store.put(namespace: "namespace", key: "key", value: "value")
    let account = try account(from: reference)

    XCTAssertEqual(
      securityClient.updateQueries.first?[kSecUseDataProtectionKeychain] as? Bool,
      true
    )
    XCTAssertNil(securityClient.updateQueries.last?[kSecUseDataProtectionKeychain])
    let standardAdd = try XCTUnwrap(securityClient.addQueries.last)
    XCTAssertNil(standardAdd[kSecUseDataProtectionKeychain])
    XCTAssertNil(standardAdd[kSecAttrAccessible])
    XCTAssertEqual(try store.get(account: account), "value")
    try store.delete(account: account)
    XCTAssertNil(try store.get(account: account))
  }

  func testExplicitReadMayAllowKeychainInteraction() throws {
    let reference = try store.put(namespace: "namespace", key: "key", value: "value")
    let account = try account(from: reference)

    XCTAssertEqual(
      try store.get(account: account, allowInteraction: true),
      "value"
    )

    let copyQuery = try XCTUnwrap(securityClient.copyQueries.last)
    XCTAssertNil(copyQuery[kSecUseAuthenticationContext])
  }

  func testNonInteractiveReadReportsRequiredKeychainInteraction() throws {
    securityClient.copyStatuses = [
      errSecItemNotFound,
      errSecSuccess,
    ]

    XCTAssertThrowsError(
      try store.get(account: String(repeating: "a", count: 64))
    ) { error in
      guard case KeychainSecretStoreError.osStatus(let status) = error else {
        return XCTFail("Expected a Keychain OSStatus error, got \(error)")
      }
      XCTAssertEqual(status, errSecInteractionNotAllowed)
    }
    XCTAssertEqual(securityClient.copyQueries.count, 2)
    let dataQuery = securityClient.copyQueries[0]
    XCTAssertEqual(
      (dataQuery[kSecUseAuthenticationContext] as? LAContext)?
        .interactionNotAllowed,
      true
    )
    XCTAssertEqual(dataQuery[kSecReturnData] as? Bool, true)
    let existenceQuery = securityClient.copyQueries[1]
    XCTAssertNil(existenceQuery[kSecUseAuthenticationContext])
    XCTAssertEqual(existenceQuery[kSecReturnAttributes] as? Bool, true)
    XCTAssertNil(existenceQuery[kSecReturnData])
  }

  func testPutRetriesUpdateWhenConcurrentAddWins() throws {
    securityClient.updateStatuses = [errSecItemNotFound, errSecSuccess]
    securityClient.addStatuses = [errSecDuplicateItem]

    let reference = try store.put(namespace: "namespace", key: "key", value: "value")

    XCTAssertNotNil(reference.range(of: "^keychain://ianvs-acp/[0-9a-f]{64}$", options: .regularExpression))
    XCTAssertEqual(securityClient.updateQueries.count, 2)
    XCTAssertEqual(securityClient.addQueries.count, 1)
  }

  func testSystemKeychainCrudWithAdHocFallback() throws {
    let integrationService = "\(KeychainSecretStore.productionService).integration.\(UUID().uuidString)"
    let integrationStore = KeychainSecretStore(service: integrationService)
    defer { deleteAllSystemItems(service: integrationService) }

    let reference = try integrationStore.put(
      namespace: "agent/Test/header",
      key: "Authorization",
      value: "Bearer first"
    )
    let account = try account(from: reference)
    XCTAssertEqual(try integrationStore.get(account: account), "Bearer first")
    if try hostTeamIdentifier() != nil {
      XCTAssertEqual(
        try systemAccessibleAttribute(service: integrationService, account: account),
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
      )
    }

    _ = try integrationStore.put(
      namespace: "agent/Test/header",
      key: "Authorization",
      value: "Bearer second"
    )
    XCTAssertEqual(try integrationStore.get(account: account), "Bearer second")
    try integrationStore.delete(account: account)
    XCTAssertNil(try integrationStore.get(account: account))
  }

  func testUnknownKeychainMethodDoesNotRequireArguments() {
    let delegate = AppDelegate()
    var response: Any?

    delegate.handleKeychainCall(
      FlutterMethodCall(methodName: "unknown", arguments: nil)
    ) { value in
      response = value
    }

    XCTAssertTrue((response as AnyObject?) === FlutterMethodNotImplemented)
  }

  func testAccessibleTextFieldProxyExposesStableNativeAttributes() {
    let view = AccessibleTextFieldProxyView(
      viewId: 7,
      arguments: [
        "label": "Search workspaces",
        "description": "Filter the workspace list",
        "value": "ianvs",
        "enabled": true,
        "focused": false,
      ]
    )

    XCTAssertTrue(view.isAccessibilityElement())
    XCTAssertEqual(view.accessibilityRole(), .textField)
    XCTAssertEqual(view.accessibilityLabel(), "Search workspaces")
    XCTAssertEqual(view.accessibilityTitle(), "Search workspaces")
    XCTAssertEqual(view.accessibilityHelp(), "Filter the workspace list")
    XCTAssertEqual(view.accessibilityValue() as? String, "ianvs")
    XCTAssertEqual(
      view.accessibilityIdentifier(),
      "ianvs-acp.accessible-text-field.7"
    )
    XCTAssertNil(view.hitTest(.zero))
  }

  func testAccessibleTextFieldCoordinatorPreservesSemanticRootLifecycle() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    let container = NSView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = container
    let semanticRoot = NSAccessibilityElement()
    container.setAccessibilityChildren([semanticRoot])
    let coordinator = AccessibleTextFieldAccessibilityCoordinator(
      container: container
    )
    let proxy = AccessibleTextFieldProxyView(
      viewId: 8,
      arguments: ["label": "Filter projects"]
    )
    container.addSubview(proxy)

    coordinator.register(proxy)
    let registeredChildren = container.accessibilityChildren() ?? []
    XCTAssertEqual(registeredChildren.count, 2)
    XCTAssertTrue(registeredChildren[0] as AnyObject === semanticRoot)
    XCTAssertTrue(registeredChildren[1] as AnyObject === proxy)
    XCTAssertTrue(proxy.accessibilityParent() as AnyObject === container)

    coordinator.unregister(proxy)
    let restoredChildren = container.accessibilityChildren() ?? []
    XCTAssertEqual(restoredChildren.count, 1)
    XCTAssertTrue(restoredChildren[0] as AnyObject === semanticRoot)
  }

  func testPendingDeepLinkBufferBoundsCountAndLength() {
    let buffer = PendingDeepLinkBuffer()

    for index in 0..<PendingDeepLinkBuffer.maxCount {
      XCTAssertTrue(buffer.append("ianvs-acp://session?id=\(index)"))
    }
    XCTAssertFalse(buffer.append("ianvs-acp://session?id=overflow"))

    let firstBatch = buffer.drain()
    XCTAssertEqual(firstBatch.count, PendingDeepLinkBuffer.maxCount)
    XCTAssertTrue(buffer.drain().isEmpty)

    let oversized = String(
      repeating: "x",
      count: PendingDeepLinkBuffer.maxUTF16Length + 1
    )
    XCTAssertFalse(PendingDeepLinkBuffer.accepts(oversized))
    XCTAssertFalse(buffer.append(oversized))
    XCTAssertTrue(buffer.drain().isEmpty)
  }

  private func account(from reference: String) throws -> String {
    let prefix = "keychain://ianvs-acp/"
    guard reference.hasPrefix(prefix) else {
      throw TestError.invalidReference(reference)
    }
    return String(reference.dropFirst(prefix.count))
  }

  private func systemAccessibleAttribute(service: String, account: String) throws -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw KeychainSecretStoreError.osStatus(status)
    }
    let attributes = result as? [CFString: Any]
    return attributes?[kSecAttrAccessible] as? String
  }

  private func deleteAllSystemItems(service: String) {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrSynchronizable: false,
    ]
    query[kSecUseDataProtectionKeychain] = true
    _ = SecItemDelete(query as CFDictionary)
    query.removeValue(forKey: kSecUseDataProtectionKeychain)
    _ = SecItemDelete(query as CFDictionary)
  }

  private func hostTeamIdentifier() throws -> String? {
    var dynamicCode: SecCode?
    let selfStatus = SecCodeCopySelf([], &dynamicCode)
    guard selfStatus == errSecSuccess, let dynamicCode else {
      throw TestError.osStatus(selfStatus)
    }
    var staticCode: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
    guard staticStatus == errSecSuccess, let staticCode else {
      throw TestError.osStatus(staticStatus)
    }
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
    let informationStatus = SecCodeCopySigningInformation(staticCode, flags, &information)
    guard informationStatus == errSecSuccess else {
      throw TestError.osStatus(informationStatus)
    }
    guard let values = information as? [CFString: Any] else {
      throw TestError.invalidSigningInformation
    }
    guard let rawTeamIdentifier = values[kSecCodeInfoTeamIdentifier] else {
      return nil
    }
    guard let teamIdentifier = rawTeamIdentifier as? String else {
      throw TestError.invalidSigningInformation
    }
    return teamIdentifier.isEmpty ? nil : teamIdentifier
  }

  private enum TestError: Error {
    case invalidReference(String)
    case invalidSigningInformation
    case osStatus(OSStatus)
  }
}

private final class FakeKeychainSecurityClient: KeychainSecurityClient {
  struct Item {
    var data: Data
    var attributes: [CFString: Any]
  }

  var updateStatuses: [OSStatus] = []
  var addStatuses: [OSStatus] = []
  var copyStatuses: [OSStatus] = []
  private(set) var updateQueries: [[CFString: Any]] = []
  private(set) var addQueries: [[CFString: Any]] = []
  private(set) var copyQueries: [[CFString: Any]] = []
  private(set) var deleteQueries: [[CFString: Any]] = []
  private var items: [String: Item] = [:]

  func update(query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
    updateQueries.append(query)
    if !updateStatuses.isEmpty {
      return updateStatuses.removeFirst()
    }
    guard
      hasValidBaseQuery(query),
      attributes[kSecValueData] is Data,
      hasValidAccessibility(attributes, for: query)
    else {
      return errSecParam
    }
    guard let itemKey = itemKey(query), var item = items[itemKey] else {
      return errSecItemNotFound
    }
    if let data = attributes[kSecValueData] as? Data {
      item.data = data
    }
    for (key, value) in attributes {
      item.attributes[key] = value
    }
    items[itemKey] = item
    return errSecSuccess
  }

  func add(query: [CFString: Any]) -> OSStatus {
    addQueries.append(query)
    if !addStatuses.isEmpty {
      return addStatuses.removeFirst()
    }
    guard
      hasValidBaseQuery(query),
      hasValidAccessibility(query, for: query),
      let itemKey = itemKey(query),
      let data = query[kSecValueData] as? Data
    else {
      return errSecParam
    }
    guard items[itemKey] == nil else {
      return errSecDuplicateItem
    }
    items[itemKey] = Item(data: data, attributes: query)
    return errSecSuccess
  }

  func copyMatching(query: [CFString: Any]) -> (OSStatus, Any?) {
    copyQueries.append(query)
    if !copyStatuses.isEmpty {
      return (copyStatuses.removeFirst(), nil)
    }
    guard hasValidBaseQuery(query),
      query[kSecMatchLimit] as? String == kSecMatchLimitOne as String
    else {
      return (errSecParam, nil)
    }
    guard let itemKey = itemKey(query), let item = items[itemKey] else {
      return (errSecItemNotFound, nil)
    }
    if query[kSecReturnData] as? Bool == true {
      return (errSecSuccess, item.data)
    }
    if query[kSecReturnAttributes] as? Bool == true {
      return (errSecSuccess, item.attributes)
    }
    return (errSecParam, nil)
  }

  func delete(query: [CFString: Any]) -> OSStatus {
    deleteQueries.append(query)
    guard hasValidBaseQuery(query), let itemKey = itemKey(query) else {
      return errSecParam
    }
    return items.removeValue(forKey: itemKey) == nil ? errSecItemNotFound : errSecSuccess
  }

  private func itemKey(_ query: [CFString: Any]) -> String? {
    guard
      let service = query[kSecAttrService] as? String,
      let account = query[kSecAttrAccount] as? String
    else {
      return nil
    }
    let backend = query[kSecUseDataProtectionKeychain] as? Bool == true
      ? "data-protection"
      : "standard"
    return "\(backend)\u{0}\(service)\u{0}\(account)"
  }

  private func hasValidBaseQuery(_ query: [CFString: Any]) -> Bool {
    let dataProtectionValue = query[kSecUseDataProtectionKeychain]
    return query[kSecClass] as? String == kSecClassGenericPassword as String
      && query[kSecAttrService] is String
      && query[kSecAttrAccount] is String
      && query[kSecAttrSynchronizable] as? Bool == false
      && (dataProtectionValue == nil || dataProtectionValue as? Bool == true)
  }

  private func hasValidAccessibility(
    _ attributes: [CFString: Any],
    for query: [CFString: Any]
  ) -> Bool {
    if query[kSecUseDataProtectionKeychain] as? Bool == true {
      return attributes[kSecAttrAccessible] as? String
        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    }
    return attributes[kSecAttrAccessible] == nil
  }
}
