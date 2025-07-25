import 'dart:isolate';

import 'package:rwkv_flutter/src/logger.dart';
import 'package:rwkv_flutter/src/rwkv.dart';
import 'package:rwkv_flutter/src/runtime.dart';

class IsolateMessage {
  final String id;
  final String method;
  final dynamic param;
  final String error;
  final bool done;

  static int _incrementId = 0;

  bool get isInitialMessage => id == 'initial';

  const IsolateMessage({
    required this.id,
    required this.method,
    required this.param,
    this.done = false,
    this.error = '',
  });

  factory IsolateMessage.initialMessage(SendPort sendPort) {
    return IsolateMessage(id: 'initial', method: 'init', param: sendPort);
  }

  factory IsolateMessage.fromFunc(Function func, [dynamic param]) {
    _incrementId++;
    return IsolateMessage(
      id: '${_incrementId}',
      method: func.toString(),
      param: param,
    );
  }

  IsolateMessage copyWith({
    String? id,
    String? method,
    dynamic param,
    bool? done,
    String? error,
  }) {
    return IsolateMessage(
      id: id ?? this.id,
      method: method ?? this.method,
      param: param ?? this.param,
      done: done ?? this.done,
      error: error ?? this.error,
    );
  }

  @override
  String toString() {
    return 'IsolateMessage{id: $id, method: $method, param: $param, done: $done, error: $error}';
  }
}

class RWKVIsolateProxy implements RWKV {
  late final SendPort sendPort;
  late final Stream<IsolateMessage> events;

  @override
  Future init(InitParam param) async {
    // init isolate
    ReceivePort receivePort = ReceivePort('rwkv_proxy_receive_port');
    events = receivePort.cast<IsolateMessage>().asBroadcastStream();
    await _IsolatedRWKV.spawn(receivePort.sendPort);
    final initMessage = await events.firstWhere((e) => e.isInitialMessage);
    sendPort = initMessage.param as SendPort;
    logDebug('isolate init done');

    // init runtime
    await _call(init, param).first;
  }

  @override
  Future initRuntime(InitRuntimeParam param) => _call(initRuntime, param).first;

  @override
  Future loadEmbedding(String path) => _call(loadEmbedding, path).first;

  @override
  Future<List<num>> embed(String text) async =>
      await _call(embed, text).first as List<num>;

  @override
  Future<num> similarity(SimilarityParam param) async =>
      _call(similarity, param).first as num;

  @override
  Stream<String> chat(List<String> history) =>
      _call(chat, history).cast<String>();

  @override
  Future clearState() => _call(clearState).first;

  @override
  Stream<String> completion(String prompt) =>
      _call(completion, prompt).cast<String>();

  @override
  Future setAudio(String path) => _call(setAudio, path).first;

  @override
  Future setImage(String path) => _call(setImage, path).first;

  @override
  Future setPenaltyParam(PenaltyParam param) =>
      _call(setPenaltyParam, param).first;

  @override
  Future setSamplerParam(SamplerParam param) =>
      _call(setSamplerParam, param).first;

  @override
  Future setGenerationParam(GenerationParam param) =>
      _call(setGenerationParam, param).first;

  @override
  Future<TextGenerationState> getGenerationState() async =>
      await _call(getGenerationState).first as TextGenerationState;

  @override
  Future stop() => _call(stop).first;

  Stream _call(Function method, [dynamic param]) async* {
    final message = IsolateMessage.fromFunc(method, param);
    sendPort.send(message);
    final src = events.where((e) => e.id == message.id);
    await for (final message in src) {
      if (message.error != '') {
        throw Exception(message.error);
      }
      if (message.done) {
        break;
      }
      yield message.param;
    }
  }
}

class _IsolatedRWKV implements RWKV {
  final Map<String, Function> handlers = {};
  late final RWKVRuntime runtime = RWKVRuntime();
  late final SendPort sendPort;
  late final ReceivePort receivePort = ReceivePort('rwkv_isolate_receive_port');

  _IsolatedRWKV._();

  static Future<Isolate> spawn(SendPort sendPort) async {
    final rwkvIsolate = _IsolatedRWKV._();
    final initialMessage = IsolateMessage.initialMessage(sendPort);
    final isolate = await Isolate.spawn<IsolateMessage>(
      rwkvIsolate._onIsolateSpawn,
      initialMessage,
    );
    return isolate;
  }

  Future _onIsolateSpawn(IsolateMessage init) async {
    _initHandler();
    sendPort = init.param as SendPort;
    sendPort.send(init.copyWith(param: receivePort.sendPort));

    receivePort.cast<IsolateMessage>().listen(
      (message) async {
        try {
          await _handleMessage(message.copyWith(error: '', done: false));
        } on NoSuchMethodError {
          final msg =
              'MethodInvocationError: method:${message.method}, param:${message.param}.';
          sendPort.send(message.copyWith(error: msg));
        } catch (e, s) {
          logError(s);
          sendPort.send(message.copyWith(error: e.toString()));
        }
      },
      onError: (e) {
        logError(e);
      },
      onDone: () {
        logDebug('rwkv isolate receive port done');
      },
    );
  }

  Future _handleMessage(IsolateMessage message) async {
    final method = message.method;
    final param = message.param;

    dynamic res;
    if (message.isInitialMessage) {
      _initHandler();
      sendPort = param as SendPort;
      sendPort.send(message.copyWith(param: receivePort.sendPort));
    } else {
      final handler = handlers[method];
      if (handler == null) {
        throw Exception('😡 Unknown method: $method');
      }
      res = param == null ? handler() : handler(param);
    }
    if (res is Future) {
      res = await res;
      sendPort.send(message.copyWith(param: res));
    } else if (res is Stream) {
      res.listen(
        (event) {
          sendPort.send(message.copyWith(param: event));
        },
        onDone: () {
          sendPort.send(message.copyWith(done: true));
        },
        onError: (e) {
          sendPort.send(message.copyWith(error: e.toString()));
        },
      );
    } else {
      sendPort.send(message.copyWith(param: res));
    }
  }

  void _initHandler() {
    final methods = {
      init,
      initRuntime,
      loadEmbedding,
      embed,
      similarity,
      chat,
      clearState,
      completion,
      setAudio,
      setImage,
      setPenaltyParam,
      setSamplerParam,
      setGenerationParam,
      getGenerationState,
      stop,
    };
    for (final method in methods) {
      handlers[method.toString()] = method;
    }
  }

  Future init(InitParam param) => runtime.init(param);

  @override
  Future initRuntime(InitRuntimeParam param) => runtime.initRuntime(param);

  @override
  Future loadEmbedding(String path) => runtime.loadEmbedding(path);

  @override
  Future<List<num>> embed(String text) => runtime.embed(text);

  @override
  Future<num> similarity(SimilarityParam param) => runtime.similarity(param);

  @override
  Stream<String> chat(List<String> history) => runtime.chat(history);

  @override
  Future clearState() => runtime.clearState();

  @override
  Stream<String> completion(String prompt) => runtime.completion(prompt);

  @override
  Future setAudio(String path) => runtime.setAudio(path);

  @override
  Future setImage(String path) => runtime.setImage(path);

  @override
  Future setPenaltyParam(PenaltyParam param) => runtime.setPenaltyParam(param);

  @override
  Future setSamplerParam(SamplerParam param) => runtime.setSamplerParam(param);

  @override
  Future setGenerationParam(GenerationParam param) =>
      runtime.setGenerationParam(param);

  @override
  Future<TextGenerationState> getGenerationState() =>
      runtime.getGenerationState();

  @override
  Future stop() => runtime.stop();
}
