import 'dart:io';
import 'package:logging/logging.dart';

/// Centralized server configuration loaded from environment variables.
/// Supports Docker secrets via _FILE suffix pattern.
class ServerConfig {
  final int port;
  final bool tlsEnabled;
  final String? tlsCertPath;
  final String? tlsKeyPath;
  final String logLevel;
  final String bitcoinRpcUrl;
  final String bitcoinRpcUser;
  final String bitcoinRpcPassword;
  final String electrumUrl;
  final int electrumPort;
  final int rateLimitMaxRequests;
  final int rateLimitWindowSeconds;

  ServerConfig._({
    required this.port,
    required this.tlsEnabled,
    this.tlsCertPath,
    this.tlsKeyPath,
    required this.logLevel,
    required this.bitcoinRpcUrl,
    required this.bitcoinRpcUser,
    required this.bitcoinRpcPassword,
    required this.electrumUrl,
    required this.electrumPort,
    required this.rateLimitMaxRequests,
    required this.rateLimitWindowSeconds,
  });

  /// Load configuration from environment variables.
  /// Supports Docker secrets via _FILE suffix (e.g., BITCOIN_RPC_PASSWORD_FILE).
  factory ServerConfig.fromEnvironment() {
    final tlsEnabled =
        Platform.environment['TLS_ENABLED']?.toLowerCase() == 'true';

    return ServerConfig._(
      port: int.tryParse(Platform.environment['PORT'] ?? '') ?? 50051,
      tlsEnabled: tlsEnabled,
      tlsCertPath: Platform.environment['TLS_CERT_PATH'],
      tlsKeyPath: Platform.environment['TLS_KEY_PATH'],
      logLevel: Platform.environment['LOG_LEVEL'] ?? 'INFO',
      bitcoinRpcUrl: Platform.environment['BITCOIN_RPC_URL'] ??
          'http://127.0.0.1:18443',
      bitcoinRpcUser: _loadSecret('BITCOIN_RPC_USER'),
      bitcoinRpcPassword: _loadSecret('BITCOIN_RPC_PASSWORD'),
      electrumUrl: Platform.environment['ELECTRUM_URL'] ??
          'electrum.blockstream.info',
      electrumPort:
          int.tryParse(Platform.environment['ELECTRUM_PORT'] ?? '60002') ??
              60002,
      rateLimitMaxRequests:
          int.tryParse(Platform.environment['RATE_LIMIT_MAX_REQUESTS'] ?? '') ??
              100,
      rateLimitWindowSeconds: int.tryParse(
              Platform.environment['RATE_LIMIT_WINDOW_SECONDS'] ?? '') ??
          60,
    );
  }

  /// Load a secret from environment variable or Docker secrets file.
  /// Returns empty string if not found (validation will catch required fields).
  static String _loadSecret(String envName) {
    // First check for _FILE variant (Docker secrets)
    final filePath = Platform.environment['${envName}_FILE'];
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (file.existsSync()) {
        return file.readAsStringSync().trim();
      }
    }
    // Fall back to direct environment variable
    return Platform.environment[envName] ?? '';
  }

  /// Validate configuration and throw if invalid.
  /// Call this at startup to fail fast with clear error messages.
  void validate() {
    final errors = <String>[];
    final warnings = <String>[];

    // TLS validation
    if (tlsEnabled) {
      if (tlsCertPath == null || tlsCertPath!.isEmpty) {
        errors.add('TLS_CERT_PATH is required when TLS_ENABLED=true');
      } else if (!File(tlsCertPath!).existsSync()) {
        errors.add('TLS certificate not found at $tlsCertPath');
      }
      if (tlsKeyPath == null || tlsKeyPath!.isEmpty) {
        errors.add('TLS_KEY_PATH is required when TLS_ENABLED=true');
      } else if (!File(tlsKeyPath!).existsSync()) {
        errors.add('TLS private key not found at $tlsKeyPath');
      }
    } else {
      warnings.add('TLS is disabled - only use for development');
    }

    // Credential validation
    if (bitcoinRpcUser.isEmpty) {
      errors.add('BITCOIN_RPC_USER is required');
    }
    if (bitcoinRpcPassword.isEmpty) {
      errors.add('BITCOIN_RPC_PASSWORD is required');
    }
    if (bitcoinRpcPassword.isNotEmpty &&
        bitcoinRpcPassword.length < 12 &&
        isProduction) {
      warnings.add('BITCOIN_RPC_PASSWORD should be at least 12 characters');
    }

    // Port validation
    if (port < 1 || port > 65535) {
      errors.add('PORT must be between 1 and 65535');
    }

    // Rate limit validation
    if (rateLimitMaxRequests < 1) {
      errors.add('RATE_LIMIT_MAX_REQUESTS must be at least 1');
    }
    if (rateLimitWindowSeconds < 1) {
      errors.add('RATE_LIMIT_WINDOW_SECONDS must be at least 1');
    }

    // Log warnings
    for (final w in warnings) {
      stderr.writeln('WARNING: $w');
    }

    if (errors.isNotEmpty) {
      throw StateError(
          'Configuration errors:\n  - ${errors.join('\n  - ')}');
    }
  }

  /// Returns true if TLS is enabled (production mode indicator).
  bool get isProduction => tlsEnabled;

  /// Parse log level string to Logger Level.
  Level get loggerLevel {
    switch (logLevel.toUpperCase()) {
      case 'ALL':
        return Level.ALL;
      case 'FINEST':
        return Level.FINEST;
      case 'FINER':
        return Level.FINER;
      case 'FINE':
        return Level.FINE;
      case 'CONFIG':
        return Level.CONFIG;
      case 'INFO':
        return Level.INFO;
      case 'WARNING':
        return Level.WARNING;
      case 'SEVERE':
        return Level.SEVERE;
      case 'OFF':
        return Level.OFF;
      default:
        return Level.INFO;
    }
  }

  @override
  String toString() {
    return 'ServerConfig('
        'port: $port, '
        'tlsEnabled: $tlsEnabled, '
        'logLevel: $logLevel, '
        'bitcoinRpcUrl: $bitcoinRpcUrl, '
        'electrumUrl: $electrumUrl:$electrumPort, '
        'rateLimitMaxRequests: $rateLimitMaxRequests, '
        'rateLimitWindowSeconds: $rateLimitWindowSeconds)';
  }
}
