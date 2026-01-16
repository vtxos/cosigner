import 'dart:convert';
import 'package:grpc/grpc.dart';

/// Input validation utilities for gRPC request parameters.
/// Throws GrpcError with appropriate status codes on validation failure.
class InputValidator {
  // User ID: either 32 hex chars (pre-DKG session) or 66 hex chars (compressed key)
  static final _userIdPattern =
      RegExp(r'^[a-fA-F0-9]{32}$|^[a-fA-F0-9]{66}$');

  // Hex string pattern
  static final _hexPattern = RegExp(r'^[a-fA-F0-9]*$');

  /// Validate user ID format (32 hex characters pre-DKG or 66 after DKG).
  /// Throws GrpcError.invalidArgument if invalid.
  static void validateUserId(String userId) {
    if (userId.isEmpty) {
      throw GrpcError.invalidArgument('user_id is required');
    }
    if (!_userIdPattern.hasMatch(userId)) {
      throw GrpcError.invalidArgument(
          'user_id must be 32 or 66 hex characters (got ${userId.length} chars)');
    }
  }

  /// Validate hex string format with optional length constraints.
  /// Throws GrpcError.invalidArgument if invalid.
  static void validateHexString(String value, String fieldName,
      {int? maxLength, bool required = true}) {
    if (value.isEmpty) {
      if (required) {
        throw GrpcError.invalidArgument('$fieldName is required');
      }
      return;
    }
    if (!_hexPattern.hasMatch(value)) {
      throw GrpcError.invalidArgument('$fieldName must be valid hex');
    }
    if (maxLength != null && value.length > maxLength) {
      throw GrpcError.invalidArgument(
          '$fieldName exceeds max length ($maxLength characters)');
    }
  }

  /// Validate JSON string format.
  /// Throws GrpcError.invalidArgument if invalid.
  static void validateJsonString(String value, String fieldName,
      {bool required = true}) {
    if (value.isEmpty) {
      if (required) {
        throw GrpcError.invalidArgument('$fieldName is required');
      }
      return;
    }
    try {
      jsonDecode(value);
    } catch (e) {
      throw GrpcError.invalidArgument('$fieldName is not valid JSON');
    }
  }

  /// Validate byte array with optional length constraints.
  /// Throws GrpcError.invalidArgument if invalid.
  static void validateBytes(List<int> value, String fieldName,
      {int? exactLength, int? maxLength, bool required = true}) {
    if (value.isEmpty) {
      if (required) {
        throw GrpcError.invalidArgument('$fieldName is required');
      }
      return;
    }
    if (exactLength != null && value.length != exactLength) {
      throw GrpcError.invalidArgument(
          '$fieldName must be exactly $exactLength bytes (got ${value.length})');
    }
    if (maxLength != null && value.length > maxLength) {
      throw GrpcError.invalidArgument(
          '$fieldName exceeds max length ($maxLength bytes)');
    }
  }

  /// Validate transaction hex string.
  /// Max size ~100KB (200000 hex chars) for standard transactions.
  static void validateTxHex(String txHex) {
    validateHexString(txHex, 'tx_hex', maxLength: 200000);
    // Minimum valid tx is ~60 bytes = 120 hex chars
    if (txHex.length < 120) {
      throw GrpcError.invalidArgument(
          'tx_hex is too short to be a valid transaction');
    }
  }

  /// Validate identifier bytes (participant ID).
  /// Expected to be 32 bytes for secp256k1 scalar.
  static void validateIdentifier(List<int> identifier) {
    validateBytes(identifier, 'identifier', exactLength: 32);
  }

  /// Validate positive integer amount.
  static void validateAmount(int amount, String fieldName) {
    if (amount < 0) {
      throw GrpcError.invalidArgument('$fieldName must be non-negative');
    }
  }

  /// Validate interval duration in seconds.
  static void validateInterval(int intervalSeconds, String fieldName) {
    if (intervalSeconds < 1) {
      throw GrpcError.invalidArgument('$fieldName must be at least 1 second');
    }
    // Max 1 year
    if (intervalSeconds > 31536000) {
      throw GrpcError.invalidArgument('$fieldName exceeds maximum (1 year)');
    }
  }
}
