defmodule Imgd.SandboxSecurityTest do
  use ExUnit.Case, async: true
  alias Imgd.Sandbox
  alias Imgd.Sandbox.Error

  setup do
    unless Process.whereis(Imgd.Sandbox.Runner) do
      start_supervised!(Imgd.Sandbox.Supervisor)
    end
    :ok
  end

  describe "Filesystem Isolation" do
    test "cannot read arbitrary files" do
      # Attempt to read /etc/passwd or similar using QuickJS std/os modules if available
      # Note: The QJS WASI build might expose 'std' or 'os' modules, but WASI sandbox should block access.
      # If 'std' is not loaded by default, we try to import it.

      code = """
      import * as std from 'std';
      try {
        const content = std.loadFile('/etc/passwd');
        return content;
      } catch(err) {
        throw new Error("Access denied: " + err.message);
      }
      """

      # Since we are using qjs-wasi.wasm, it likely relies on WASI for file ops.
      # If we don't pre-open directories, access should be denied.

      # However, `import` statements might fail if modules aren't resolved.
      # Let's try to use the global `std` or `os` if they exist, or check basic file operations.
      # The bootstrap script doesn't import std/os into global.

      # If `import` works (ESM), it implies module loading.
      # If qjs is built as a standalone binary run via wasi, it might not support dynamic imports easily without a loader.

      # Let's try a simpler check: verify if we can access the root directory via any global APIs if they exist.
      # But mostly, we want to ensure that IF someone manages to run file I/O code, it fails.

      # Let's write a test that assumes 'std' module presence or tries to use it.
      # If 'import' fails with syntax error (if not module mode) or resolution error, that's also secure-ish (functionality unavailable).

      # But qjs-wasi usually supports `std` and `os` builtins.

      # Our executor uses `qjs -m -e ...` so it IS in module mode.

      assert {:error, %Error{message: msg}} = Sandbox.eval(code)
      # We expect either a module resolution error (secure) or an access denied error (secure).
      # We just want to make sure it DOES NOT return the content of /etc/passwd.
      assert msg =~ "Access denied" or msg =~ "module not found" or msg =~ "error"
    end

    test "cannot write files" do
       code = """
       import * as std from 'std';
       const fd = std.open('hacked.txt', 'w');
       if (fd) {
         fd.puts('pwned');
         fd.close();
         return 'wrote file';
       }
       return 'failed';
       """

       assert {:error, %Error{}} = Sandbox.eval(code)
    end
  end

  describe "Environment Isolation" do
    test "cannot access host environment variables" do
      code = """
      import * as std from 'std';
      return std.getenv('PATH');
      """

      # If std is available, getenv should return undefined or null, NOT the host PATH.
      # Or the import fails.

      case Sandbox.eval(code) do
        {:ok, nil} -> assert true
        {:ok, ""} -> assert true
        {:error, _} -> assert true # Import failure is also secure
        {:ok, val} ->
           # If we get a value, it must NOT be the host's PATH (which is likely non-empty)
           # WASI env is usually empty unless explicitly passed.
           # We passed %{} in Executor.
           assert val == nil or val == ""
      end
    end
  end

  describe "Network Isolation" do
    test "cannot make network requests" do
      # QuickJS WASI usually doesn't have network sockets unless extensions are added.
      # We verify that typical network globals don't exist or fail.

      code = """
      if (typeof fetch !== 'undefined') {
        return fetch('https://google.com').then(r => r.text());
      }
      return 'no fetch';
      """

      # We expect 'no fetch' or an error if fetch exists but fails (WASI typically blocks it).
      assert {:ok, "no fetch"} = Sandbox.eval(code)
    end
  end

  describe "Global Namespace Pollution" do
    test "globals are restricted" do
       code = """
       return Object.keys(globalThis).filter(k => k !== 'args' && k !== 'console' && k !== 'print');
       """
       # This is an exploratory test. We want to see what's exposed.
       # We just assert it returns a list, and we can inspect it if needed.
       assert {:ok, keys} = Sandbox.eval(code)
       assert is_list(keys)

       # Critical checks: no 'process' (Node.js), no 'window' (Browser)
       refute "process" in keys
       refute "window" in keys
    end
  end
end
