import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bitcoin_base/bitcoin_base.dart';
import 'package:blockchain_utils/blockchain_utils.dart';

class ElectrumTcpServiceImpl implements ElectrumServiceProvider {
  final String domain;
  final int port;
  final Duration connectionTimeout;
  final bool useSSL;

  Socket? _socket;
  StreamSubscription? _subscription;

  // Use a broadcast controller for notifications
  final _notificationController =
      StreamController<ElectrumRequestDetails>.broadcast();

  Stream<ElectrumRequestDetails> get notifications =>
      _notificationController.stream;

  // Pending requests: ID -> Completer
  final Map<int, Completer<dynamic>> _pendingRequests = {};
  int _nextId = 0;

  ElectrumTcpServiceImpl({
    required this.domain,
    required this.port,
    this.connectionTimeout = const Duration(seconds: 30),
    this.useSSL = false,
  });

  /// Open connection if not already open
  Future<void> connect() async {
    if (_socket != null) return;

    print("Connecting to $domain:$port (SSL: $useSSL)...");
    try {
      if (useSSL || port == 443 || port == 50002) {
        _socket = await SecureSocket.connect(domain, port,
            timeout: connectionTimeout);
      } else {
        _socket =
            await Socket.connect(domain, port, timeout: connectionTimeout);
      }
      print("Connected to $domain:$port");

      _subscription = _socket!
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onMessage, onError: _onError, onDone: _onDone);
    } catch (e) {
      print("Connection Failed: $e");
      _closeCleanup();
      rethrow;
    }
  }

  void _onMessage(String line) {
    if (line.isEmpty) return;
    // print("RX: $line"); // Uncomment for spam
    try {
      final Map<String, dynamic> msg = jsonDecode(line);

      if (msg.containsKey('id') && msg['id'] != null) {
        // Response
        final id = msg['id'];
        if (_pendingRequests.containsKey(id)) {
          final completer = _pendingRequests.remove(id)!;
          if (msg.containsKey('error') && msg['error'] != null) {
            // Handle Error. Electrum errors can be strings or objects.
            completer.completeError(msg['error']);
          } else {
            completer.complete(msg['result']);
          }
        }
      } else if (msg.containsKey('method') &&
          msg['method'].endsWith('.subscribe')) {
        // Notification
        // params: [scripthash, status]
        if (msg.containsKey('params')) {
          final params = msg['params'];
          Map<String, dynamic> paramsMap = {};
          if (params is List) {
            for (int i = 0; i < params.length; i++) {
              paramsMap['$i'] = params[i];
            }
          } else if (params is Map) {
            paramsMap = Map<String, dynamic>.from(params);
          }

          _notificationController.add(ElectrumRequestDetails(
            method: msg['method'],
            params: paramsMap,
            requestID: 0,
            type: RequestServiceType.post,
          ));
        }
      }
    } catch (e) {
      print("JSONRPC Parse Error: $e");
    }
  }

  void _onError(Object error) {
    print("Electrum Socket Error: $error");
    _closeCleanup();
  }

  void _onDone() {
    print("Electrum Socket Closed");
    _closeCleanup();
  }

  void _closeCleanup() {
    _socket?.destroy();
    _socket = null;
    _subscription?.cancel();
    _subscription = null;

    // Fail all pending
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) c.completeError(StateError("Connection closed"));
    }
    _pendingRequests.clear();
  }

  Future<void> disconnect() async {
    _closeCleanup();
  }

  @override
  Future<BaseServiceResponse<T>> doRequest<T>(ElectrumRequestDetails request,
      {Duration? timeout}) async {
    if (_socket == null) {
      await connect();
    }

    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pendingRequests[id] = completer;

    final payload = {
      "jsonrpc": "2.0",
      "method": request.method,
      "params": request.params,
      "id": id,
    };

    // Add newline delimiter
    _socket!.write(jsonEncode(payload) + '\n');

    try {
      final result = await completer.future;
      // Use our concrete implementation
      return ElectrumServiceResponse<T>(result);
    } catch (e) {
      rethrow;
    }
  }
}

class ElectrumServiceResponse<T> implements BaseServiceResponse<T> {
  final T _result;
  ElectrumServiceResponse(this._result);

  @override
  T getResult(BaseServiceRequestParams request) => _result;

  @override
  E cast<E extends BaseServiceResponse<dynamic>>() {
    if (this is E) return this as E;
    throw StateError("Cannot cast $runtimeType to $E");
  }

  @override
  int get statusCode => 200;

  @override
  ServiceResponseType get type => ServiceResponseType.success;
}
