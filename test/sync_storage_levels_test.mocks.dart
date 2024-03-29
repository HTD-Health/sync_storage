// Mocks generated by Mockito 5.0.12 from annotations
// in sync_storage/test/sync_storage_levels_test.dart.
// Do not manually edit this file.

import 'dart:async' as _i3;

import 'package:mockito/mockito.dart' as _i1;
import 'package:sync_storage/src/callbacks/storage_network_callbacks.dart'
    as _i2;

// ignore_for_file: avoid_redundant_argument_values
// ignore_for_file: avoid_setters_without_getters
// ignore_for_file: comment_references
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member
// ignore_for_file: prefer_const_constructors
// ignore_for_file: unnecessary_parenthesis

class _FakeStorageNetworkCallbacks<T> extends _i1.Fake
    implements _i2.StorageNetworkCallbacks<T> {}

/// A class which mocks [StorageNetworkCallbacks].
///
/// See the documentation for Mockito's code generation for more information.
class MockStorageNetworkCallbacks<T> extends _i1.Mock
    implements _i2.StorageNetworkCallbacks<T> {
  MockStorageNetworkCallbacks() {
    _i1.throwOnMissingStub(this);
  }

  @override
  _i2.StorageNetworkCallbacks<dynamic> copyWith(
          {_i2.OnDeleteCallback<T>? onDelete,
          _i2.OnCreateCallback<T>? onCreate,
          _i2.OnUpdateCallback<T>? onUpdate,
          _i2.OnFetchCallback<T>? onFetch}) =>
      (super.noSuchMethod(
              Invocation.method(#copyWith, [], {
                #onDelete: onDelete,
                #onCreate: onCreate,
                #onUpdate: onUpdate,
                #onFetch: onFetch
              }),
              returnValue: _FakeStorageNetworkCallbacks<dynamic>())
          as _i2.StorageNetworkCallbacks<dynamic>);
  @override
  _i3.Future<List<T>?> onFetch() =>
      (super.noSuchMethod(Invocation.method(#onFetch, []),
          returnValue: Future<List<T>?>.value()) as _i3.Future<List<T>?>);
  @override
  _i3.Future<void>? onDelete(T? element) => (super.noSuchMethod(
      Invocation.method(#onDelete, [element]),
      returnValueForMissingStub: Future<void>.value()) as _i3.Future<void>?);
  @override
  _i3.Future<T?> onCreate(T? element) =>
      (super.noSuchMethod(Invocation.method(#onCreate, [element]),
          returnValue: Future<T?>.value()) as _i3.Future<T?>);
  @override
  _i3.Future<T?> onUpdate(T? oldElement, T? newElement) => (super.noSuchMethod(
      Invocation.method(#onUpdate, [oldElement, newElement]),
      returnValue: Future<T?>.value()) as _i3.Future<T?>);
}
