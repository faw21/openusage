import CryptoKit
import XCTest
@testable import OpenUsage

final class LANSyncProtocolTests: XCTestCase {
    func testPairingDerivesMatchingCodeAndEncryptedSession() throws {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let client = LANSyncProtocol.Hello(
            version: LANSyncProtocol.version,
            mode: .pair,
            deviceID: "client",
            displayName: "Studio Mac",
            publicKey: clientKey.publicKey.rawRepresentation,
            nonce: Data(repeating: 1, count: 32)
        )
        let server = LANSyncProtocol.ServerHello(
            version: LANSyncProtocol.version,
            deviceID: "server",
            displayName: "MacBook Pro",
            publicKey: serverKey.publicKey.rawRepresentation,
            nonce: Data(repeating: 2, count: 32),
            proof: nil
        )

        let clientContext = try LANSyncProtocol.context(
            clientHello: client, serverHello: server, privateKey: clientKey
        )
        let serverContext = try LANSyncProtocol.context(
            clientHello: client, serverHello: server, privateKey: serverKey
        )

        XCTAssertEqual(clientContext.code, serverContext.code)
        XCTAssertEqual(clientContext.code.count, 6)
        let sealed = try LANSyncProtocol.seal(["message": "private"], using: clientContext.key)
        let opened = try LANSyncProtocol.open([String: String].self, sealed: sealed, using: serverContext.key)
        XCTAssertEqual(opened, ["message": "private"])
    }

    func testPairedProofsAreRoleBoundAndRejectAnotherSecret() throws {
        let transcript = Data("bound transcript".utf8)
        let secret = Data(repeating: 7, count: 32)
        let wrongSecret = Data(repeating: 8, count: 32)
        let proof = LANSyncProtocol.proof(role: "server", transcript: transcript, pairSecret: secret)

        XCTAssertTrue(LANSyncProtocol.verify(proof, role: "server", transcript: transcript, pairSecret: secret))
        XCTAssertFalse(LANSyncProtocol.verify(proof, role: "client", transcript: transcript, pairSecret: secret))
        XCTAssertFalse(LANSyncProtocol.verify(proof, role: "server", transcript: transcript, pairSecret: wrongSecret))
    }

    func testPairingCodeBindsAdvertisedIdentity() throws {
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let serverKey = Curve25519.KeyAgreement.PrivateKey()
        let client = LANSyncProtocol.Hello(
            version: LANSyncProtocol.version, mode: .pair, deviceID: "client", displayName: "Mac A",
            publicKey: clientKey.publicKey.rawRepresentation, nonce: Data(repeating: 3, count: 32)
        )
        let server = LANSyncProtocol.ServerHello(
            version: LANSyncProtocol.version, deviceID: "server", displayName: "Mac B",
            publicKey: serverKey.publicKey.rawRepresentation, nonce: Data(repeating: 4, count: 32), proof: nil
        )
        let renamed = LANSyncProtocol.ServerHello(
            version: server.version, deviceID: server.deviceID, displayName: "Spoofed Mac",
            publicKey: server.publicKey, nonce: server.nonce, proof: nil
        )

        let expected = try LANSyncProtocol.context(clientHello: client, serverHello: server, privateKey: clientKey)
        let tampered = try LANSyncProtocol.context(clientHello: client, serverHello: renamed, privateKey: clientKey)
        XCTAssertNotEqual(expected.transcript, tampered.transcript)
    }
}
