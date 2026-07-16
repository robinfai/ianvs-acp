import Cocoa
import CryptoKit
import FlutterMacOS
import Security

enum KeychainSecretStoreError: Error {
  case invalidData
  case osStatus(OSStatus)
}

protocol KeychainSecurityClient {
  func update(query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus
  func add(query: [CFString: Any]) -> OSStatus
  func copyMatching(query: [CFString: Any]) -> (OSStatus, Any?)
  func delete(query: [CFString: Any]) -> OSStatus
}

struct SystemKeychainSecurityClient: KeychainSecurityClient {
  func update(query: [CFString: Any], attributes: [CFString: Any]) -> OSStatus {
    return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func add(query: [CFString: Any]) -> OSStatus {
    return SecItemAdd(query as CFDictionary, nil)
  }

  func copyMatching(query: [CFString: Any]) -> (OSStatus, Any?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result)
  }

  func delete(query: [CFString: Any]) -> OSStatus {
    return SecItemDelete(query as CFDictionary)
  }
}

final class KeychainSecretStore {
  static let productionService = "com.ianvs.acp.secrets"

  private let service: String
  private let securityClient: KeychainSecurityClient

  init(
    service: String = productionService,
    securityClient: KeychainSecurityClient = SystemKeychainSecurityClient()
  ) {
    self.service = service
    self.securityClient = securityClient
  }

  func put(namespace: String, key: String, value: String) throws -> String {
    let account = account(namespace: namespace, key: key)
    let valueData = Data(value.utf8)
    let query = baseQuery(account: account)
    let updates: [CFString: Any] = [
      kSecValueData: valueData,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]

    // Another process or isolate may race between update and add. Retrying the
    // update after a duplicate keeps put idempotent without weakening queries.
    var lastStatus = errSecItemNotFound
    for _ in 0..<3 {
      let updateStatus = securityClient.update(query: query, attributes: updates)
      if updateStatus == errSecSuccess {
        return "keychain://ianvs-acp/\(account)"
      }
      guard updateStatus == errSecItemNotFound else {
        throw KeychainSecretStoreError.osStatus(updateStatus)
      }

      var addQuery = query
      addQuery[kSecValueData] = valueData
      addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = securityClient.add(query: addQuery)
      if addStatus == errSecSuccess {
        return "keychain://ianvs-acp/\(account)"
      }
      guard addStatus == errSecDuplicateItem else {
        throw KeychainSecretStoreError.osStatus(addStatus)
      }
      lastStatus = addStatus
    }
    throw KeychainSecretStoreError.osStatus(lastStatus)
  }

  func get(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    let (status, result) = securityClient.copyMatching(query: query)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainSecretStoreError.osStatus(status)
    }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw KeychainSecretStoreError.invalidData
    }
    return value
  }

  func delete(account: String) throws {
    let status = securityClient.delete(query: baseQuery(account: account))
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainSecretStoreError.osStatus(status)
    }
  }

  private func account(namespace: String, key: String) -> String {
    let namespaceBytes = Array(namespace.utf8)
    var namespaceLength = UInt64(namespaceBytes.count).bigEndian
    var identity = Data()
    Swift.withUnsafeBytes(of: &namespaceLength) { bytes in
      identity.append(contentsOf: bytes)
    }
    identity.append(contentsOf: namespaceBytes)
    identity.append(contentsOf: key.utf8)
    let digest = SHA256.hash(data: identity)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func baseQuery(account: String) -> [CFString: Any] {
    return [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
  }
}

final class PendingDeepLinkBuffer {
  static let maxCount = 8
  static let maxUTF16Length = 8 * 1024

  private var values: [String] = []

  static func accepts(_ value: String) -> Bool {
    return !value.isEmpty && value.utf16.count <= maxUTF16Length
  }

  @discardableResult
  func append(_ value: String) -> Bool {
    guard Self.accepts(value), values.count < Self.maxCount else {
      return false
    }
    values.append(value)
    return true
  }

  func drain() -> [String] {
    let result = values
    values.removeAll(keepingCapacity: true)
    return result
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private let deepLinkChannelName = "ianvs_acp/deep_links"
  private let keychainChannelName = "ianvs_acp/keychain"
  private let keychainStore = KeychainSecretStore()
  private var deepLinkChannel: FlutterMethodChannel?
  private var keychainChannel: FlutterMethodChannel?
  private let pendingDeepLinks = PendingDeepLinkBuffer()

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate does not safely implement this optional callback on
    // every engine version; calling super here can raise an Objective-C
    // forwarding exception during launch.
    configureDeepLinkChannel()
    configureKeychainChannel()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      handleDeepLink(url)
    }
  }

  private func configureDeepLinkChannel() {
    guard let controller = NSApplication.shared.windows.compactMap({ window in
      window.contentViewController as? FlutterViewController
    }).first else {
      return
    }

    let channel = FlutterMethodChannel(
      name: deepLinkChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "getInitialDeepLinks" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.pendingDeepLinks.drain() ?? [])
    }
    deepLinkChannel = channel
  }

  private func configureKeychainChannel() {
    guard let controller = NSApplication.shared.windows.compactMap({ window in
      window.contentViewController as? FlutterViewController
    }).first else {
      return
    }

    let channel = FlutterMethodChannel(
      name: keychainChannelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleKeychainCall(call, result: result)
    }
    keychainChannel = channel
  }

  func handleKeychainCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "put":
        guard
          let arguments = call.arguments as? [String: Any],
          let namespace = arguments["namespace"] as? String,
          !namespace.isEmpty,
          let key = arguments["key"] as? String,
          !key.isEmpty,
          let value = arguments["value"] as? String
        else {
          result(invalidArgumentsError())
          return
        }
        result(try keychainStore.put(namespace: namespace, key: key, value: value))
      case "get":
        guard let arguments = call.arguments as? [String: Any] else {
          result(invalidArgumentsError())
          return
        }
        guard let account = validAccount(from: arguments) else {
          result(invalidArgumentsError())
          return
        }
        result(try keychainStore.get(account: account))
      case "delete":
        guard let arguments = call.arguments as? [String: Any] else {
          result(invalidArgumentsError())
          return
        }
        guard let account = validAccount(from: arguments) else {
          result(invalidArgumentsError())
          return
        }
        try keychainStore.delete(account: account)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch KeychainSecretStoreError.invalidData {
      result(
        FlutterError(
          code: "invalid_keychain_data",
          message: "Keychain item is not valid UTF-8.",
          details: nil
        )
      )
    } catch KeychainSecretStoreError.osStatus(let status) {
      let message = SecCopyErrorMessageString(status, nil) as String?
      result(
        FlutterError(
          code: "keychain_error",
          message: message ?? "Keychain operation failed.",
          details: status
        )
      )
    } catch {
      result(
        FlutterError(
          code: "keychain_error",
          message: "Keychain operation failed.",
          details: nil
        )
      )
    }
  }

  private func validAccount(from arguments: [String: Any]) -> String? {
    guard let account = arguments["account"] as? String, account.count == 64 else {
      return nil
    }
    let validCharacters = CharacterSet(charactersIn: "0123456789abcdef")
    return account.unicodeScalars.allSatisfy(validCharacters.contains) ? account : nil
  }

  private func invalidArgumentsError() -> FlutterError {
    return FlutterError(
      code: "invalid_arguments",
      message: "Invalid Keychain method arguments.",
      details: nil
    )
  }

  private func handleDeepLink(_ url: URL) {
    guard url.scheme == "ianvs-acp" else {
      return
    }

    let value = url.absoluteString
    guard PendingDeepLinkBuffer.accepts(value) else {
      return
    }
    if let channel = deepLinkChannel {
      channel.invokeMethod("openDeepLink", arguments: value)
    } else {
      pendingDeepLinks.append(value)
    }
  }
}
