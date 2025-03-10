// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn('vm')
@Timeout(Duration(minutes: 2))
import 'dart:async';

import 'package:test/test.dart';
import 'package:test_common/logging.dart';
import 'package:test_common/test_sdk_configuration.dart';
import 'package:vm_service/vm_service.dart';

import 'fixtures/context.dart';
import 'fixtures/project.dart';

void main() {
  final provider = TestSdkConfigurationProvider();
  tearDownAll(provider.dispose);

  final context = TestContext(TestProject.testWithSoundNullSafety, provider);

  setUpAll(() async {
    setCurrentLogWriter();
    await context.setUp();
  });

  tearDownAll(() async {
    await context.tearDown();
  });

  group('breakpoints', () {
    late VmServiceInterface service;
    VM vm;
    late Isolate isolate;
    ScriptList scripts;
    late ScriptRef mainScript;
    late Stream<Event> isolateEventStream;

    setUp(() async {
      setCurrentLogWriter();
      service = context.service;
      vm = await service.getVM();
      isolate = await service.getIsolate(vm.isolates!.first.id!);
      scripts = await service.getScripts(isolate.id!);
      mainScript = scripts.scripts!
          .firstWhere((each) => each.uri!.contains('main.dart'));
      isolateEventStream = service.onEvent('Isolate');
    });

    tearDown(() async {
      // Remove breakpoints so they don't impact other tests.
      for (var breakpoint in isolate.breakpoints!.toList()) {
        await service.removeBreakpoint(isolate.id!, breakpoint.id!);
      }
    });

    test('restore after refresh', () async {
      final firstBp =
          await service.addBreakpoint(isolate.id!, mainScript.id!, 23);
      expect(firstBp, isNotNull);
      expect(firstBp.id, isNotNull);

      final eventsDone = expectLater(
          isolateEventStream,
          emitsThrough(emitsInOrder([
            predicate((Event event) => event.kind == EventKind.kIsolateExit),
            predicate((Event event) => event.kind == EventKind.kIsolateStart),
            predicate(
                (Event event) => event.kind == EventKind.kIsolateRunnable),
          ])));

      await context.webDriver.refresh();
      await eventsDone;

      vm = await service.getVM();
      isolate = await service.getIsolate(vm.isolates!.first.id!);

      expect(isolate.breakpoints!.length, equals(1));
    }, timeout: const Timeout.factor(2));

    test('restore after hot restart', () async {
      final firstBp =
          await service.addBreakpoint(isolate.id!, mainScript.id!, 23);
      expect(firstBp, isNotNull);
      expect(firstBp.id, isNotNull);

      final eventsDone = expectLater(
          isolateEventStream,
          emits(emitsInOrder([
            predicate((Event event) => event.kind == EventKind.kIsolateExit),
            predicate((Event event) => event.kind == EventKind.kIsolateStart),
            predicate(
                (Event event) => event.kind == EventKind.kIsolateRunnable),
          ])));

      await context.debugConnection.vmService
          .callServiceExtension('hotRestart');
      await eventsDone;

      vm = await service.getVM();
      isolate = await service.getIsolate(vm.isolates!.first.id!);

      expect(isolate.breakpoints!.length, equals(1));
    }, timeout: const Timeout.factor(2));
  });
}
