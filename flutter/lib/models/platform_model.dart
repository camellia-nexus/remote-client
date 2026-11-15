import 'native_model.dart' if (dart.library.html) '../web/platform_ffi_web.dart';
import 'package:camellia_remote_app/generated_bridge.dart'
    if (dart.library.html) 'package:camellia_remote_app/web/bridge.dart';

final platformFFI = PlatformFFI.instance;
final localeName = PlatformFFI.localeName;

RustdeskImpl get bind => platformFFI.ffiBind;

String ffiGetByName(String name, [String arg = '']) {
  return PlatformFFI.getByName(name, arg);
}

void ffiSetByName(String name, [String value = '']) {
  PlatformFFI.setByName(name, value);
}
