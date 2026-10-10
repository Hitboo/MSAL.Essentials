# Microsoft.Identity.Client - dependency notes

> **Current version:** 4.90.1, published on NuGet **2026-09-25** (checked 2026-10-06).  
> Supported versions: 4.77.1 and newer. Older versions are unsupported.
> Source: <https://www.nuget.org/packages/Microsoft.Identity.Client>

## Dependency timeline

| Version | Dependencies |
|---|---|
| Older than 4.45.0 | Not verified per target framework. Some older versions list `Microsoft.CSharp` on certain targets. |
| **4.45.0** | `Microsoft.IdentityModel.Abstractions` (6.18.0) added for the net45 and net461 targets. The `netstandard2.0` target also lists `Microsoft.CSharp` 4.5.0. |
| Later 4.x | `System.Text.Json`, `System.Diagnostics.DiagnosticSource` and `System.Formats.Asn1` were added. *The exact version was not verified.* |
| **4.90.1 (current)** | See the per-target table below. |

### Direct dependencies of 4.90.1, per target

The targets differ, so the lists are **not** identical across frameworks.

| Target | Direct dependencies |
|---|---|
| net462 | `Microsoft.IdentityModel.Abstractions` ≥ 8.14.0, `System.Diagnostics.DiagnosticSource` ≥ 6.0.1, `System.Formats.Asn1` ≥ 8.0.1, `System.Text.Json` ≥ 6.0.10, `System.ValueTuple` ≥ 4.5.0 |
| net472 | the same as net462, **without** `System.ValueTuple` |
| netstandard2.0 | `Microsoft.IdentityModel.Abstractions`, `System.Diagnostics.DiagnosticSource`, `System.Formats.Asn1`, `System.Text.Json`, plus **`System.Security.Cryptography.Cng` ≥ 5.0.0** |
| net8.0 | `Microsoft.IdentityModel.Abstractions`, `System.Diagnostics.DiagnosticSource` |

Minimum versions are the same on every target where the package appears.

## TL;DR — why the lib folder has so many DLLs

MSAL used to ship with few external dependencies on .NET Framework. Newer versions rely on shared Microsoft packages instead of their own copies of that code:

- **`Microsoft.IdentityModel.Abstractions`**: shared interfaces and types used across Microsoft's identity libraries, including logging.
- **`System.Text.Json`**: the standard JSON library.
- **`System.Diagnostics.DiagnosticSource`** and **`System.Formats.Asn1`**: pulled in as direct dependencies. What MSAL uses them for isn't stated on NuGet. Likely uses are diagnostics/telemetry hooks and certificate/crypto parsing, but that is an assumption.

.NET Framework 4.x doesn't ship the modern base class library types these packages rely on (`Span<T>`, `Memory<T>`, `ArrayPool<T>`, `ValueTask`, and so on). Microsoft publishes them as separate NuGet packages, and they get installed as **transitive** dependencies.

## Why the net472 folder has 13 DLLs

That is MSAL itself, 4 direct dependencies and 8 transitive ones.

| DLL | Role |
|---|---|
| `Microsoft.Identity.Client.dll` | The library itself |
| `Microsoft.IdentityModel.Abstractions.dll` | **Direct.** Shared identity interfaces and logging types |
| `System.Text.Json.dll` | **Direct.** JSON serialization |
| `System.Diagnostics.DiagnosticSource.dll` | **Direct.** Diagnostics hooks |
| `System.Formats.Asn1.dll` | **Direct.** ASN.1 reading and writing |
| `Microsoft.Bcl.AsyncInterfaces.dll` | Transitive. `IAsyncEnumerable<T>` / `IAsyncDisposable` for `System.Text.Json` |
| `System.Buffers.dll` | Transitive. `ArrayPool<T>`. Required by `System.Formats.Asn1` and `System.Text.Json` |
| `System.Memory.dll` | Transitive. `Span<T>` / `Memory<T>`. Required by `System.Formats.Asn1` and `System.Text.Json` |
| `System.Numerics.Vectors.dll` | Transitive. Dependency of `System.Memory` |
| `System.Runtime.CompilerServices.Unsafe.dll` | Transitive. Low-level memory operations used by `Span<T>` |
| `System.Text.Encodings.Web.dll` | Transitive. A real library (not a polyfill) that `System.Text.Json` needs for text encoders |
| `System.Threading.Tasks.Extensions.dll` | Transitive. `ValueTask` / `ValueTask<T>` |
| `System.ValueTuple.dll` | Transitive. Declared by dependencies. On net472 itself the tuple types are already in the framework, so this DLL is effectively a facade |

> **Verification note:** only the link `System.Formats.Asn1 8.0.1` → `System.Buffers`, `System.Memory` (and `System.ValueTuple` on net462) was checked against NuGet. The other parent/child relationships in the table come from general knowledge of those packages. The transitive packages are pulled in by several of the direct dependencies, not only by `System.Text.Json`.

## netstandard2.0 (PowerShell 7)

The `netstandard2.0` target is **not** the same as net472. It has an additional direct dependency (`System.Security.Cryptography.Cng`), and which transitive DLLs end up in the folder depends on how the dependencies were resolved. Check the actual contents of `lib/netstandard2.0` instead of assuming it matches `lib/net472`.

## Pinning an old version

Rolling back to a pre-4.45.0 version to avoid these dependencies is **not recommended**:

- The `netstandard2.0` target is not dependency-free even in 4.45.0 (`Microsoft.CSharp`).
- Versions older than 4.77.1 are unsupported, and for example 4.49.1 is flagged as deprecated with a moderate-severity vulnerability.