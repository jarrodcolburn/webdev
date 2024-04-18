// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dwds/data/debug_info.dart';

import 'chrome_api.dart';
import 'logger.dart';
import 'storage.dart';
import 'utils.dart';

bool panelsExist = false;

Future<void> main() async {
  await _registerListeners();
  await _maybeCreatePanels();
}

Future<void> _registerListeners() async {
  chrome.storage.onChanged
      .listen((OnChangedEvent onChangedEvent) => _maybeCreatePanels());
}

Future<void> _maybeCreatePanels() async {
  if (panelsExist) return;
  final tabId = chrome.devtools.inspectedWindow.tabId;
  final debugInfo = await fetchStorageObject<DebugInfo>(
    type: StorageObject.debugInfo,
    tabId: tabId,
  );
  if (debugInfo case null) return;
  final isInternalBuild = debugInfo.isInternalBuild ?? false;
  if (!isInternalBuild) return;
  // Create a Debugger panel for all internal apps:
  final panel = await chrome.devtools.panels.create(
    isDevMode ? '[DEV] Dart Debugger' : 'Dart Debugger',
    '',
    'static_assets/debugger_panel.html',
  );
  _onPanelAdded(panel, debugInfo);
  // Create an inspector panel for internal Flutter apps:
  final isFlutterApp = debugInfo.isFlutterApp ?? false;
  if (isFlutterApp) {
    final panel = await chrome.devtools.panels.create(
        isDevMode ? '[DEV] Flutter Inspector' : 'Flutter Inspector',
        '',
        'static_assets/inspector_panel.html');
    _onPanelAdded(panel, debugInfo);
  }
  panelsExist = true;
}

void _onPanelAdded(ExtensionPanel panel, DebugInfo debugInfo) {
  panel.onShown.listen(
    ((window) {
      // FIXME is this JSObject window? or Chrome API window?
      if (window.origin != debugInfo.appOrigin) {
        debugWarn('Page at ${window.origin} is no longer a Dart app.');
        // TODO(elliette): Display banner that panel is not applicable. See:
        // https://stackoverflow.com/questions/18927147/how-to-close-destroy-chrome-devtools-extensionpanel-programmatically
      }
    }),
  );
}
