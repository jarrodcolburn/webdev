// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library utils;

import 'dart:async';

import 'chrome_api.dart';

Future<Tab> createTab(String url, {bool inNewWindow = false}) async {
  if (inNewWindow) {
    final windowObj =
        await chrome.windows.create(CreateData(focused: true, url: url));
    if (windowObj?.tabs?.first case final Tab tab) return tab;
  }
  return chrome.tabs.create(
    CreateProperties(
      active: true,
      url: url,
    ),
  );
}

Future<Tab?> getTab(int tabId) => chrome.tabs.get(tabId);

Future<Tab?> get activeTab async =>
    (await chrome.tabs.query(QueryInfo(active: true, currentWindow: true)))
        .first;

Future<bool> removeTab(int tabId) async {
  await chrome.tabs.remove(tabId);
  return true;
}

void displayNotification(
  String message, {
  bool isError = false,
  Function? callback,
}) async {
  await chrome.notifications.create(
    null,
    NotificationOptions(
      title: '${isError ? '[Error] ' : ''}Dart Debug Extension',
      message: message,
      iconUrl:
          isError ? 'static_assets/dart_warning.png' : 'static_assets/dart.png',
      type: TemplateType.basic,
    ),
  );
  callback?.call();
}

void setExtensionIcon(IconInfo info) => switch (isMV3) {
      true => _setExtensionIconMV3(info, null),
      false => _setExtensionIconMV2(info, null)
    };

void setExtensionPopup(PopupDetails details) => switch (isMV3) {
      true => _setExtensionPopupMV3(details, null),
      false => _setExtensionPopupMV2(details, null),
    };

bool? _isDevMode;

bool get isDevMode {
  if (_isDevMode != null) {
    return _isDevMode!;
  }
  final extensionManifest = chrome.runtime.getManifest();
  final extensionName = getProperty(extensionManifest, 'name') ?? '';
  final isDevMode = extensionName.contains('DEV');
  _isDevMode = isDevMode;
  return isDevMode;
}

bool? _isMV3;

bool get isMV3 {
  if (_isMV3 != null) {
    return _isMV3!;
  }
  final extensionManifest = chrome.runtime.getManifest();
  final manifestVersion =
      getProperty(extensionManifest, 'manifest_version') ?? 2;
  final isMV3 = manifestVersion == 3;
  _isMV3 = isMV3;
  return isMV3;
}

String addQueryParameters(
  String uri, {
  required Map<String, String> queryParameters,
}) {
  final originalUri = Uri.parse(uri);
  final newUri = originalUri.replace(
    path: '', // Replace the /debugger path so that the inspector url works.
    queryParameters: {
      ...originalUri.queryParameters,
      ...queryParameters,
    },
  );
  return newUri.toString();
}

@JS('chrome.browserAction.setIcon')
external void _setExtensionIconMV2(IconInfo iconInfo, Function? callback);

@JS('chrome.action.setIcon')
external void _setExtensionIconMV3(IconInfo iconInfo, Function? callback);

@JS('chrome.browserAction.setPopup')
external void _setExtensionPopupMV2(PopupDetails details, Function? callback);

@JS('chrome.action.setPopup')
external void _setExtensionPopupMV3(PopupDetails details, Function? callback);

@JS()
@anonymous
class IconInfo {
  external String get path;
  external factory IconInfo({required String path});
}

@JS()
@anonymous
class PopupDetails {
  external int get tabId;
  external String get popup;
  external factory PopupDetails({required int tabId, required String popup});
}
