// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library background;

import 'dart:js_interop';

import 'package:chrome_extension/action.dart';
import 'package:chrome_extension/web_navigation.dart';
import 'package:dwds/data/debug_info.dart';

import 'chrome_api.dart';
import 'cider_connection.dart';
import 'cross_extension_communication.dart';
import 'data_types.dart';
import 'debug_session.dart';
import 'logger.dart';
import 'messaging.dart';
import 'storage.dart';
import 'utils.dart';

void main() {
  _registerListeners();
}

DebugInfo _addTabInfo(DebugInfo debugInfo, {required Tab tab}) {
  return DebugInfo(
    (b) => b
      ..appEntrypointPath = debugInfo.appEntrypointPath
      ..appId = debugInfo.appId
      ..appInstanceId = debugInfo.appInstanceId
      ..appOrigin = debugInfo.appOrigin
      ..appUrl = debugInfo.appUrl
      ..authUrl = debugInfo.authUrl
      ..extensionUrl = debugInfo.extensionUrl
      ..isInternalBuild = debugInfo.isInternalBuild
      ..isFlutterApp = debugInfo.isFlutterApp
      ..workspaceName = debugInfo.workspaceName
      ..tabUrl = tab.url
      ..tabId = tab.id,
  );
}

Future<void> _detectNavigationAwayFromDartApp(
  OnCommittedDetails navigationInfo,
) async {
  // Ignore any navigation events within the page itself (e.g., opening a link,
  // reloading the page, reloading an IFRAME, etc):
  if (_isInternalNavigation(navigationInfo)) return;
  final tabId = navigationInfo.tabId;
  final debugInfo = await _fetchDebugInfo(navigationInfo.tabId);
  if (debugInfo == null) return;
  if (debugInfo.tabUrl != navigationInfo.url) {
    _setDefaultIcon(navigationInfo.tabId);
    await clearStaleDebugSession(tabId);
    await removeStorageObject(type: StorageObject.debugInfo, tabId: tabId);
    await detachDebugger(
      tabId,
      type: TabType.dartApp,
      reason: DetachReason.canceledByUser, // TODO was 'navigatedAwayFromApp'
    );
  }
}

Future<DebugInfo?> _fetchDebugInfo(int tabId) {
  return fetchStorageObject<DebugInfo>(
    type: StorageObject.debugInfo,
    tabId: tabId,
  );
}

Future<void> _handleRuntimeMessages(
  OnMessageEvent onMessageEvent,
) async {
  final OnMessageEvent(message: jsRequest, :sendResponse, :sender) =
      onMessageEvent;
  if (jsRequest is! String) return;

  interceptMessage<String>(
    message: jsRequest,
    expectedType: MessageType.isAuthenticated,
    expectedSender: Script.detector,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (String isAuthenticated) async {
      final dartTab = sender.tab;
      if (dartTab == null) {
        debugWarn('Received auth info but tab is missing.');
        return;
      }
      // Save the authentication info in storage:
      await setStorageObject<String>(
        type: StorageObject.isAuthenticated,
        value: isAuthenticated,
        tabId: dartTab.id,
      );
    },
  );

  interceptMessage<DebugInfo>(
    message: jsRequest,
    expectedType: MessageType.debugInfo,
    expectedSender: Script.detector,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (DebugInfo debugInfo) async {
      final dartTab = sender.tab;
      if (dartTab == null) {
        debugWarn('Received debug info but tab is missing.');
        return;
      }
      // If this is a new Dart app, we need to clear old debug session data:
      if (!await _matchesAppInStorage(debugInfo.appId,
          tabId: dartTab.id ??
              (throw Exception(
                  'Tab ID is missing when trying to clear old debug session data.',)),)) {
        await clearStaleDebugSession(dartTab.id ??
            (throw Exception(
                'Tab ID is missing when trying to clear stale debug session.',)),);
      }
      // Save the debug info for the Dart app in storage:
      await setStorageObject<DebugInfo>(
        type: StorageObject.debugInfo,
        value: _addTabInfo(debugInfo, tab: dartTab),
        tabId: dartTab.id,
      );
      // Update the icon to show that a Dart app has been detected:
      final currentTab = await activeTab;
      if (currentTab?.id == dartTab.id) {
        await _updateIcon(dartTab.id ??
            (throw Exception('Tab ID is missing when trying to update icon.')),);
      }
    },
  );

  interceptMessage<DebugStateChange>(
    message: jsRequest,
    expectedType: MessageType.debugStateChange,
    expectedSender: Script.debuggerPanel,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (DebugStateChange debugStateChange) {
      final newState = debugStateChange.newState;
      final tabId = debugStateChange.tabId;
      if (newState == DebugStateChange.startDebugging) {
        attachDebugger(tabId, trigger: Trigger.extensionPanel);
      }
    },
  );

  interceptMessage<DebugStateChange>(
    message: jsRequest,
    expectedType: MessageType.debugStateChange,
    expectedSender: Script.popup,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (DebugStateChange debugStateChange) {
      final newState = debugStateChange.newState;
      final tabId = debugStateChange.tabId;
      if (newState == DebugStateChange.startDebugging) {
        attachDebugger(tabId, trigger: Trigger.extensionIcon);
      }
    },
  );

  interceptMessage<String>(
    message: jsRequest,
    expectedType: MessageType.multipleAppsDetected,
    expectedSender: Script.detector,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (String multipleAppsDetected) async {
      final dartTab = sender.tab;
      if (dartTab == null) {
        debugWarn('Received multiple apps detected but tab is missing.');
        return;
      }
      // Save the multiple apps info in storage:
      await setStorageObject<String>(
        type: StorageObject.multipleAppsDetected,
        value: multipleAppsDetected,
        tabId: dartTab.id,
      );
      _setWarningIcon(dartTab.id ??
          (throw Exception('Tab ID is missing when setting warning icon.')),);
    },
  );

  interceptMessage<String>(
    message: jsRequest,
    expectedType: MessageType.appId,
    expectedSender: Script.copier,
    expectedRecipient: Script.background,
    sender: sender,
    messageHandler: (String appId) {
      displayNotification('Copied app ID: $appId');
    },
  );

  sendResponse.callAsFunction(defaultResponse);
}

bool _isInternalNavigation(OnCommittedDetails navigationInfo) {
  return [
    'auto_subframe',
    'form_submit',
    'link',
    'manual_subframe',
    'reload',
  ].contains(navigationInfo.transitionType);
}

Future<bool> _matchesAppInStorage(String? appId, {required int tabId}) async {
  final debugInfo = await _fetchDebugInfo(tabId);
  return appId != null && appId == debugInfo?.appId;
}

Future<bool> _maybeSendCopyAppIdRequest(OnCommandEvent onCommandEvent) async {
  final OnCommandEvent(:command, :tab) = onCommandEvent;
  if (command != 'copyAppId') return false;
  final tabId = (tab ?? await activeTab)?.id;
  if (tabId == null) return false;
  final debugInfo = await _fetchDebugInfo(tabId);
  final workspaceName = debugInfo?.workspaceName;
  if (workspaceName == null) return false;
  final appId = '$workspaceName-$tabId';
  return sendTabsMessage(
    tabId: tabId,
    type: MessageType.appId,
    body: appId,
    sender: Script.background,
    recipient: Script.copier,
  );
}

void _registerListeners() {
  chrome.runtime.onMessage.listen(
    _handleRuntimeMessages,
  );
  // The only extension allowed to send messages to this extension is the
  // AngularDart DevTools extension. Its permission is set in the manifest.json
  // externally_connectable field.
  chrome.runtime.onMessageExternal.listen(
    (handleMessagesFromAngularDartDevTools),
  );
  // The only external service that sends messages to the Dart Debug Extension
  // is Cider.
  chrome.runtime.onConnectExternal.listen((handleCiderConnectRequest));
  // Update the extension icon on tab navigation:
  chrome.tabs.onActivated
      .listen((OnActivatedActiveInfo info) => _updateIcon(info.tabId));
  chrome.windows.onFocusChanged.listen(_updateIcon);
  chrome.webNavigation.onCommitted.listen((_detectNavigationAwayFromDartApp));

  chrome.commands.onCommand.listen((_maybeSendCopyAppIdRequest));
}

void _setDebuggableIcon(int tabId) {
  setExtensionIcon(SetIconDetails(path: 'static_assets/dart.png'));
  setExtensionPopup(
    SetPopupDetails(popup: 'static_assets/popup.html', tabId: tabId),
  );
}

void _setDefaultIcon(int tabId) {
  final iconPath =
      isDevMode ? 'static_assets/dart_dev.png' : 'static_assets/dart_grey.png';
  setExtensionIcon(SetIconDetails(path: iconPath));
  setExtensionPopup(SetPopupDetails(popup: '', tabId: tabId));
}

void _setWarningIcon(int tabId) {
  setExtensionPopup(
    SetPopupDetails(popup: 'static_assets/popup.html', tabId: tabId),
  );
}

Future<void> _updateIcon(int activeTabId) async {
  final debugInfo = await _fetchDebugInfo(activeTabId);
  if (debugInfo == null) {
    _setDefaultIcon(activeTabId);
    return;
  }
  final multipleApps = await fetchStorageObject<String>(
    type: StorageObject.multipleAppsDetected,
    tabId: activeTabId,
  );
  multipleApps == null
      ? _setDebuggableIcon(activeTabId)
      : _setWarningIcon(activeTabId);
}
