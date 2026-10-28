import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    // Cargo's .d output lists Rust sources, but dependency pins and compiler
    // selection must also invalidate the cached native asset.
    output.dependencies.addAll([
      input.packageRoot.resolve('native/Cargo.toml'),
      input.packageRoot.resolve('native/Cargo.lock'),
      input.packageRoot.resolve('native/rust-toolchain.toml'),
    ]);
    // Android 16 KiB page alignment is handled by native/build.rs, so no extra
    // Cargo configuration needs to be shipped or passed here.
    await RustBuilder(
      assetName: 'uniffi:bdk_dart_ffi',
      extraCargoBuildArgs: ['--locked'],
    ).run(input: input, output: output);
  });
}
