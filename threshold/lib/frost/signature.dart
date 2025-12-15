import 'package:pointycastle/ecc/api.dart';
import 'package:threshold/core/share.dart';
import 'package:threshold/core/utils.dart';
import 'package:convert/convert.dart';
import 'package:threshold/frost/hasher.dart';
import 'package:threshold/frost/utils.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

class Signature {
  final ECPoint R;
  final BigInt Z;

  Signature(this.R, this.Z);

  factory Signature.fromJson(Map<String, dynamic> json) {
    final R = elemDeserializeCompressed(
      Uint8List.fromList(hex.decode(json['R'])),
    );
    final Z = bytesToBigInt(Uint8List.fromList(hex.decode(json['Z'])));
    return Signature(R, Z);
  }

  Map<String, dynamic> toJson() => {
    'R': hex.encode(elemSerializeCompressed(R)),
    'Z': hex.encode(bigIntToBytes(Z)),
  };

  bool get hasEvenY {
    return R.y!.toBigInteger()!.isEven;
  }

  Signature intoEvenY({bool? isEven}) {
    final currentIsEven = isEven ?? hasEvenY;
    if (!currentIsEven) {
      final n = secp256k1Curve.n;
      final negMultiplier = n - BigInt.one;

      final newR = (R * negMultiplier)!;
      return Signature(newR, Z);
    }
    return this;
  }

  // bip340 signature
  Uint8List serialize() {
    final rBytesCompressed = elemSerializeCompressed(R);
    final zBytes = bigIntToBytes(Z);

    final out = Uint8List(64);

    // R bytes: skip first byte (0x02 or 0x03)
    out.setRange(0, 32, rBytesCompressed.sublist(1));

    // Z bytes: big endian, padded to 32 bytes
    final zOffset = 32 + (32 - zBytes.length);
    out.setRange(zOffset, 64, zBytes);

    return out;
  }

  // Verify signature against public key P and message m
  bool verify(VerifyingKey pk, Uint8List message) {
    final pkEvenY = pk.intoEvenY();
    final sigEvenY = intoEvenY();

    final challenge = computeChallenge(sigEvenY.R, pkEvenY, message);

    // 2. Check s*G = R + e*P
    final s = Z;
    final P = pkEvenY.E;

    final sG = (secp256k1Curve.G * s)!;
    final eP = (P * challenge)!;
    final R_plus_eP = (sigEvenY.R + eP)!;

    return pointsEqual(sG, R_plus_eP);
  }
}

BigInt computeChallenge(ECPoint R, VerifyingKey vk, Uint8List message) {
  // BIP-340: e = hash_BIP0340/challenge(bytes(R) || bytes(P) || m)
  // bytes(R) and bytes(P) are x-only (32 bytes)

  final RBytes = elemSerializeCompressed(R).sublist(1);
  final PBytes = elemSerializeCompressed(vk.E).sublist(1);

  final builder = BytesBuilder();
  builder.add(RBytes);
  builder.add(PBytes);
  builder.add(message);

  return taggedHash("BIP0340/challenge", builder.toBytes());
}

BigInt taggedHash(String tag, Uint8List msg) {
  final tagHash = sha256.convert(utf8.encode(tag)).bytes;
  final builder = BytesBuilder();
  builder.add(tagHash);
  builder.add(tagHash);
  builder.add(msg);

  final hash = sha256.convert(builder.toBytes()).bytes;
  return bytesToBigInt(Uint8List.fromList(hash)) % secp256k1Curve.n;
}
