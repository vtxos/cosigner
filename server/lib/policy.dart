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
}
