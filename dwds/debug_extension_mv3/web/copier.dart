// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library copier;

import 'dart:js_interop';
import 'package:web/web.dart' show window;

import 'chrome_api.dart';
import 'messaging.dart';

void main() {
  _registerListeners();
}

void _registerListeners() {
  chrome.runtime.onMessage.listen(
    (_handleRuntimeMessages),
  );
}

void _handleRuntimeMessages(
  OnMessageEvent onMessageEvent,
) {
  final OnMessageEvent(message: jsRequest, :sendResponse, :sender) =
      onMessageEvent;
  interceptMessage<String>(
    message: jsRequest.toString(),
    expectedType: MessageType.appId,
    expectedSender: Script.background,
    expectedRecipient: Script.copier,
    sender: sender,
    messageHandler: _copyAppId,
  );

  sendResponse.callAsFunction(defaultResponse);
}

void _copyAppId(String appId) {
  final clipboard = window.navigator.clipboard;
  if (clipboard == null) return;
  clipboard.writeText(appId);
  _notifyCopiedSuccess(appId);
}

Future<bool> _notifyCopiedSuccess(String appId) => sendRuntimeMessage(
      type: MessageType.appId,
      body: appId,
      sender: Script.copier,
      recipient: Script.background,
    );
