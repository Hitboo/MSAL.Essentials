## Microsoft.Identity.Client — .NET Framework dependency timeline

| Version range | Dependencies (net45/net461/net472) |
|---|---|
| **1.x – 4.43.1** | None |
| **4.45.0** | `Microsoft.IdentityModel.Abstractions` added |
| **~4.5x – 4.6x** | `System.Text.Json`, `System.Diagnostics.DiagnosticSource`, `System.Formats.Asn1` added (net472 gets its own explicit build) |
| **4.86.0 (current)** | `Microsoft.IdentityModel.Abstractions`, `System.Diagnostics.DiagnosticSource`, `System.Formats.Asn1`, `System.Text.Json` |

### TL;DR why

MSAL used to be self-contained on .NET Framework — it shipped its own internal JSON handling and token-cache logic baked into the DLL. As Microsoft consolidated identity infrastructure across their SDKs (MSAL, Azure.Identity, IdentityModel/JWT libraries, etc.), they extracted shared pieces into standalone packages so all of them use the same code instead of duplicating it:

- **`Microsoft.IdentityModel.Abstractions`** — shared interfaces/types so MSAL and the IdentityModel/JWT stack speak the same "language" for tokens and logging.
- **`System.Text.Json`** — replaced MSAL's legacy/homegrown JSON (de)serialization with Microsoft's standard, faster JSON library.
- **`System.Diagnostics.DiagnosticSource`** / **`System.Formats.Asn1`** — added for telemetry/observability hooks and certificate/crypto parsing (used in cert-based auth flows).

### Why the folder has 12 DLLs, not just 4

Only 4 of these are dependencies MSAL *actually asked for* directly. The rest exist purely because **.NET Framework 4.x predates `System.Text.Json`**, and that library internally relies on modern BCL types (`Span<T>`, `Memory<T>`, `ValueTuple`, async interfaces, etc.) that .NET Framework never shipped in the box. Microsoft backported each of those as separate NuGet "polyfill" packages so `System.Text.Json` can run on net472 at all — so installing it drags all of them in as *transitive* dependencies.

On **`netstandard2.0`** (used by PowerShell 7 / .NET Core+), you get the exact same list, because netstandard2.0 is a *contract*, not a runtime — it still compiles against these polyfills even though the actual .NET Core/.NET 5+ runtime underneath already has native versions of most of them built in.

| DLL | Why it's there |
|---|---|
| `Microsoft.Identity.Client.dll` | The library itself |
| `Microsoft.IdentityModel.Abstractions.dll` | **Direct dependency** — shared token/logging interfaces across Microsoft's identity libraries |
| `System.Text.Json.dll` | **Direct dependency** — MSAL's JSON serializer |
| `System.Diagnostics.DiagnosticSource.dll` | **Direct dependency** — telemetry/observability hooks |
| `System.Formats.Asn1.dll` | **Direct dependency** — ASN.1 parsing for certificate-based auth flows |
| `Microsoft.Bcl.AsyncInterfaces.dll` | Polyfill — `IAsyncEnumerable<T>`/`IAsyncDisposable` support for `System.Text.Json` |
| `System.Buffers.dll` | Polyfill — `ArrayPool<T>` used internally by `System.Text.Json` for low-allocation parsing |
| `System.Memory.dll` | Polyfill — `Span<T>`/`Memory<T>`, core to how `System.Text.Json` reads/writes without extra allocations |
| `System.Numerics.Vectors.dll` | Polyfill — SIMD vector types that `System.Memory` depends on |
| `System.Runtime.CompilerServices.Unsafe.dll` | Polyfill — low-level pointer/memory operations backing `Span<T>` |
| `System.Text.Encodings.Web.dll` | Polyfill — UTF-8/HTML/URL encoding helpers used by `System.Text.Json` |
| `System.Threading.Tasks.Extensions.dll` | Polyfill — `ValueTask`/`ValueTask<T>` for efficient async code paths |
| `System.ValueTuple.dll` | Polyfill — tuple syntax (`(int, string)`) support, since net472 predates built-in tuples |

**Bottom line:** 4 real dependencies pull in 8 more just to make `System.Text.Json` (a .NET Core–era library) runnable on a much older runtime. This entire chain disappears if you pin to a pre-4.45.0 version like `4.43.1`, since that release predates all of it.