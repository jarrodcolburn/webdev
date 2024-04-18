// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @JS()
library debug_session;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:built_collection/built_collection.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:dwds/data/debug_info.dart';
import 'package:dwds/data/devtools_request.dart';
import 'package:dwds/data/extension_request.dart';
import 'package:dwds/shared/batched_stream.dart';
import 'package:dwds/src/sockets.dart';
// import 'package:js/js.dart';
// import 'package:js/js_util.dart' as js_util;
import 'package:sse/client/sse_client.dart';
import 'package:web/web.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'chrome_api.dart';
import 'cider_connection.dart';
import 'cross_extension_communication.dart';
import 'data_serializers.dart';
import 'data_types.dart';
import 'logger.dart';
import 'messaging.dart';
import 'storage.dart';
import 'utils.dart';
import 'web_api.dart';

const _notADartAppAlert = 'No Dart application detected.'
    ' Are you trying to debug an application that includes a Chrome hosted app'
    ' (an application listed in chrome://apps)? If so, debugging is disabled.'
    ' You can fix this by removing the application from chrome://apps. Please'
    ' see https://bugs.chromium.org/p/chromium/issues/detail?id=885025#c11.';

const _devToolsAlreadyOpenedAlert =
    'DevTools is already opened on a different window.';

final _debugSessions = <_DebugSession>[];
final _tabIdToTrigger = <int, Trigger>{};

// enum DetachReason {
//   canceledByUser,
//   connectionErrorEvent,
//   connectionDoneEvent,
//   devToolsTabClosed,
//   navigatedAwayFromApp,
//   staleDebugSession,
//   unknown;

//   factory DetachReason.fromString(String value) {
//     return DetachReason.values.byName(value);
//   }
// }

enum ConnectFailureReason {
  authentication,
  noDartApp,
  timeout,
  unknown;

  factory ConnectFailureReason.fromString(String value) {
    return ConnectFailureReason.values.byName(value);
  }
}

enum TabType {
  dartApp,
  devTools,
}

enum Trigger {
  angularDartDevTools,
  cider,
  extensionPanel,
  extensionIcon,
}

enum DebuggerLocation {
  angularDartDevTools,
  chromeDevTools,
  dartDevTools,
  ide;

  String get displayName => switch (this) {
        DebuggerLocation.angularDartDevTools => 'AngularDart DevTools',
        DebuggerLocation.chromeDevTools => 'Chrome DevTools',
        DebuggerLocation.dartDevTools => 'a Dart DevTools tab',
        DebuggerLocation.ide => 'an IDE'
      };
}

bool get existsActiveDebugSession => _debugSessions.isNotEmpty;

int? get latestAppBeingDebugged =>
    existsActiveDebugSession ? _debugSessions.last.appTabId : null;

Future<void> attachDebugger(
  int dartAppTabId, {
  required Trigger trigger,
}) async {
  // Validate that the tab can be debugged:
  final tabIsDebuggable = await _validateTabIsDebuggable(
    dartAppTabId,
    forwardErrorsToCider: trigger == Trigger.cider,
  );
  if (!tabIsDebuggable) return;
  debugLog('Attaching to tab $dartAppTabId', verbose: true);
  _tabIdToTrigger[dartAppTabId] = trigger;
  _registerDebugEventListeners();
  await chrome.debugger.attach(
    Debuggee(tabId: dartAppTabId),
    '1.3',
  );
  () => _enableExecutionContextReporting(dartAppTabId);
}

Future<bool> detachDebugger(
  int tabId, {
  required TabType type,
  required DetachReason reason,
}) async {
  final debugSession = _debugSessionForTab(tabId, type: type);
  if (debugSession case null) return false;
  final debuggee = Debuggee(tabId: debugSession.appTabId);
  await chrome.debugger.detach(debuggee);
  if (chrome.runtime.lastError case final RuntimeLastError error) {
    debugWarn(
      'Error detaching tab for reason: $reason. Error: ${error.message}',
    );
    return false;
  }
  await _handleDebuggerDetach(OnDetachEvent(source: debuggee, reason: reason));
  return true;
}

bool isActiveDebugSession(int tabId) =>
    _debugSessionForTab(tabId, type: TabType.dartApp) != null;

Future<void> clearStaleDebugSession(int tabId) async {
  final debugSession = _debugSessionForTab(tabId, type: TabType.dartApp);
  if (debugSession != null) {
    await detachDebugger(
      tabId,
      type: TabType.dartApp,
      reason: DetachReason.canceledByUser, // todo: was 'staleDebugSession'
    );
  } else {
    await _removeDebugSessionDataInStorage(tabId);
  }
}

Future<bool> _validateTabIsDebuggable(
  int dartAppTabId, {
  bool forwardErrorsToCider = false,
}) async {
  // Check if a debugger is already attached:
  final existingDebuggerLocation = _debuggerLocation(dartAppTabId);
  if (existingDebuggerLocation != null) {
    await _showWarning(
      'Already debugging in ${existingDebuggerLocation.displayName}.',
      forwardToCider: forwardErrorsToCider,
    );
    return false;
  }
  // Determine if this is a Dart app:
  final debugInfo = await fetchStorageObject<DebugInfo>(
    type: StorageObject.debugInfo,
    tabId: dartAppTabId,
  );
  if (debugInfo == null) {
    await _showWarning(
      'Not a Dart app.',
      forwardToCider: forwardErrorsToCider,
    );
    return false;
  }
  // Determine if there are multiple apps in the tab:
  final multipleApps = await fetchStorageObject<String>(
    type: StorageObject.multipleAppsDetected,
    tabId: dartAppTabId,
  );
  if (multipleApps != null) {
    await _showWarning(
      'Dart debugging is not supported in a multi-app environment.',
      forwardToCider: forwardErrorsToCider,
    );
    return false;
  }
  // Verify that the user is authenticated:
  final isAuthenticated = await _authenticateUser(dartAppTabId);
  return isAuthenticated;
}

void _registerDebugEventListeners() {
  chrome.debugger.onEvent.listen(_onDebuggerEvent);
  chrome.debugger.onDetach.listen(
    ((onDetachEvent) async {
      await _handleDebuggerDetach(
        OnDetachEvent(
            source: onDetachEvent.source, reason: DetachReason.canceledByUser),
      );
    }),
  );
  chrome.tabs.onRemoved.listen((onRemovedEvent) {
    detachDebugger(
      onRemovedEvent.tabId,
      type: TabType.devTools,
      reason: DetachReason.targetClosed,
    );
  });
}

_enableExecutionContextReporting(int tabId) async {
  // Runtime.enable enables reporting of execution contexts creation by means of
  // executionContextCreated event. When the reporting gets enabled the event
  // will be sent immediately for each existing execution context:
  await chrome.debugger.sendCommand(
    Debuggee(tabId: tabId),
    'Runtime.enable',
    EmptyParam(),
  );
  if (chrome.runtime.lastError?.message case final String chromeError) {
    final errorMessage = _translateChromeError(chromeError);
    displayNotification(errorMessage, isError: true);
  }
}

String _translateChromeError(String chromeErrorMessage) {
  if (chromeErrorMessage.contains('Cannot access') ||
      chromeErrorMessage.contains('Cannot attach')) {
    return _notADartAppAlert;
  }
  return _devToolsAlreadyOpenedAlert;
}

Future<void> _onDebuggerEvent(
  OnEventEvent onEventEvent,
) async {
  final OnEventEvent(:source, :method, :params) = onEventEvent;

  final tabId = source.tabId;
  if (tabId != null) {
    maybeForwardMessageToAngularDartDevTools(
      method: method,
      params: params,
      tabId: tabId,
    );
  } else {
    debugWarn('No tab ID found for debugger event: $method');
  }

  if (method == 'Runtime.executionContextCreated') {
    // Only try to connect to DWDS if we don't already have a debugger instance:
    if (tabId != null && _debuggerLocation(tabId) == null) {
      return _maybeConnectToDwds(tabId, params);
    }
  }

  return _forwardChromeDebuggerEventToDwds(source, method, params);
}

Future<void> _maybeConnectToDwds(int tabId, Object? params) async {
  final context = json.decode(JSON.stringify(params))['context'];
  final contextOrigin = context['origin'] as String?;
  if (contextOrigin == null) return;
  if (contextOrigin.contains(('chrome-extension:'))) return;
  final debugInfo = await fetchStorageObject<DebugInfo>(
    type: StorageObject.debugInfo,
    tabId: tabId,
  );
  if (debugInfo == null) return;
  if (contextOrigin != debugInfo.appOrigin) return;
  final contextId = context['id'] as int;
  // Find the correct frame to connect to (this is necessary if the Dart app is
  // embedded in an IFRAME):
  final isDartFrame = await _isDartFrame(tabId: tabId, contextId: contextId);
  if (!isDartFrame) return;
  final connected = await _connectToDwds(
    dartAppContextId: contextId,
    dartAppTabId: tabId,
    debugInfo: debugInfo,
  );
  if (!connected) {
    debugWarn('Failed to connect to DWDS for $contextOrigin.');
    await _sendConnectFailureMessage(
      ConnectFailureReason.unknown,
      dartAppTabId: tabId,
    );
  }
}

Future<bool> _isDartFrame({required int tabId, required int contextId}) async {
  final response = await chrome.debugger
      .sendCommand(Debuggee(tabId: tabId), 'Runtime.evaluate', {
    'expression':
        '[window.\$dartAppId, window.\$dartAppInstanceId, window.\$dwdsVersion]',
    'returnByValue': true,
    contextId: contextId,
  });
  // FIXME
  final evalResponse = response as _EvalResponse;
  final value = evalResponse.result.value;
  final appId = value?[0];
  final instanceId = value?[1];
  final dwdsVersion = value?[2];
  final frameIdentifier = 'Frame at tab $tabId with context $contextId';
  if (appId == null || instanceId == null) {
    debugWarn('$frameIdentifier is not a Dart frame.');
    return false;
  }
  debugLog('Dart $frameIdentifier is using DWDS $dwdsVersion.');
  return true;
}

Future<bool> _connectToDwds({
  required int dartAppContextId,
  required int dartAppTabId,
  required DebugInfo debugInfo,
}) async {
  if (debugInfo.extensionUrl == null) {
    debugWarn('Can\'t connect to DWDS without an extension URL.');
    return false;
  }
  final uri = Uri.parse(debugInfo.extensionUrl!);
  // Start the client connection with DWDS:
  final client = uri.isScheme('ws') || uri.isScheme('wss')
      ? WebSocketClient(WebSocketChannel.connect(uri))
      : SseSocketClient(SseClient(uri.toString(), debugKey: 'DebugExtension'));
  final trigger = _tabIdToTrigger[dartAppTabId];
  debugLog('Connecting to DWDS...', verbose: true);
  final debugSession = _DebugSession(
    client: client,
    appTabId: dartAppTabId,
    trigger: trigger,
    onIncoming: (data) => _routeDwdsEvent(data, client, dartAppTabId),
    onDone: () async {
      await detachDebugger(
        dartAppTabId,
        type: TabType.dartApp,
        reason: DetachReason.canceledByUser, // TODO was 'connectionDoneEvent'
      );
    },
    onError: (err) async {
      debugWarn('Connection error: $err', verbose: true);
      await detachDebugger(
        dartAppTabId,
        type: TabType.dartApp,
        reason: DetachReason.targetClosed, // TODO was 'connectionErrorEvent'
      );
    },
    cancelOnError: true,
  );
  _debugSessions.add(debugSession);
  // Send a DevtoolsRequest to the event stream:
  final tabUrl = await _getTabUrl(dartAppTabId);
  debugSession.sendEvent(
    DevToolsRequest(
      (b) => b
        ..appId = debugInfo.appId
        ..instanceId = debugInfo.appInstanceId
        ..contextId = dartAppContextId
        ..tabUrl = tabUrl
        ..uriOnly = true,
    ),
  );
  return true;
}

void _routeDwdsEvent(String eventData, SocketClient client, int tabId) {
  final message = serializers.deserialize(jsonDecode(eventData));
  if (message is ExtensionRequest) {
    _forwardDwdsEventToChromeDebugger(message, client, tabId);
  } else if (message is ExtensionEvent) {
    maybeForwardMessageToAngularDartDevTools(
      method: message.method,
      params: message.params,
      tabId: tabId,
    );
    if (message.method == 'dwds.devtoolsUri') {
      if (_tabIdToTrigger[tabId] == Trigger.cider) {
        // Save the DevTools URI so that Cider can request it later:
        setStorageObject(
          type: StorageObject.devToolsUri,
          value: message.params,
          tabId: tabId,
        );
      } else {
        _openDevTools(message.params, dartAppTabId: tabId);
      }
    }
    if (message.method == 'dwds.debugUri') {
      debugLog('Sending debug URI to Cider ${message.params}', verbose: true);
      sendMessageToCider(
        messageType: CiderMessageType.startDebugResponse,
        messageBody: message.params,
      );
    }
    if (message.method == 'dwds.encodedUri') {
      setStorageObject(
        type: StorageObject.encodedUri,
        value: message.params,
        tabId: tabId,
      );
    }
  }
}

Future _forwardDwdsEventToChromeDebugger(
  ExtensionRequest message,
  SocketClient client,
  int tabId,
) async {
  try {
    final messageParams = message.commandParams;
    final params = messageParams == null
        ? <String, Object>{}
        : BuiltMap<String, Object>(json.decode(messageParams)).toMap();

    final e = await chrome.debugger
        .sendCommand(Debuggee(tabId: tabId), message.command, params);
    // No arguments indicate that an error occurred.
    if (e == null) {
      client.sink.add(
        jsonEncode(
          serializers.serialize(
            ExtensionResponse(
              (b) => b
                ..id = message.id
                ..success = false
                ..result = JSON.stringify(chrome.runtime.lastError),
            ),
          ),
        ),
      );
    } else {
      client.sink.add(
        jsonEncode(
          serializers.serialize(
            ExtensionResponse(
              (b) => b
                ..id = message.id
                ..success = true
                ..result = JSON.stringify(e),
            ),
          ),
        ),
      );
    }
  } catch (error) {
    debugError(
      'Error forwarding ${message.command} with ${message.commandParams} to chrome.debugger: $error',
    );
  }
}

void _forwardChromeDebuggerEventToDwds(
  Debuggee source,
  String method,
  dynamic params,
) {
  final debugSession = _debugSessions
      .firstWhereOrNull((session) => session.appTabId == source.tabId);
  if (debugSession == null) return;
  final event = _extensionEventFor(method, params);
  if (method == 'Debugger.scriptParsed') {
    debugSession.sendBatchedEvent(event);
  } else {
    debugSession.sendEvent(event);
  }
}

Future<void> _openDevTools(
  String devToolsUri, {
  required int dartAppTabId,
}) async {
  if (devToolsUri.isEmpty) {
    debugError('DevTools URI is empty.');
    return;
  }
  final debugSession = _debugSessionForTab(dartAppTabId, type: TabType.dartApp);
  if (debugSession == null) {
    debugError('Debug session not found.');
    return;
  }
  // Save the DevTools URI so that the extension panels have access to it:
  await setStorageObject(
    type: StorageObject.devToolsUri,
    value: devToolsUri,
    tabId: dartAppTabId,
  );
  // Open a separate tab / window if triggered through the extension icon or
  // through AngularDart DevTools:
  if (debugSession.trigger == Trigger.extensionIcon ||
      debugSession.trigger == Trigger.angularDartDevTools) {
    final devToolsOpener = await fetchStorageObject<DevToolsOpener>(
      type: StorageObject.devToolsOpener,
    );
    final devToolsTab = await createTab(
      addQueryParameters(
        devToolsUri,
        queryParameters: {
          'ide': 'DebugExtension',
        },
      ),
      inNewWindow: devToolsOpener?.newWindow ?? false,
    );
    debugSession.devToolsTabId = devToolsTab.id;
  }
}

Future<void> _handleDebuggerDetach(OnDetachEvent onDetachEvent) async {
  final OnDetachEvent(:source, :reason) = onDetachEvent;
  final Debuggee(:tabId) = source;
  debugLog(
    'Debugger detached due to: $reason',
    verbose: true,
    prefix: '$tabId',
  );
  final debugSession = _debugSessionForTab(tabId, type: TabType.dartApp);
  if (debugSession != null) {
    debugLog('Removing debug session...');
    _removeDebugSession(debugSession);
    // Notify the extension panels that the debug session has ended:

    if (tabId case null) {
      debugLog('Tab ID is null.');
    } else {
      await _sendStopDebuggingMessage(reason, dartAppTabId: tabId);
    }
    // Maybe close the associated DevTools tab as well:
    await _maybeCloseDevTools(debugSession.devToolsTabId);
  }
  if (tabId case null) {
    debugLog('Tab ID is null.');
  } else {
    await _removeDebugSessionDataInStorage(tabId);
  }
}

Future<void> _maybeCloseDevTools(int? devToolsTabId) async {
  if (devToolsTabId == null) return;
  final devToolsTab = await chrome.tabs.get(devToolsTabId);
  if (devToolsTab != null) {
    debugLog('Closing DevTools tab...');
    await removeTab(devToolsTabId);
  }
}

Future<void> _removeDebugSessionDataInStorage(int tabId) async {
  // Remove the DevTools URI, encoded URI, and multiple apps info from storage:
  await removeStorageObject(
    type: StorageObject.devToolsUri,
    tabId: tabId,
  );
  await removeStorageObject(
    type: StorageObject.encodedUri,
    tabId: tabId,
  );
  await removeStorageObject(
    type: StorageObject.multipleAppsDetected,
    tabId: tabId,
  );
}

void _removeDebugSession(_DebugSession debugSession) {
  // Note: package:sse will try to keep the connection alive, even after the
  // client has been closed. Therefore the extension sends an event to notify
  // DWDS that we should close the connection, instead of relying on the done
  // event sent when the client is closed. See details:
  // https://github.com/dart-lang/webdev/pull/1595#issuecomment-1116773378
  final event = _extensionEventFor('DebugExtension.detached', {});
  debugSession.sendEvent(event);
  debugSession.close();
  final removed = _debugSessions.remove(debugSession);
  if (!removed) {
    debugWarn('Could not remove debug session.');
  }
}

Future<bool> _sendConnectFailureMessage(
  ConnectFailureReason reason, {
  required int dartAppTabId,
}) async {
  final json = jsonEncode(
    serializers.serialize(
      ConnectFailure(
        (b) => b
          ..tabId = dartAppTabId
          ..reason = reason.name,
      ),
    ),
  );
  return await sendRuntimeMessage(
    type: MessageType.connectFailure,
    body: json,
    sender: Script.background,
    recipient: Script.debuggerPanel,
  );
}

Future<bool> _sendStopDebuggingMessage(
  DetachReason reason, {
  required int dartAppTabId,
}) async {
  final json = jsonEncode(
    serializers.serialize(
      DebugStateChange(
        (b) => b
          ..tabId = dartAppTabId
          ..reason = reason.name
          ..newState = DebugStateChange.stopDebugging,
      ),
    ),
  );
  return await sendRuntimeMessage(
    type: MessageType.debugStateChange,
    body: json,
    sender: Script.background,
    recipient: Script.debuggerPanel,
  );
}

_DebugSession? _debugSessionForTab(tabId, {required TabType type}) {
  switch (type) {
    case TabType.dartApp:
      return _debugSessions
          .firstWhereOrNull((session) => session.appTabId == tabId);
    case TabType.devTools:
      return _debugSessions
          .firstWhereOrNull((session) => session.devToolsTabId == tabId);
  }
}

Future<bool> _authenticateUser(int tabId) async {
  final isAlreadyAuthenticated = await _fetchIsAuthenticated(tabId);
  if (isAlreadyAuthenticated) return true;
  final debugInfo = await fetchStorageObject<DebugInfo>(
    type: StorageObject.debugInfo,
    tabId: tabId,
  );
  final authUrl = debugInfo?.authUrl ?? _authUrl(debugInfo?.extensionUrl);
  if (authUrl == null) {
    await _showWarningNotification('Cannot authenticate user.');
    return false;
  }
  final isAuthenticated = await _sendAuthRequest(authUrl);
  if (isAuthenticated) {
    await setStorageObject<String>(
      type: StorageObject.isAuthenticated,
      value: '$isAuthenticated',
      tabId: tabId,
    );
  } else {
    await _sendConnectFailureMessage(
      ConnectFailureReason.authentication,
      dartAppTabId: tabId,
    );
    await createTab(authUrl, inNewWindow: false);
  }
  return isAuthenticated;
}

Future<bool> _fetchIsAuthenticated(int tabId) async {
  final authenticated = await fetchStorageObject<String>(
    type: StorageObject.isAuthenticated,
    tabId: tabId,
  );
  return authenticated == 'true';
}

Future<bool> _sendAuthRequest(String authUrl) async {
  return (await (await fetchRequest(authUrl)).text().toDart)
      .toDart
      .contains('Dart Debug Authentication Success!');
}

Future<bool> _showWarning(
  String message, {
  bool forwardToCider = false,
}) {
  if (forwardToCider) {
    sendErrorMessageToCider(
      errorType: CiderErrorType.invalidRequest,
      errorDetails: message,
    );
    return Future.value(true);
  } else {
    return _showWarningNotification(message);
  }
}

Future<bool> _showWarningNotification(String message) {
  final completer = Completer<bool>();
  displayNotification(
    message,
    isError: true,
    callback: (_) {
      completer.complete(true);
    },
  );
  return completer.future;
}

DebuggerLocation? _debuggerLocation(int dartAppTabId) {
  final debugSession = _debugSessionForTab(dartAppTabId, type: TabType.dartApp);
  final trigger = _tabIdToTrigger[dartAppTabId];
  if (debugSession == null || trigger == null) return null;

  switch (trigger) {
    case Trigger.extensionIcon:
      if (debugSession.devToolsTabId != null) {
        return DebuggerLocation.dartDevTools;
      } else {
        return DebuggerLocation.ide;
      }
    case Trigger.angularDartDevTools:
      return DebuggerLocation.angularDartDevTools;
    case Trigger.extensionPanel:
      return DebuggerLocation.chromeDevTools;
    case Trigger.cider:
      return DebuggerLocation.ide;
  }
}

/// Construct an [ExtensionEvent] from [method] and [params].
ExtensionEvent _extensionEventFor(String method, Map params) {
  return ExtensionEvent(
    (b) => b
      ..params = jsonEncode(params)
      ..method = jsonEncode(method),
  );
}

Future<String> _getTabUrl(int tabId) async =>
    (await chrome.tabs.get(tabId)).url ?? '';

get EmptyParam => {};

// @JS()
// @anonymous
// class EmptyParam {
//   external factory EmptyParam();
// }

class _DebugSession {
  // The tab ID that contains the running Dart application.
  final int appTabId;

  // What triggered the debug session (debugger panel, extension icon, etc.)
  final Trigger? trigger;

  // Socket client for communication with dwds extension backend.
  late final SocketClient _socketClient;

  // How often to send batched events.
  static const int _batchDelayMilliseconds = 1000;

  // The tab ID that contains the corresponding Dart DevTools, if it exists.
  int? devToolsTabId;

  // Collect events into batches to be send periodically to the server.
  final _batchController =
      BatchedStreamController<ExtensionEvent>(delay: _batchDelayMilliseconds);
  late final StreamSubscription<List<ExtensionEvent>> _batchSubscription;

  _DebugSession({
    required client,
    required this.appTabId,
    required this.trigger,
    required void Function(String data) onIncoming,
    required void Function() onDone,
    required void Function(dynamic error) onError,
    required bool cancelOnError,
  }) : _socketClient = client {
    // Collect extension events and send them periodically to the server.
    _batchSubscription = _batchController.stream.listen((events) {
      _socketClient.sink.add(
        jsonEncode(
          serializers.serialize(
            BatchedEvents(
              (b) => b.events = ListBuilder<ExtensionEvent>(events),
            ),
          ),
        ),
      );
    });
    // Listen for incoming events:
    _socketClient.stream.listen(
      onIncoming,
      onDone: onDone,
      onError: onError,
      cancelOnError: cancelOnError,
    );
  }

  set socketClient(SocketClient client) {
    _socketClient = client;

    // Collect extension events and send them periodically to the server.
    _batchSubscription = _batchController.stream.listen((events) {
      _socketClient.sink.add(
        jsonEncode(
          serializers.serialize(
            BatchedEvents(
              (b) => b.events = ListBuilder<ExtensionEvent>(events),
            ),
          ),
        ),
      );
    });
  }

  void sendEvent<T>(T event) {
    try {
      _socketClient.sink.add(jsonEncode(serializers.serialize(event)));
    } catch (error) {
      debugError('Error sending event $event: $error');
    }
  }

  void sendBatchedEvent(ExtensionEvent event) {
    try {
      _batchController.sink.add(event);
    } catch (error) {
      debugError('Error sending batched event $event: $error');
    }
  }

  void close() {
    try {
      _socketClient.close();
    } catch (error) {
      debugError('Error closing socket client: $error');
    }
    try {
      _batchSubscription.cancel();
    } catch (error) {
      debugError('Error canceling batch subscription: $error');
    }
    try {
      _batchController.close();
    } catch (error) {
      debugError('Error closing batch controller: $error');
    }
  }
}

String? _authUrl(String? extensionUrl) {
  if (extensionUrl == null) return null;
  final authUrl = Uri.parse(extensionUrl).replace(path: authenticationPath);
  switch (authUrl.scheme) {
    case 'ws':
      return authUrl.replace(scheme: 'http').toString();
    case 'wss':
      return authUrl.replace(scheme: 'https').toString();
    default:
      return authUrl.toString();
  }
}

extension type _EvalResponse(JSObject map) implements JSObject {
  external _EvalResult get result;
}

@JS()
@anonymous
class _EvalResult {
  external List<String?>? get value;
}

@JS()
@anonymous
class _InjectedParams {
  external String get expresion;
  external bool get returnByValue;
  external int get contextId;
  external factory _InjectedParams({
    String? expression,
    bool? returnByValue,
    int? contextId,
  });
}
