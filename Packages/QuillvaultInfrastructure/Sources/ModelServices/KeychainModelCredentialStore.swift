import Domain
import Foundation
import Security

public actor KeychainModelCredentialStore: ModelCredentialStore {
  private let service: String

  public init(service: String = "com.coolhwm.Quillvault.model-credentials") {
    self.service = service
  }

  public func save(
    _ secret: String,
    for reference: ModelCredentialReference
  ) async throws {
    let data = Data(secret.utf8)
    let query = Self.identityQuery(
      service: service,
      reference: reference
    )
    let addition = Self.additionQuery(
      service: service,
      reference: reference,
      data: data
    )

    let status = SecItemAdd(addition as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [kSecValueData as String: data] as CFDictionary
      )
      try Self.check(updateStatus)
      return
    }
    try Self.check(status)
  }

  public func read(
    _ reference: ModelCredentialReference
  ) async throws -> String {
    var query = Self.identityQuery(
      service: service,
      reference: reference
    )
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    try Self.check(status)
    guard let data = result as? Data,
      let secret = String(data: data, encoding: .utf8)
    else {
      throw ModelCredentialError.unavailable
    }
    return secret
  }

  public func delete(
    _ reference: ModelCredentialReference
  ) async throws {
    let status = SecItemDelete(
      Self.identityQuery(
        service: service,
        reference: reference
      ) as CFDictionary
    )
    if status != errSecItemNotFound {
      try Self.check(status)
    }
  }

  static func securityAttributesForTesting(
    service: String,
    reference: ModelCredentialReference
  ) throws -> KeychainSecurityAttributes {
    let attributes = additionQuery(
      service: service,
      reference: reference,
      data: Data()
    )
    return KeychainSecurityAttributes(
      accessibility: attributes[kSecAttrAccessible as String]
        .map(String.init(describing:)),
      synchronizable: attributes[kSecAttrSynchronizable as String]
        as? Bool
    )
  }

  static func deleteAllForTesting(service: String) throws {
    let status = SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
      ] as CFDictionary
    )
    if status != errSecItemNotFound {
      try check(status)
    }
  }

  static func mappedErrorForTesting(
    _ status: OSStatus
  ) -> ModelCredentialError? {
    mappedError(status)
  }

  private static func identityQuery(
    service: String,
    reference: ModelCredentialReference
  ) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference.rawValue.uuidString,
    ]
  }

  private static func additionQuery(
    service: String,
    reference: ModelCredentialReference,
    data: Data
  ) -> [String: Any] {
    var query = identityQuery(
      service: service,
      reference: reference
    )
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] =
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return query
  }

  private static func check(_ status: OSStatus) throws {
    if let error = mappedError(status) {
      throw error
    }
  }

  private static func mappedError(
    _ status: OSStatus
  ) -> ModelCredentialError? {
    switch status {
    case errSecSuccess:
      nil
    case errSecItemNotFound:
      .notFound
    case errSecInteractionNotAllowed:
      .unavailableUntilFirstUnlock
    default:
      .unavailable
    }
  }
}

struct KeychainSecurityAttributes {
  let accessibility: String?
  let synchronizable: Bool?
}
