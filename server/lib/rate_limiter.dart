import 'dart:async';
import 'package:grpc/grpc.dart';

/// Tracks request count within a sliding time window.
class _RateLimitEntry {
  int requestCount = 0;
  DateTime windowStart = DateTime.now();
}

/// Simple in-memory rate limiter for gRPC services.
/// Uses a sliding window approach per identifier (typically device ID).
class RateLimiter {
  final int maxRequestsPerWindow;
  final Duration windowDuration;
  final Map<String, _RateLimitEntry> _entries = {};

  Timer? _cleanupTimer;

  /// Create a rate limiter.
  /// [maxRequestsPerWindow] - Maximum requests allowed per window (default: 100)
  /// [windowDuration] - Time window duration (default: 1 minute)
  RateLimiter({
    this.maxRequestsPerWindow = 100,
    this.windowDuration = const Duration(minutes: 1),
  }) {
    // Periodic cleanup of stale entries every 5 minutes
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) => _cleanup());
  }

  /// Dispose the rate limiter and cancel cleanup timer.
  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _entries.clear();
  }

  /// Check if a request is allowed for the given identifier.
  /// Throws GrpcError.resourceExhausted if rate limit exceeded.
  void checkLimit(String identifier) {
    final now = DateTime.now();
    final entry = _entries.putIfAbsent(identifier, () => _RateLimitEntry());

    // Reset window if expired
    if (now.difference(entry.windowStart) > windowDuration) {
      entry.requestCount = 0;
      entry.windowStart = now;
    }

    entry.requestCount++;

    if (entry.requestCount > maxRequestsPerWindow) {
      final retryAfter = windowDuration.inSeconds -
          now.difference(entry.windowStart).inSeconds;
      throw GrpcError.resourceExhausted(
        'Rate limit exceeded. Max $maxRequestsPerWindow requests per '
        '${windowDuration.inSeconds}s. Retry after ${retryAfter}s.',
      );
    }
  }

  /// Get current request count for an identifier (for monitoring).
  int getRequestCount(String identifier) {
    final entry = _entries[identifier];
    if (entry == null) return 0;

    final now = DateTime.now();
    if (now.difference(entry.windowStart) > windowDuration) {
      return 0;
    }
    return entry.requestCount;
  }

  /// Get number of tracked identifiers (for monitoring).
  int get trackedIdentifiers => _entries.length;

  /// Clean up stale entries (older than 2x window duration).
  void _cleanup() {
    final now = DateTime.now();
    final staleThreshold = windowDuration * 2;
    _entries.removeWhere(
        (_, entry) => now.difference(entry.windowStart) > staleThreshold);
  }
}
