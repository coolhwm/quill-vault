import Domain
import Foundation
import Security
import Testing

@testable import ModelServices

@Suite("Keychain model credential store")
struct KeychainModelCredentialStoreTests {
  @Test("Credentials are local-only, overwriteable, readable, and deletable")
  func credentialLifecycle() async throws {
    let service = "com.coolhwm.Quillvault.tests.\(UUID().uuidString)"
    let reference = ModelCredentialReference(rawValue: UUID())
    let store = KeychainModelCredentialStore(service: service)
    defer {
      try? KeychainModelCredentialStore.deleteAllForTesting(service: service)
    }

    try await store.save("first-secret", for: reference)
    #expect(try await store.read(reference) == "first-secret")
    try await store.save("replacement-secret", for: reference)
    #expect(try await store.read(reference) == "replacement-secret")

    let attributes =
      try KeychainModelCredentialStore
      .securityAttributesForTesting(
        service: service,
        reference: reference
      )
    #expect(
      attributes.accessibility
        == String(
          describing:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    )
    #expect(attributes.synchronizable == nil)

    try await store.delete(reference)
    await #expect(throws: ModelCredentialError.notFound) {
      _ = try await store.read(reference)
    }
  }

  @Test("Locked-before-first-unlock is mapped distinctly")
  func firstUnlockMapping() {
    #expect(
      KeychainModelCredentialStore.mappedErrorForTesting(
        errSecInteractionNotAllowed
      ) == .unavailableUntilFirstUnlock
    )
  }
}
