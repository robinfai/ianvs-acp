import Foundation
import FlutterMacOS
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
    for query in queries {
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
  }

  func testPutRetriesUpdateWhenConcurrentAddWins() throws {
    securityClient.updateStatuses = [errSecItemNotFound, errSecSuccess]
    securityClient.addStatuses = [errSecDuplicateItem]

    let reference = try store.put(namespace: "namespace", key: "key", value: "value")

    XCTAssertNotNil(reference.range(of: "^keychain://ianvs-acp/[0-9a-f]{64}$", options: .regularExpression))
    XCTAssertEqual(securityClient.updateQueries.count, 2)
    XCTAssertEqual(securityClient.addQueries.count, 1)
  }

  func testSystemKeychainCrudWhenHostHasDataProtectionEntitlement() throws {
    let integrationService = "\(KeychainSecretStore.productionService).integration.\(UUID().uuidString)"
    let integrationStore = KeychainSecretStore(service: integrationService)
    defer { deleteAllSystemItems(service: integrationService) }

    do {
      let reference = try integrationStore.put(
        namespace: "agent/Test/header",
        key: "Authorization",
        value: "Bearer first"
      )
      let account = try account(from: reference)
      XCTAssertEqual(try integrationStore.get(account: account), "Bearer first")
      XCTAssertEqual(
        try systemAccessibleAttribute(service: integrationService, account: account),
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
      )

      _ = try integrationStore.put(
        namespace: "agent/Test/header",
        key: "Authorization",
        value: "Bearer second"
      )
      XCTAssertEqual(try integrationStore.get(account: account), "Bearer second")
      try integrationStore.delete(account: account)
      XCTAssertNil(try integrationStore.get(account: account))
    } catch KeychainSecretStoreError.osStatus(let status)
      where status == errSecMissingEntitlement
    {
      if try hostTeamIdentifier() != nil {
        throw KeychainSecretStoreError.osStatus(status)
      }
      throw XCTSkip("Host has no Data Protection Keychain entitlement; run this test in the signed macOS job.")
    }
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
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
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
      attributes[kSecAttrAccessible] as? String
        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
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
      query[kSecAttrAccessible] as? String
        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
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
    guard
      hasValidBaseQuery(query),
      query[kSecReturnData] as? Bool == true,
      query[kSecMatchLimit] as? String == kSecMatchLimitOne as String
    else {
      return (errSecParam, nil)
    }
    guard let itemKey = itemKey(query), let item = items[itemKey] else {
      return (errSecItemNotFound, nil)
    }
    return (errSecSuccess, item.data)
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
    return "\(service)\u{0}\(account)"
  }

  private func hasValidBaseQuery(_ query: [CFString: Any]) -> Bool {
    return query[kSecClass] as? String == kSecClassGenericPassword as String
      && query[kSecAttrService] is String
      && query[kSecAttrAccount] is String
      && query[kSecAttrSynchronizable] as? Bool == false
      && query[kSecUseDataProtectionKeychain] as? Bool == true
  }
}
