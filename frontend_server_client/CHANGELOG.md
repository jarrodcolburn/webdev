## 3.3.0-dev

- Update SDK constraint to `>=3.0.0-134.0.dev <4.0.0`.
- Support changes in the SDK layout for Dart 3.0.

## 3.2.0

- Add `nativeAssets` parameter to `FrontendServerClient`, for passing
  additional `--native-assets` to the kernel compiler.

## 3.1.0

- Add `additionalSources` parameter to `FrontendServerClient`, for passing
  additional `--source`s to the kernel compiler.

## 3.0.0

- Update the `compile` api to return a non-null `CompileResult`, and instead
  make the `dillOutput` field nullable. This allows you to still get compiler
  output if no dill file was produced.

## 2.1.3

- Update `package:vm_service` to version `^8.0.0`

## 2.1.2

- Force kill the frontend server after one second when calling shutdown. It
  appears to hang on windows sometimes.

## 2.1.1

- Fix a bug where spaces in the output dill path would cause a parse error when
  reading the error count output.

## 2.1.0

- Support enabling experiments when starting the compiler.

## 2.0.1

- Widen the upper bound sdk constraint to `<3.0.0`. The frontend server api is
  now considered quite stable and this package is now depended on by
  package:test, so a tight constraint would cause unnecessary headaches.

## 2.0.0

- Support null safety.

## 1.0.0

- Initial version
