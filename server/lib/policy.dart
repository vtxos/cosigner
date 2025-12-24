import 'package:threshold/threshold.dart' as threshold;

class ProtectedPolicy {
  final String id;
  final BigInt thresholdSats;
  final DateTime startTime;
  final Duration interval;
  final threshold.KeyPackage keyPackage;
  final threshold.PublicKeyPackage publicKeyPackage;

  ProtectedPolicy({
    required this.id,
    required this.thresholdSats,
    required this.startTime,
    required this.interval,
    required this.keyPackage,
    required this.publicKeyPackage,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'thresholdSats': thresholdSats.toString(),
      'startTime': startTime.millisecondsSinceEpoch,
      'interval': interval.inSeconds,
      'keyPackage': keyPackage.toJson(),
      'publicKeyPackage': publicKeyPackage.toJson(),
    };
  }

  static ProtectedPolicy fromJson(Map<String, dynamic> json) {
    return ProtectedPolicy(
      id: json['id'],
      thresholdSats: BigInt.parse(json['thresholdSats']),
      startTime: DateTime.fromMillisecondsSinceEpoch(json['startTime']),
      interval: Duration(seconds: json['interval']),
      keyPackage: threshold.KeyPackage.fromJson(json['keyPackage']),
      publicKeyPackage:
          threshold.PublicKeyPackage.fromJson(json['publicKeyPackage']),
    );
  }
}

class NormalPolicy {
  final String id;
  final threshold.KeyPackage keyPackage;
  final threshold.PublicKeyPackage publicKeyPackage;

  NormalPolicy({
    required this.id,
    required this.keyPackage,
    required this.publicKeyPackage,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'keyPackage': keyPackage.toJson(),
      'publicKeyPackage': publicKeyPackage.toJson(),
    };
  }

  static NormalPolicy fromJson(Map<String, dynamic> json) {
    return NormalPolicy(
      id: json['id'],
      keyPackage: threshold.KeyPackage.fromJson(json['keyPackage']),
      publicKeyPackage:
          threshold.PublicKeyPackage.fromJson(json['publicKeyPackage']),
    );
  }
}
