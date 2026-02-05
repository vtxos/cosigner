import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:threshold/threshold.dart';

void main() {
  group('Authentication', () {
    test('sign and verify round trip', () {
      // Generate a random secret key
      final secretKey = SecretKey(modNRandom());
      
      // Create auth signer
      final signer = AuthSigner.fromSecret(secretKey);
      
      // The userId is the compressed public key
      final userId = signer.publicKeyCompressed;
      final userIdHex = userId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      
      // Create and sign an auth message
      final authMessage = AuthMessage(
        operation: AuthMessage.opSignStep1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        userIdHex: userIdHex,
      );
      
      final signature = signer.signAuthMessage(authMessage);
      
      // Verify the signature
      final isValid = verifySchnorrSignature(
        publicKeyCompressed: userId,
        message: authMessage.messageBytes,
        signatureBytes: signature,
      );
      
      expect(isValid, isTrue);
    });
    
    test('verification fails with wrong message', () {
      final secretKey = SecretKey(modNRandom());
      final signer = AuthSigner.fromSecret(secretKey);
      final userId = signer.publicKeyCompressed;
      final userIdHex = userId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      
      final authMessage = AuthMessage(
        operation: AuthMessage.opSignStep1,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        userIdHex: userIdHex,
      );
      
      final signature = signer.signAuthMessage(authMessage);
      
      // Try to verify with a different message
      final wrongMessage = AuthMessage(
        operation: AuthMessage.opSignStep2, // Different operation
        timestampMs: authMessage.timestampMs,
        userIdHex: userIdHex,
      );
      
      final isValid = verifySchnorrSignature(
        publicKeyCompressed: userId,
        message: wrongMessage.messageBytes,
        signatureBytes: signature,
      );
      
      expect(isValid, isFalse);
    });
  });
}
