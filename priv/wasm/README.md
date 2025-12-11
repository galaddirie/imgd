# QuickJS WebAssembly Runtime

Place your `quickjs.wasm` binary in this directory. The sandbox expects the file at `priv/wasm/quickjs.wasm`.

You can build the binary yourself (e.g., via Emscripten/wasi-sdk) or download a prebuilt QuickJS-to-Wasm artifact that exports:

- `eval_js(input_ptr: i32, input_len: i32) -> i32`
- `get_output_len() -> i32`
- `get_error_ptr() -> i32`
- `get_error_len() -> i32`
- `alloc(size: i32) -> i32`
