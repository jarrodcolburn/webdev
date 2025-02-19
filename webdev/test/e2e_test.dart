// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@Timeout(Duration(minutes: 5))
import 'dart:io';

import 'package:io/io.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;
import 'package:test_process/test_process.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:webdev/src/logging.dart';
import 'package:webdev/src/pubspec.dart';
import 'package:webdev/src/serve/utils.dart';
import 'package:webdev/src/util.dart';
import 'package:yaml/yaml.dart';

import 'daemon/utils.dart';
import 'test_utils.dart';

/// Key: name of file in web directory
/// Value: `null`  - exists in both modes
///        `true`  - DDC only
///        `false` - dart2js only
final _testItems = <String, bool?>{
  'main.dart.js': null,
  'main.dart.bootstrap.js': true,
  'main.ddc.js': true,
};

void main() {
  // Change to true for debugging.
  final debug = false;

  final testRunner = TestRunner();
  late String exampleDirectory;
  late String soundExampleDirectory;
  setUpAll(() async {
    configureLogWriter(debug);
    await testRunner.setUpAll();
    exampleDirectory =
        p.absolute(p.join(p.current, '..', 'fixtures', '_webdevSmoke'));
    soundExampleDirectory =
        p.absolute(p.join(p.current, '..', 'fixtures', '_webdevSoundSmoke'));

    var process = await TestProcess.start(dartPath, ['pub', 'upgrade'],
        workingDirectory: exampleDirectory, environment: getPubEnvironment());

    await process.shouldExit(0);

    process = await TestProcess.start(dartPath, ['pub', 'upgrade'],
        workingDirectory: soundExampleDirectory,
        environment: getPubEnvironment());

    await process.shouldExit(0);

    await d
        .file('.dart_tool/package_config.json', isNotEmpty)
        .validate(soundExampleDirectory);
    await d.file('pubspec.lock', isNotEmpty).validate(soundExampleDirectory);
  });

  tearDownAll(testRunner.tearDownAll);

  test('smoke test is configured properly', () async {
    var smokeYaml = loadYaml(
            await File('$soundExampleDirectory/pubspec.yaml').readAsString())
        as YamlMap;
    var webdevYaml =
        loadYaml(await File('pubspec.yaml').readAsString()) as YamlMap;
    expect(smokeYaml['environment']['sdk'],
        equals(webdevYaml['environment']['sdk']));
    expect(smokeYaml['dev_dependencies']['build_runner'],
        equals(buildRunnerConstraint.toString()));
    expect(smokeYaml['dev_dependencies']['build_web_compilers'],
        equals(buildWebCompilersConstraint.toString()));
  });

  test('build should fail if targeting an existing directory', () async {
    await d.file('simple thing', 'throw-away').create();

    var args = ['build', '-o', 'web:${d.sandbox}'];

    var process = await testRunner.runWebDev(args,
        workingDirectory: soundExampleDirectory);

    // NOTE: We'd like this to be more useful
    // See https://github.com/dart-lang/build/issues/1283

    await expectLater(
        process.stdout,
        emitsThrough(
            contains('Unable to create merged directory at ${d.sandbox}.')));
    await expectLater(
        process.stdout,
        emitsThrough(
            'Choose a different directory or delete the contents of that '
            'directory.'));

    await process.shouldExit(isNot(0));
  });

  test('build should allow passing extra arguments to build_runner', () async {
    var args = [
      'build',
      '-o',
      'web:${d.sandbox}',
      '--',
      '--delete-conflicting-outputs'
    ];

    var process = await testRunner.runWebDev(args,
        workingDirectory: soundExampleDirectory);

    await checkProcessStdout(process, ['Succeeded']);
    await process.shouldExit(0);
  });

  group('should build with valid configuration', () {
    for (var withDDC in [true, false]) {
      test(withDDC ? 'DDC' : 'dart2js', () async {
        var args = ['build', '-o', 'web:${d.sandbox}'];
        if (withDDC) {
          args.add('--no-release');
        }

        var process = await testRunner.runWebDev(args,
            workingDirectory: soundExampleDirectory);

        var expectedItems = <Object>['Succeeded'];

        await checkProcessStdout(process, expectedItems);
        await process.shouldExit(0);

        for (var entry in _testItems.entries) {
          var shouldExist = (entry.value ?? withDDC) == withDDC;

          if (shouldExist) {
            await d.file(entry.key, isNotEmpty).validate();
          } else {
            await d.nothing(entry.key).validate();
          }
        }
      });
    }
    test('and --null-safety=sound', () async {
      var args = [
        'build',
        '-o',
        'web:${d.sandbox}',
        '--no-release',
        '--null-safety=sound'
      ];

      var process = await testRunner.runWebDev(args,
          workingDirectory: soundExampleDirectory);

      var expectedItems = <Object>['Succeeded'];

      await checkProcessStdout(process, expectedItems);
      await process.shouldExit(0);

      await d.file('main.ddc.js', isNotEmpty).validate();
    });

    test('and --null-safety=unsound', () async {
      var args = [
        'build',
        '-o',
        'web:${d.sandbox}',
        '--no-release',
        '--null-safety=unsound'
      ];

      var process =
          await testRunner.runWebDev(args, workingDirectory: exampleDirectory);

      var expectedItems = <Object>['Succeeded'];

      await checkProcessStdout(process, expectedItems);
      await process.shouldExit(0);

      await d.file('main.unsound.ddc.js', isNotEmpty).validate();
    });
  });

  group('should build with --output=NONE', () {
    for (var withDDC in [true, false]) {
      test(withDDC ? 'DDC' : 'dart2js', () async {
        var args = ['build', '--output=NONE'];
        if (withDDC) {
          args.add('--no-release');
        }

        var process = await testRunner.runWebDev(args,
            workingDirectory: soundExampleDirectory);

        var expectedItems = <Object>['Succeeded'];

        await checkProcessStdout(process, expectedItems);
        await process.shouldExit(0);

        await d.nothing('build').validate(soundExampleDirectory);
      });
    }
  });

  group('should serve with valid configuration', () {
    for (var withDDC in [true, false]) {
      var type = withDDC ? 'DDC' : 'dart2js';
      test('using $type', () async {
        var openPort = await findUnusedPort();
        var args = ['serve', 'web:$openPort'];
        if (!withDDC) {
          args.add('--release');
        }

        var process = await testRunner.runWebDev(args,
            workingDirectory: soundExampleDirectory);

        var hostUrl = 'http://localhost:$openPort';

        // Wait for the initial build to finish.
        await expectLater(process.stdout, emitsThrough(contains('Succeeded')));

        var client = HttpClient();

        try {
          for (var entry in _testItems.entries) {
            var url = Uri.parse('$hostUrl/${entry.key}');

            var request = await client.getUrl(url);
            var response = await request.close();

            var shouldExist = (entry.value ?? withDDC) == withDDC;

            expect(response.statusCode, shouldExist ? 200 : 404,
                reason: 'Expecting "$url"? $shouldExist');
          }
        } finally {
          client.close(force: true);
        }

        await process.kill();
        await process.shouldExit();
      });
    }
  });

  group('Should fail with invalid build directories', () {
    var invalidServeDirs = ['.', '../', '../foo', 'foo/bar', 'foo/../'];
    for (var dir in invalidServeDirs) {
      for (var command in ['build', 'serve']) {
        test('cannot $command directory: `$dir`', () async {
          var args = [
            command,
            if (command == 'build') '--output=$dir:foo' else dir
          ];

          var process = await testRunner.runWebDev(args,
              workingDirectory: soundExampleDirectory);
          await expectLater(
              process.stdout,
              emitsThrough(contains(
                  'Invalid configuration: Only top level directories under the '
                  'package can be built')));
          await expectLater(process.exitCode, completion(ExitCode.config.code));
        });
      }
    }
  });

  group('should work with ', () {
    setUp(() async {
      configureLogWriter(debug);
    });

    for (var soundNullSafety in [false, true]) {
      var nullSafetyOption = soundNullSafety ? 'sound' : 'unsound';
      group('--null-safety=$nullSafetyOption', () {
        setUp(() async {
          configureLogWriter(debug);
        });
        group('and --enable-expression-evaluation:', () {
          setUp(() async {
            configureLogWriter(debug);
          });
          test('evaluateInFrame', () async {
            var openPort = await findUnusedPort();
            // running daemon command that starts dwds without keyboard input
            var args = [
              'daemon',
              'web:$openPort',
              '--enable-expression-evaluation',
              '--null-safety=$nullSafetyOption',
              '--verbose',
            ];
            var process = await testRunner.runWebDev(args,
                workingDirectory:
                    soundNullSafety ? soundExampleDirectory : exampleDirectory);
            VmService? vmService;

            process.stdoutStream().listen(Logger.root.fine);
            process.stderrStream().listen(Logger.root.warning);

            try {
              // Wait for debug service Uri
              String? wsUri;
              await expectLater(process.stdout, emitsThrough((message) {
                wsUri = getDebugServiceUri(message as String);
                return wsUri != null;
              }));
              Logger.root.fine('vm service uri: $wsUri');
              expect(wsUri, isNotNull);

              vmService = await vmServiceConnectUri(wsUri!);
              var vm = await vmService.getVM();
              var isolateId = vm.isolates!.first.id!;
              var scripts = await vmService.getScripts(isolateId);

              await vmService.streamListen('Debug');
              var stream = vmService.onEvent('Debug');

              var mainScript = scripts.scripts!
                  .firstWhere((each) => each.uri!.contains('main.dart'));

              var bpLine = await findBreakpointLine(
                  vmService, 'printCounter', isolateId, mainScript);

              var bp = await vmService.addBreakpointWithScriptUri(
                  isolateId, mainScript.uri!, bpLine);
              expect(bp, isNotNull);

              await stream.firstWhere(
                  (Event event) => event.kind == EventKind.kPauseBreakpoint);

              final isNullSafetyEnabled =
                  '() { const sound = !(<Null>[] is List<int>); return sound; } ()';
              final result = await vmService.evaluateInFrame(
                  isolateId, 0, isNullSafetyEnabled);

              expect(
                  result,
                  const TypeMatcher<InstanceRef>().having(
                      (instance) => instance.valueAsString,
                      'valueAsString',
                      '$soundNullSafety'));
            } finally {
              await vmService?.dispose();
              await exitWebdev(process);
              await process.shouldExit();
            }
          }, timeout: const Timeout.factor(2));

          test('evaluate', () async {
            var openPort = await findUnusedPort();
            // running daemon command that starts dwds without keyboard input
            var args = [
              'daemon',
              'web:$openPort',
              '--enable-expression-evaluation',
              '--verbose',
            ];
            var process = await testRunner.runWebDev(args,
                workingDirectory:
                    soundNullSafety ? soundExampleDirectory : exampleDirectory);
            VmService? vmService;

            try {
              // Wait for debug service Uri
              String? wsUri;
              await expectLater(process.stdout, emitsThrough((message) {
                wsUri = getDebugServiceUri(message as String);
                return wsUri != null;
              }));
              expect(wsUri, isNotNull);

              vmService = await vmServiceConnectUri(wsUri!);
              var vm = await vmService.getVM();
              var isolateId = vm.isolates!.first.id!;
              var isolate = await vmService.getIsolate(isolateId);
              var libraryId = isolate.rootLib!.id!;

              await vmService.streamListen('Debug');

              var result = await vmService.evaluate(isolateId, libraryId,
                  '(document?.body?.children?.first as SpanElement)?.text');

              expect(
                  result,
                  const TypeMatcher<InstanceRef>().having(
                      (instance) => instance.valueAsString,
                      'valueAsString',
                      'Hello World!!'));

              result = await vmService.evaluate(
                  isolateId, libraryId, 'main.toString()');

              expect(
                  result,
                  const TypeMatcher<InstanceRef>().having(
                      (instance) => instance.valueAsString,
                      'valueAsString',
                      contains('Hello World!!')));
            } finally {
              await vmService?.dispose();
              await exitWebdev(process);
              await process.shouldExit();
            }
          }, timeout: const Timeout.factor(2));
        });

        group('and --no-enable-expression-evaluation:', () {
          test('evaluateInFrame', () async {
            var openPort = await findUnusedPort();
            var args = [
              'daemon',
              'web:$openPort',
              '--no-enable-expression-evaluation',
              '--verbose',
            ];
            var process = await testRunner.runWebDev(args,
                workingDirectory:
                    soundNullSafety ? soundExampleDirectory : exampleDirectory);
            VmService? vmService;

            try {
              // Wait for debug service Uri
              String? wsUri;
              await expectLater(process.stdout, emitsThrough((message) {
                wsUri = getDebugServiceUri(message as String);
                return wsUri != null;
              }));
              expect(wsUri, isNotNull);

              vmService = await vmServiceConnectUri(wsUri!);
              var vm = await vmService.getVM();
              var isolateId = vm.isolates!.first.id!;
              var scripts = await vmService.getScripts(isolateId);

              await vmService.streamListen('Debug');
              var stream = vmService.onEvent('Debug');

              var mainScript = scripts.scripts!
                  .firstWhere((each) => each.uri!.contains('main.dart'));

              var bpLine = await findBreakpointLine(
                  vmService, 'printCounter', isolateId, mainScript);

              var bp = await vmService.addBreakpointWithScriptUri(
                  isolateId, mainScript.uri!, bpLine);
              expect(bp, isNotNull);

              var event = await stream.firstWhere(
                  (Event event) => event.kind == EventKind.kPauseBreakpoint);

              expect(
                  () => vmService!.evaluateInFrame(
                      isolateId, event.topFrame!.index!, 'true'),
                  throwsRPCError);
            } finally {
              await vmService?.dispose();
              await exitWebdev(process);
              await process.shouldExit();
            }
          });

          test('evaluate', () async {
            var openPort = await findUnusedPort();
            // running daemon command that starts dwds without keyboard input
            var args = [
              'daemon',
              'web:$openPort',
              '--no-enable-expression-evaluation',
              '--verbose',
            ];
            var process = await testRunner.runWebDev(args,
                workingDirectory:
                    soundNullSafety ? soundExampleDirectory : exampleDirectory);
            VmService? vmService;

            try {
              // Wait for debug service Uri
              String? wsUri;
              await expectLater(process.stdout, emitsThrough((message) {
                wsUri = getDebugServiceUri(message as String);
                return wsUri != null;
              }));
              expect(wsUri, isNotNull);

              vmService = await vmServiceConnectUri(wsUri!);
              var vm = await vmService.getVM();
              var isolateId = vm.isolates!.first.id!;
              var isolate = await vmService.getIsolate(isolateId);
              var libraryId = isolate.rootLib!.id!;

              await vmService.streamListen('Debug');

              expect(
                  () => vmService!
                      .evaluate(isolateId, libraryId, 'main.toString()'),
                  throwsRPCError);
            } finally {
              await vmService?.dispose();
              await exitWebdev(process);
              await process.shouldExit();
            }
          }, timeout: const Timeout.factor(2));
        });
      });
    }
  });
}
