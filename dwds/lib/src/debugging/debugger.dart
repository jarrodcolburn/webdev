// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:dwds/src/debugging/dart_scope.dart';
import 'package:dwds/src/debugging/frame_computer.dart';
import 'package:dwds/src/debugging/location.dart';
import 'package:dwds/src/debugging/metadata/class.dart';
import 'package:dwds/src/debugging/remote_debugger.dart';
import 'package:dwds/src/debugging/skip_list.dart';
import 'package:dwds/src/loaders/strategy.dart';
import 'package:dwds/src/services/chrome_debug_exception.dart';
import 'package:dwds/src/utilities/conversions.dart';
import 'package:dwds/src/utilities/dart_uri.dart';
import 'package:dwds/src/utilities/domain.dart';
import 'package:dwds/src/utilities/objects.dart' show Property;
import 'package:dwds/src/utilities/server.dart';
import 'package:dwds/src/utilities/shared.dart';
import 'package:dwds/src/utilities/synchronized.dart';
import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart';
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart'
    hide StackTrace;

/// Adds [event] to the stream with [streamId] if there is anybody listening
/// on that stream.
typedef StreamNotify = void Function(String streamId, Event event);

/// Converts from ExceptionPauseMode strings to [PauseState] enums.
///
/// Values defined in:
/// https://chromedevtools.github.io/devtools-protocol/tot/Debugger#method-setPauseOnExceptions
const _pauseModePauseStates = {
  'none': PauseState.none,
  'all': PauseState.all,
  'unhandled': PauseState.uncaught,
};

class Debugger extends Domain {
  static final logger = Logger('Debugger');

  final RemoteDebugger _remoteDebugger;

  final StreamNotify _streamNotify;
  final Locations _locations;
  final SkipLists _skipLists;
  final String _root;

  Debugger._(
    this._remoteDebugger,
    this._streamNotify,
    this._locations,
    this._skipLists,
    this._root,
  ) : _breakpoints = _Breakpoints(
            locations: _locations,
            remoteDebugger: _remoteDebugger,
            root: _root);

  /// The breakpoints we have set so far, indexable by either
  /// Dart or JS ID.
  final _Breakpoints _breakpoints;

  PauseState _pauseState = PauseState.none;

  // TODO(elliette): https://github.com/dart-lang/webdev/issues/1501 Re-enable
  // after checking with Chrome team if there is a way to check if the Chrome
  // DevTools is showing an overlay. Both cannot be shown at the same time:
  // bool _pausedOverlayVisible = false;

  String get pauseState => _pauseModePauseStates.entries
      .firstWhere((entry) => entry.value == _pauseState)
      .key;

  /// The JS frames at the current paused location.
  ///
  /// The most important thing here is that frames are identified by
  /// frameIndex in the Dart API, but by frame Id in Chrome, so we need
  /// to keep the JS frames and their Ids around.
  FrameComputer? stackComputer;

  bool _isStepping = false;

  void updateInspector(AppInspectorInterface appInspector) {
    inspector = appInspector;
    _breakpoints.inspector = appInspector;
  }

  Future<Success> pause() async {
    _isStepping = false;
    final result = await _remoteDebugger.pause();
    handleErrorIfPresent(result);
    return Success();
  }

  Future<Success> setExceptionPauseMode(String mode) async {
    mode = mode.toLowerCase();
    final state = _pauseModePauseStates[mode];
    if (state == null) {
      throwInvalidParam('setExceptionPauseMode', 'Unsupported mode: $mode');
    } else {
      _pauseState = state;
    }
    await _remoteDebugger.setPauseOnExceptions(_pauseState);
    return Success();
  }

  /// Resumes the debugger.
  ///
  /// Step parameter options:
  /// https://github.com/dart-lang/sdk/blob/main/runtime/vm/service/service.md#resume
  ///
  /// If the step parameter is not provided, the program will resume regular
  /// execution.
  ///
  /// If the step parameter is provided, it indicates what form of
  /// single-stepping to use.
  ///
  /// Note that stepping will automatically continue until Chrome is paused at
  /// a location for which we have source information.
  Future<Success> resume({String? step, int? frameIndex}) async {
    if (frameIndex != null) {
      throw ArgumentError('FrameIndex is currently unsupported.');
    }
    WipResponse? result;
    if (step != null) {
      _isStepping = true;
      switch (step) {
        case 'Over':
          result = await _remoteDebugger.stepOver();
          break;
        case 'Out':
          result = await _remoteDebugger.stepOut();
          break;
        case 'Into':
          result = await _remoteDebugger.stepInto();
          break;
        default:
          throwInvalidParam('resume', 'Unexpected value for step: $step');
      }
    } else {
      _isStepping = false;
      result = await _remoteDebugger.resume();
    }
    handleErrorIfPresent(result);
    return Success();
  }

  /// Returns the current Dart stack for the paused debugger.
  ///
  /// Throws RPCError if the debugger is not paused.
  ///
  /// The returned stack will contain up to [limit] frames if provided.
  Future<Stack> getStack({int? limit}) async {
    if (stackComputer == null) {
      throw RPCError('getStack', RPCError.kInternalError,
          'Cannot compute stack when application is not paused');
    }

    final frames = await stackComputer!.calculateFrames(limit: limit);
    return Stack(
        frames: frames,
        messages: [],
        truncated: limit != null && frames.length == limit);
  }

  static Future<Debugger> create(
    RemoteDebugger remoteDebugger,
    StreamNotify streamNotify,
    Locations locations,
    SkipLists skipLists,
    String root,
  ) async {
    final debugger = Debugger._(
      remoteDebugger,
      streamNotify,
      locations,
      skipLists,
      root,
    );
    await debugger._initialize();
    return debugger;
  }

  Future<void> _initialize() async {
    // We must add a listener before enabling the debugger otherwise we will
    // miss events.
    // Allow a null debugger/connection for unit tests.
    runZonedGuarded(() {
      _remoteDebugger.onPaused.listen(_pauseHandler);
      _remoteDebugger.onResumed.listen(_resumeHandler);
      _remoteDebugger.onTargetCrashed.listen(_crashHandler);
    }, (e, StackTrace s) {
      logger.warning('Error handling Chrome event', e, s);
    });

    handleErrorIfPresent(await _remoteDebugger.enablePage());
    await _remoteDebugger.enable();

    // Enable collecting information about async frames when paused.
    handleErrorIfPresent(await _remoteDebugger
        .sendCommand('Debugger.setAsyncCallStackDepth', params: {
      'maxDepth': 128,
    }));
  }

  /// Resumes the Isolate from start.
  ///
  /// The JS VM is technically not paused at the start of the Isolate so there
  /// will not be a corresponding [DebuggerResumedEvent].
  Future<void> resumeFromStart() => _resumeHandler(null);

  /// Notify the debugger the [Isolate] is paused at the application start.
  void notifyPausedAtStart() {
    stackComputer = FrameComputer(this, []);
  }

  /// Add a breakpoint at the given position.
  ///
  /// Note that line and column are Dart source locations and are one-based.
  Future<Breakpoint> addBreakpoint(
    String scriptId,
    int line, {
    int? column,
  }) async {
    column ??= 0;
    final breakpoint = await _breakpoints.add(scriptId, line, column);
    _notifyBreakpoint(breakpoint);
    return breakpoint;
  }

  Future<ScriptRef?> _updatedScriptRefFor(Breakpoint breakpoint) async {
    final oldRef = (breakpoint.location as SourceLocation).script;
    final uri = oldRef?.uri;
    if (uri == null) return null;
    final dartUri = DartUri(uri, _root);
    return await inspector.scriptRefFor(dartUri.serverPath);
  }

  Future<void> reestablishBreakpoints(
    Set<Breakpoint> previousBreakpoints,
    Set<Breakpoint> disabledBreakpoints,
  ) async {
    // Previous breakpoints were never removed from Chrome since we use
    // `setBreakpointByUrl`. We simply need to update the references.
    for (var breakpoint in previousBreakpoints) {
      final dartBpId = breakpoint.id!;
      final scriptRef = await _updatedScriptRefFor(breakpoint);
      final scriptUri = scriptRef?.uri;
      if (scriptRef != null && scriptUri != null) {
        final jsBpId = _breakpoints.jsIdFor(dartBpId)!;
        final updatedLocation = await _locations.locationForDart(
            DartUri(scriptUri, _root),
            _lineNumberFor(breakpoint),
            _columnNumberFor(breakpoint));
        if (updatedLocation != null) {
          final updatedBreakpoint = _breakpoints._dartBreakpoint(
              scriptRef, updatedLocation, dartBpId);
          _breakpoints._note(bp: updatedBreakpoint, jsId: jsBpId);
          _notifyBreakpoint(updatedBreakpoint);
        } else {
          logger.warning('Cannot update breakpoint $dartBpId:'
              ' cannot update location.');
        }
      } else {
        logger.warning('Cannot update breakpoint $dartBpId:'
            ' cannot find script ref.');
      }
    }

    // Disabled breakpoints were actually removed from Chrome so simply add
    // them back.
    for (var breakpoint in disabledBreakpoints) {
      final scriptRef = await _updatedScriptRefFor(breakpoint);
      final scriptId = scriptRef?.id;
      if (scriptId != null) {
        await addBreakpoint(scriptId, _lineNumberFor(breakpoint),
            column: _columnNumberFor(breakpoint));
      } else {
        logger.warning('Cannot update disabled breakpoint ${breakpoint.id}:'
            ' cannot find script ref.');
      }
    }
  }

  void _notifyBreakpoint(Breakpoint breakpoint) {
    final event = Event(
      kind: EventKind.kBreakpointAdded,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isolate: inspector.isolateRef,
    );
    event.breakpoint = breakpoint;
    _streamNotify('Debug', event);
  }

  /// Remove a Dart breakpoint.
  Future<Success> removeBreakpoint(String breakpointId) async {
    if (_breakpoints.breakpointFor(breakpointId) == null) {
      throwInvalidParam(
          'removeBreakpoint', 'invalid breakpoint id $breakpointId');
    }
    final jsId = _breakpoints.jsIdFor(breakpointId);
    if (jsId == null) {
      throw RPCError('removeBreakpoint', RPCError.kInternalError,
          'invalid JS breakpoint id $jsId');
    }
    await _removeBreakpoint(jsId);

    final bp = await _breakpoints.remove(jsId: jsId, dartId: breakpointId);
    if (bp != null) {
      _streamNotify(
        'Debug',
        Event(
            kind: EventKind.kBreakpointRemoved,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            isolate: inspector.isolateRef)
          ..breakpoint = bp,
      );
    }
    return Success();
  }

  /// Call the Chrome protocol removeBreakpoint.
  Future<void> _removeBreakpoint(String breakpointId) async {
    try {
      final response = await _remoteDebugger.removeBreakpoint(breakpointId);
      handleErrorIfPresent(response);
    } on WipError catch (e) {
      throw RPCError('removeBreakpoint', 102, '$e');
    }
  }

  /// Returns Chrome script uri for Chrome script ID.
  String? urlForScriptId(String scriptId) =>
      _remoteDebugger.scripts[scriptId]?.url;

  /// Returns source [Location] for the paused event.
  ///
  /// If we do not have [Location] data for the embedded JS location, null is
  /// returned.
  Future<Location?> _sourceLocation(DebuggerPausedEvent e) async {
    final frame = e.params?['callFrames']?[0];
    final location = frame?['location'];
    if (location == null) return null;

    final scriptId = location['scriptId'] as String?;
    final line = location['lineNumber'] as int?;
    if (scriptId == null || line == null) return null;

    final column = location['columnNumber'] as int?;
    final url = urlForScriptId(scriptId);
    if (url == null) return null;

    return _locations.locationForJs(url, line, column);
  }

  /// Returns script ID for the paused event.
  String? _frameScriptId(DebuggerPausedEvent e) {
    final frame = e.params?['callFrames']?[0];
    return frame?['location']?['scriptId'] as String?;
  }

  /// The variables visible in a frame in Dart protocol [BoundVariable] form.
  Future<List<BoundVariable>> variablesFor(WipCallFrame frame) async {
    // TODO(alanknight): Can these be moved to dart_scope.dart?
    final properties = await visibleProperties(debugger: this, frame: frame);
    final boundVariables = await Future.wait(
      properties.map(_boundVariable),
    );

    // Filter out variables that do not come from dart code, such as native
    // JavaScript objects
    return boundVariables
        .where((bv) => isDisplayableObject(bv?.value))
        .toList()
        .cast();
  }

  Future<BoundVariable?> _boundVariable(Property property) async {
    // TODO(annagrin): value might be null in the future for variables
    // optimized by V8. Return appropriate sentinel values for them.
    if (property.value != null) {
      final value = property.value!;
      // We return one level of properties from this object. Sub-properties are
      // another round trip.
      final instanceRef = await inspector.instanceRefFor(value);
      // Skip null instance refs, which we get for weird objects, e.g.
      // properties that are getter/setter pairs.
      // TODO(alanknight): Handle these properly.
      if (instanceRef == null) return null;

      return BoundVariable(
        name: property.name,
        value: instanceRef,
        // TODO(grouma) - Provide actual token positions.
        declarationTokenPos: -1,
        scopeStartTokenPos: -1,
        scopeEndTokenPos: -1,
      );
    }
    return null;
  }

  static bool _isEmptyRange({
    required int length,
    int? offset,
    int? count,
  }) {
    if (count == 0) return true;
    if (offset == null) return false;
    return offset >= length;
  }

  static bool _isSubRange({
    required int length,
    int? offset,
    int? count,
  }) {
    if (offset == 0 && count == null) return false;
    return offset != null || count != null;
  }

  /// Compute the last possible element index in the range of [offset]..end
  /// that includes [count] elements, if available.
  static int? _calculateRangeEnd(
          {int? count, required int offset, required int length}) =>
      count == null ? null : math.min(offset + count, length);

  /// Calculate the number of available elements in the range.
  static int _calculateRangeCount(
          {int? count, required int offset, required int length}) =>
      count == null ? length - offset : math.min(count, length - offset);

  /// Find a sub-range of the entries for a Map/List when offset and/or count
  /// have been specified on a getObject request.
  ///
  /// If the object referenced by [id] is not a system List or Map then this
  /// will just return a RemoteObject for it and ignore [offset], [count] and
  /// [length]. If it is, then [length] should be the number of entries in the
  /// List/Map and [offset] and [count] should indicate the desired range.
  Future<RemoteObject> _subRange(String id,
      {required int offset, int? count, required int length}) async {
    // TODO(#809): Sometimes we already know the type of the object, and
    // we could take advantage of that to short-circuit.
    final receiver = remoteObjectFor(id);
    final end =
        _calculateRangeEnd(count: count, offset: offset, length: length);
    final rangeCount =
        _calculateRangeCount(count: count, offset: offset, length: length);
    final args =
        [offset, rangeCount, end].map(dartIdFor).map(remoteObjectFor).toList();
    // If this is a List, just call sublist. If it's a Map, get the entries, but
    // avoid doing a toList on a large map using skip/take to get the section we
    // want. To make those alternatives easier in JS, pass both count and end.
    final expression = '''
        function (offset, count, end) {
          const sdk = ${globalLoadStrategy.loadModuleSnippet}("dart_sdk");
          if (sdk.core.Map.is(this)) {
            const entries = sdk.dart.dload(this, "entries");
            const skipped = sdk.dart.dsend(entries, "skip", [offset])
            const taken = sdk.dart.dsend(skipped, "take", [count]);
            return sdk.dart.dsend(taken, "toList", []);
          } else  if (sdk.core.List.is(this)) {
            return sdk.dart.dsendRepl(this, "sublist", [offset, end]);
          } else {
            return this;
          }
        }
        ''';
    return await inspector.jsCallFunctionOn(receiver, expression, args);
  }

  // TODO(elliette): https://github.com/dart-lang/webdev/issues/1501 Re-enable
  // after checking with Chrome team if there is a way to check if the Chrome
  // DevTools is showing an overlay. Both cannot be shown at the same time:

  // Renders the paused at breakpoint overlay over the application.
  // void _showPausedOverlay() async {
  //   if (_pausedOverlayVisible) return;
  //   handleErrorIfPresent(await _remoteDebugger?.sendCommand('DOM.enable'));
  //   handleErrorIfPresent(await _remoteDebugger?.sendCommand('Overlay.enable'));
  //   handleErrorIfPresent(await _remoteDebugger
  //       ?.sendCommand('Overlay.setPausedInDebuggerMessage', params: {
  //     'message': 'Paused',
  //   }));
  //   _pausedOverlayVisible = true;
  // }

  // Removes the paused at breakpoint overlay from the application.
  // void _hidePausedOverlay() async {
  //   if (!_pausedOverlayVisible) return;
  //   handleErrorIfPresent(await _remoteDebugger?.sendCommand('Overlay.disable'));
  //   _pausedOverlayVisible = false;
  // }

  /// Calls the Chrome Runtime.getProperties API for the object with [objectId].
  ///
  /// Note that the property names are JS names, e.g.
  /// Symbol(DartClass.actualName) and will need to be converted. For a system
  /// List or Map, [offset] and/or [count] can be provided to indicate a desired
  /// range of entries. They will be ignored if there is no [length].
  Future<List<Property>> getProperties(
    String objectId, {
    int? offset,
    int? count,
    int? length,
  }) async {
    String rangeId = objectId;
    // Ignore offset/count if there is no length:
    if (length != null) {
      if (_isEmptyRange(offset: offset, count: count, length: length)) {
        return [];
      }
      if (_isSubRange(offset: offset, count: count, length: length)) {
        final range = await _subRange(objectId,
            offset: offset ?? 0, count: count, length: length);
        rangeId = range.objectId ?? rangeId;
      }
    }
    final jsProperties = await sendCommandAndValidateResult<List>(
      _remoteDebugger,
      method: 'Runtime.getProperties',
      resultField: 'result',
      params: {
        'objectId': rangeId,
        'ownProperties': true,
      },
    );
    return jsProperties
        .map<Property>((each) => Property(each as Map<String, dynamic>))
        .toList();
  }

  /// Returns a Dart [Frame] for a JS [frame].
  Future<Frame?> calculateDartFrameFor(
    WipCallFrame frame,
    int frameIndex, {
    bool populateVariables = true,
  }) async {
    final location = frame.location;
    final line = location.lineNumber;
    final column = location.columnNumber;

    final url = urlForScriptId(location.scriptId);
    if (url == null) {
      logger.fine('Failed to create dart frame for ${frame.functionName}: '
          'cannot find url for script ${location.scriptId}');
      return null;
    }

    final bestLocation = await _locations.locationForJs(url, line, column ?? 0);
    if (bestLocation == null) return null;

    final script =
        await inspector.scriptRefFor(bestLocation.dartLocation.uri.serverPath);
    // We think we found a location, but for some reason we can't find the
    // script. Just drop the frame.
    // TODO(#700): Understand when this can happen and have a better fix.
    if (script == null) return null;

    final functionName = _prettifyMember((frame.functionName).split('.').last);
    final codeRefName = functionName.isEmpty ? '<closure>' : functionName;

    final dartFrame = Frame(
      index: frameIndex,
      code: CodeRef(
        name: codeRefName,
        kind: CodeKind.kDart,
        id: createId(),
      ),
      location: SourceLocation(
          line: bestLocation.dartLocation.line,
          column: bestLocation.dartLocation.column,
          tokenPos: bestLocation.tokenPos,
          script: script),
      kind: FrameKind.kRegular,
    );

    // Don't populate variables for async frames.
    if (populateVariables) {
      dartFrame.vars = await variablesFor(frame);
    }

    return dartFrame;
  }

  /// Handles pause events coming from the Chrome connection.
  Future<void> _pauseHandler(DebuggerPausedEvent e) async {
    final isolate = inspector.isolate;
    Event event;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final jsBreakpointIds = e.hitBreakpoints ?? [];
    if (jsBreakpointIds.isNotEmpty) {
      final breakpointIds = jsBreakpointIds
          .map((id) => _breakpoints._dartIdByJsId[id])
          // In case the breakpoint was set in Chrome DevTools outside of
          // package:dwds.
          .where((entry) => entry != null)
          .toSet();
      final pauseBreakpoints = isolate.breakpoints
          ?.where((bp) => breakpointIds.contains(bp.id))
          .toList();
      event = Event(
          kind: EventKind.kPauseBreakpoint,
          timestamp: timestamp,
          isolate: inspector.isolateRef)
        ..pauseBreakpoints = pauseBreakpoints;
    } else if (e.reason == 'exception' || e.reason == 'assert') {
      InstanceRef? exception;

      if (e.data is Map<String, dynamic>) {
        final map = e.data as Map<String, dynamic>;
        if (map['type'] == 'object') {
          final obj = RemoteObject(map);
          exception = await inspector.instanceRefFor(obj);
          if (exception != null && isNativeJsError(exception)) {
            if (obj.description != null) {
              // Create a string exception object.
              final description =
                  await inspector.mapExceptionStackTrace(obj.description!);
              exception = await inspector.instanceRefFor(description);
            } else {
              exception = null;
            }
          }
        }
      }

      event = Event(
        kind: EventKind.kPauseException,
        timestamp: timestamp,
        isolate: inspector.isolateRef,
        exception: exception,
      );
    } else {
      // Continue stepping until we hit a dart location,
      // avoiding stepping through library loading code.
      if (_isStepping) {
        final scriptId = _frameScriptId(e);
        if (scriptId == null) {
          logger.severe('Stepping failed: '
              'cannot find script id for event $e');
          throw StateError('Stepping failed on event $e');
        }
        final url = urlForScriptId(scriptId);
        if (url == null) {
          logger.severe('Stepping failed: '
              'cannot find url for script $scriptId');
          throw StateError('Stepping failed in script $scriptId');
        }

        if (url.contains(globalLoadStrategy.loadLibrariesModule)) {
          await _remoteDebugger.stepOut();
          return;
        } else if ((await _sourceLocation(e)) == null) {
          // TODO(grouma) - In the future we should send all previously computed
          // skipLists.
          await _remoteDebugger.stepInto(params: {
            'skipList': _skipLists.compute(
              scriptId,
              await _locations.locationsForUrl(url),
            )
          });
          return;
        }
      }
      event = Event(
          kind: EventKind.kPauseInterrupted,
          timestamp: timestamp,
          isolate: inspector.isolateRef);
    }

    // Calculate the frames (and handle any exceptions that may occur).
    stackComputer = FrameComputer(
      this,
      e.getCallFrames().toList(),
      asyncStackTrace: e.asyncStackTrace,
    );

    try {
      final frames = await stackComputer!.calculateFrames(limit: 1);
      event.topFrame = frames.isNotEmpty ? frames.first : null;
    } catch (e, s) {
      // TODO: Return information about the error to the user.
      logger.warning('Error calculating Dart frames', e, s);
    }

    // TODO(elliette): https://github.com/dart-lang/webdev/issues/1501 Re-enable
    // after checking with Chrome team if there is a way to check if the Chrome
    // DevTools is showing an overlay. Both cannot be shown at the same time.
    // _showPausedOverlay();
    isolate.pauseEvent = event;
    _streamNotify('Debug', event);
  }

  /// Handles resume events coming from the Chrome connection.
  Future<void> _resumeHandler(DebuggerResumedEvent? _) async {
    // We can receive a resume event in the middle of a reload which will result
    // in a null isolate.
    final isolate = inspector.isolate;

    stackComputer = null;
    final event = Event(
        kind: EventKind.kResume,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isolate: inspector.isolateRef);

    // TODO(elliette): https://github.com/dart-lang/webdev/issues/1501 Re-enable
    // after checking with Chrome team if there is a way to check if the Chrome
    // DevTools is showing an overlay. Both cannot be shown at the same time.
    // _hidePausedOverlay();
    isolate.pauseEvent = event;
    _streamNotify('Debug', event);
  }

  /// Handles targetCrashed events coming from the Chrome connection.
  Future<void> _crashHandler(TargetCrashedEvent _) async {
    // We can receive a resume event in the middle of a reload which will result
    // in a null isolate.
    final isolate = inspector.isolate;

    stackComputer = null;
    final event = Event(
        kind: EventKind.kIsolateExit,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isolate: inspector.isolateRef);
    isolate.pauseEvent = event;
    _streamNotify('Isolate', event);
    logger.severe('Target crashed!');
  }

  WipCallFrame? jsFrameForIndex(int frameIndex) {
    final computer = stackComputer;
    if (computer == null) {
      throw RPCError('evaluateInFrame', 106,
          'Cannot evaluate on a call frame when the program is not paused');
    }
    return computer.jsFrameForIndex(frameIndex);
  }

  /// Evaluate [expression] by calling Chrome's Runtime.evaluateOnCallFrame on
  /// the call frame with index [frameIndex] in the currently saved stack.
  ///
  /// If the program is not paused, so there is no current stack, throws a
  /// [StateError].
  Future<RemoteObject> evaluateJsOnCallFrameIndex(
      int frameIndex, String expression) {
    final index = jsFrameForIndex(frameIndex)?.callFrameId;
    if (index == null) {
      // This might happen on async frames.
      throw StateError('No frame for frame index: $index');
    }
    return evaluateJsOnCallFrame(index, expression);
  }

  /// Evaluate [expression] by calling Chrome's Runtime.evaluateOnCallFrame on
  /// the call frame with id [callFrameId].
  Future<RemoteObject> evaluateJsOnCallFrame(
      String callFrameId, String expression) async {
    // TODO(alanknight): Support a version with arguments if needed.
    try {
      return await _remoteDebugger.evaluateOnCallFrame(callFrameId, expression);
    } on ExceptionDetails catch (e) {
      throw ChromeDebugException(
        e.json,
        evalContents: expression,
      );
    }
  }
}

Future<T> sendCommandAndValidateResult<T>(
  RemoteDebugger remoteDebugger, {
  required String method,
  required String resultField,
  Map<String, dynamic>? params,
}) async {
  final response = await remoteDebugger.sendCommand(method, params: params);
  final result = response.result?[resultField];
  if (result == null) {
    throw RPCError(method, RPCError.kInternalError,
        '$resultField not found in result from sendCommand', params);
  }
  return result;
}

/// Returns true for objects we display for the user.
bool isDisplayableObject(Object? object) =>
    object is Sentinel ||
    object is InstanceRef &&
        !isNativeJsObject(object) &&
        !isNativeJsError(object);

/// Returns true for non-dart JavaScript objects.
bool isNativeJsObject(InstanceRef instanceRef) {
  return isNativeJsObjectRef(instanceRef.classRef);
}

/// Returns true of JavaScript exceptions.
bool isNativeJsError(InstanceRef instanceRef) {
  return instanceRef.classRef == classRefForNativeJsError;
}

/// Returns the Dart line number for the provided breakpoint.
int _lineNumberFor(Breakpoint breakpoint) =>
    int.parse(breakpoint.id!.split('#').last.split(':').first);

/// Returns the Dart column number for the provided breakpoint.
int _columnNumberFor(Breakpoint breakpoint) =>
    int.parse(breakpoint.id!.split('#').last.split(':').last);

/// Returns the breakpoint ID for the provided Dart script ID and Dart line
/// number.
String breakpointIdFor(String scriptId, int line, int column) =>
    'bp/$scriptId#$line:$column';

/// Keeps track of the Dart and JS breakpoint Ids that correspond.
class _Breakpoints extends Domain {
  final _logger = Logger('Breakpoints');
  final _dartIdByJsId = <String, String>{};
  final _jsIdByDartId = <String, String>{};

  final _bpByDartId = <String, Future<Breakpoint>>{};

  final _queue = AtomicQueue();

  final Locations locations;
  final RemoteDebugger remoteDebugger;

  /// The root URI from which the application is served.
  final String root;

  _Breakpoints({
    required this.locations,
    required this.remoteDebugger,
    required this.root,
  });

  Future<Breakpoint> _createBreakpoint(
      String id, String scriptId, int line, int column) async {
    final dartScript = inspector.scriptWithId(scriptId);
    final dartScriptUri = dartScript?.uri;
    Location? location;
    if (dartScriptUri != null) {
      final dartUri = DartUri(dartScriptUri, root);
      location = await locations.locationForDart(dartUri, line, column);
    }
    // TODO: Handle cases where a breakpoint can't be set exactly at that line.
    if (location == null) {
      _logger.fine('Failed to set breakpoint $id '
          '($scriptId:$line:$column): '
          'cannot find Dart location.');
      throw RPCError(
          'addBreakpoint',
          102,
          'The VM is unable to add a breakpoint $id '
              'at the specified line or function: ($scriptId:$line:$column): '
              ' cannot find Dart location.');
    }

    try {
      final dartBreakpoint = _dartBreakpoint(dartScript!, location, id);
      final jsBreakpointId = await _setJsBreakpoint(location);
      if (jsBreakpointId == null) {
        _logger.fine('Failed to set breakpoint $id '
            '($scriptId:$line:$column): '
            'cannot set JS breakpoint.');
        throw RPCError(
            'addBreakpoint',
            102,
            'The VM is unable to add a breakpoint $id '
                'at the specified line or function: ($scriptId:$line:$column): '
                'cannot set JS breakpoint at $location');
      }
      _note(jsId: jsBreakpointId, bp: dartBreakpoint);
      return dartBreakpoint;
    } on WipError catch (wipError) {
      throw RPCError('addBreakpoint', 102, '$wipError');
    }
  }

  /// Adds a breakpoint at [scriptId] and [line] or returns an existing one if
  /// present.
  Future<Breakpoint> add(String scriptId, int line, int column) async {
    final id = breakpointIdFor(scriptId, line, column);
    return _bpByDartId.putIfAbsent(
        id, () => _createBreakpoint(id, scriptId, line, column));
  }

  /// Create a Dart breakpoint at [location] in [dartScript] with [id].
  Breakpoint _dartBreakpoint(
      ScriptRef dartScript, Location location, String id) {
    final breakpoint = Breakpoint(
      id: id,
      breakpointNumber: int.parse(createId()),
      resolved: true,
      location: SourceLocation(
        script: dartScript,
        tokenPos: location.tokenPos,
        line: location.dartLocation.line,
        column: location.dartLocation.column,
      ),
      enabled: true,
    )..id = id;
    return breakpoint;
  }

  /// Calls the Chrome protocol setBreakpoint and returns the remote ID.
  Future<String?> _setJsBreakpoint(Location location) async {
    // The module can be loaded from a nested path and contain an ETAG suffix.
    final urlRegex = '.*${location.jsLocation.module}.*';
    // Prevent `Aww, snap!` errors when setting multiple breakpoints
    // simultaneously by serializing the requests.
    return _queue.run(() async {
      final breakPointId = await sendCommandAndValidateResult<String>(
          remoteDebugger,
          method: 'Debugger.setBreakpointByUrl',
          resultField: 'breakpointId',
          params: {
            'urlRegex': urlRegex,
            'lineNumber': location.jsLocation.line,
            'columnNumber': location.jsLocation.column,
          });
      return breakPointId;
    });
  }

  /// Records the internal Dart <=> JS breakpoint id mapping and adds the
  /// breakpoint to the current isolates list of breakpoints.
  void _note({required Breakpoint bp, required String jsId}) {
    final bpId = bp.id;
    if (bpId != null) {
      _dartIdByJsId[jsId] = bpId;
      _jsIdByDartId[bpId] = jsId;
      final isolate = inspector.isolate;
      isolate.breakpoints?.add(bp);
    }
  }

  Future<Breakpoint?> remove({
    required String jsId,
    required String dartId,
  }) async {
    final isolate = inspector.isolate;
    _dartIdByJsId.remove(jsId);
    _jsIdByDartId.remove(dartId);
    isolate.breakpoints?.removeWhere((b) => b.id == dartId);
    return await _bpByDartId.remove(dartId);
  }

  Future<Breakpoint>? breakpointFor(String dartId) => _bpByDartId[dartId];
  String? jsIdFor(String dartId) => _jsIdByDartId[dartId];
}

final escapedPipe = '\$124';
final escapedPound = '\$35';

/// Reformats a JS member name to make it look more Dart-like.
///
/// Logic copied from build/build_web_compilers/web/stack_trace_mapper.dart.
/// TODO(https://github.com/dart-lang/sdk/issues/38869): Remove this logic when
/// DDC stack trace deobfuscation is overhauled.
String _prettifyMember(String member) {
  member = member.replaceAll(escapedPipe, '|');
  if (member.contains('|')) {
    return _prettifyExtension(member);
  } else {
    if (member.startsWith('[') && member.endsWith(']')) {
      member = member.substring(1, member.length - 1);
    }
    return member;
  }
}

/// Reformats a JS member name as an extension method invocation.
String _prettifyExtension(String member) {
  var isSetter = false;
  final pipeIndex = member.indexOf('|');
  final spaceIndex = member.indexOf(' ');
  final poundIndex = member.indexOf(escapedPound);
  if (spaceIndex >= 0) {
    // Here member is a static field or static getter/setter.
    isSetter = member.substring(0, spaceIndex) == 'set';
    member = member.substring(spaceIndex + 1, member.length);
  } else if (poundIndex >= 0) {
    // Here member is a tear-off or local property getter/setter.
    isSetter = member.substring(pipeIndex + 1, poundIndex) == 'set';
    member = member.replaceRange(pipeIndex + 1, poundIndex + 3, '');
  } else {
    final body = member.substring(pipeIndex + 1, member.length);
    if (body.startsWith('unary') || body.startsWith('\$')) {
      // Here member's an operator, so it's safe to unescape everything lazily.
      member = _unescape(member);
    }
  }
  member = member.replaceAll('|', '.');
  return isSetter ? '$member=' : member;
}

/// Un-escapes a DDC-escaped JS identifier name.
///
/// Identifier names that contain illegal JS characters are escaped by DDC to a
/// decimal representation of the symbol's UTF-16 value.
/// Warning: this greedily escapes characters, so it can be unsafe in the event
/// that an escaped sequence precedes a number literal in the JS name.
String _unescape(String name) {
  return name.replaceAllMapped(
      RegExp(r'\$[0-9]+'),
      (m) =>
          String.fromCharCode(int.parse(name.substring(m.start + 1, m.end))));
}
