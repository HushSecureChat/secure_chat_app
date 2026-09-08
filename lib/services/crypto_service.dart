import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  final _storage = const FlutterSecureStorage();
  final X25519 _algorithm = X25519();
  final AesGcm _aes = AesGcm.with256bits();

  // Typage explicite en SimpleKeyPair pour accéder aux octets privés
  SimpleKeyPair? _keyPair;
  String? _userId;

  Future<void> initUserIdentity() async {
    String? storedPrivateKeyHex = await _storage.read(key: 'private_key');

    if (storedPrivateKeyHex == null) {
      _keyPair = await _algorithm.newKeyPair();
      final privateKeyBytes = await _keyPair!.extractPrivateKeyBytes();
      await _storage.write(key: 'private_key', value: base64Encode(privateKeyBytes));
    } else {
      final privateKeyBytes = base64Decode(storedPrivateKeyHex);
      _keyPair = await _algorithm.newKeyPairFromSeed(privateKeyBytes);
    }

    final publicKey = await _keyPair!.extractPublicKey();
    _userId = base64UrlEncode(publicKey.bytes).substring(0, 16);
  }

  String get userId => _userId ?? 'Inconnu';

  Future<String> getPublicKeyString() async {
    final pubKey = await _keyPair!.extractPublicKey();
    return base64Encode(pubKey.bytes);
  }

  Future<String> encryptMessage(String plaintext, String recipientPublicKeyBase64) async {
    final recipientPubKey = SimplePublicKey(
      base64Decode(recipientPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final SecretKey sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: recipientPubKey,
    );

    final secretBox = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: sharedSecret,
    );

    return jsonEncode({
      'cipherText': base64Encode(secretBox.cipherText),
      'nonce': base64Encode(secretBox.nonce),
      'mac': base64Encode(secretBox.mac.bytes),
    });
  }

  Future<String> decryptMessage(String encryptedJsonPayload, String senderPublicKeyBase64) async {
    final senderPubKey = SimplePublicKey(
      base64Decode(senderPublicKeyBase64),
      type: KeyPairType.x25519,
    );

    final SecretKey sharedSecret = await _algorithm.sharedSecretKey(
      keyPair: _keyPair!,
      remotePublicKey: senderPubKey,
    );

    final data = jsonDecode(encryptedJsonPayload);
    final secretBox = SecretBox(
      base64Decode(data['cipherText']),
      nonce: base64Decode(data['nonce']),
      mac: Mac(base64Decode(data['mac'])),
    );

    final decryptedBytes = await _aes.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    return utf8.decode(decryptedBytes);
  }
}