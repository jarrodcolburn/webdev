// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// import 'dart:html';
// import 'dart:js_util' as js_util;

// import 'dart:convert' show Js;
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart';

export 'dart:convert';
export 'dart:js_interop';
export 'package:web/web.dart';
// import 'package:web/' as web;
// export 'package:web/web.dart' show fetch;

// import 'package:js/js.dart';

// @JS()
// ignore: non_constant_identifier_names
// external Json get JSON;

// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/JSON/stringify
mixin JSON {
  static String stringify(object) => jsonEncode(object);
}

// Custom implementation of Fetch API until the Dart implementation supports
// credentials. See https://github.com/dart-lang/http/issues/595.
typedef FetchResponse = Response;
typedef FetchOptions = RequestInit;

Future<FetchResponse> fetchRequest(String resourceUrl) async {
  final options = FetchOptions(method: 'GET', credentials: 'include');
  return window.fetch(resourceUrl.toJS, options).toDart;
}
