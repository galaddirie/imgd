# QuickJS WebAssembly Runtime

The sandbox now targets a WASI build of QuickJS. By default it looks for `qjs-wasi.wasm` in the project root, but you can override the location with the `QJS_WASM_PATH` environment variable (for example, pointing at `priv/wasm/qjs-wasi.wasm`).

The runtime executes QuickJS' `_start` entrypoint with a bootstrap script passed via `-e`, so no custom exports are required beyond the standard WASI interfaces.
