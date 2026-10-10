# Third-party notices

MSAL.Essentials bundles the libraries below in `src/lib/net472` (Windows PowerShell 5.1) and `src/lib/netstandard2.0` (PowerShell 7). The exact versions are pinned in [`src/lib/dependencies.json`](src/lib/dependencies.json). The set of libraries can differ between the two folders.

All of them are licensed under the MIT License. As the license requires, its text and the copyright notices are reproduced here.

| Library | Used for | License | Copyright | Project |
| --- | --- | --- | --- | --- |
| Microsoft.Identity.Client (MSAL.NET) | Acquiring tokens | MIT | Microsoft Corporation | <https://github.com/AzureAD/microsoft-authentication-library-for-dotnet> |
| Microsoft.IdentityModel.Abstractions | Shared identity and logging interfaces | MIT | Microsoft Corporation | <https://github.com/AzureAD/azure-activedirectory-identitymodel-extensions-for-dotnet> |
| System.Text.Json | JSON | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Diagnostics.DiagnosticSource | Diagnostics | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Formats.Asn1 | ASN.1 data | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| Microsoft.Bcl.AsyncInterfaces | Async interfaces on .NET Framework | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Buffers | Buffer pooling on .NET Framework | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Memory | `Span<T>` and `Memory<T>` on .NET Framework | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Numerics.Vectors | Vector types (dependency of System.Memory) | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Runtime.CompilerServices.Unsafe | Low-level memory operations | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Text.Encodings.Web | Text encoders | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.Threading.Tasks.Extensions | `ValueTask` on .NET Framework | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |
| System.ValueTuple | Tuple types on .NET Framework | MIT | .NET Foundation and Contributors | <https://github.com/dotnet/runtime> |

## Microsoft Corporation

Applies to: Microsoft.Identity.Client, Microsoft.IdentityModel.Abstractions

```text
MIT License

Copyright (c) Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## .NET Foundation and Contributors

Applies to: System.Text.Json, System.Diagnostics.DiagnosticSource, System.Formats.Asn1, Microsoft.Bcl.AsyncInterfaces, System.Buffers, System.Memory, System.Numerics.Vectors, System.Runtime.CompilerServices.Unsafe, System.Text.Encodings.Web, System.Threading.Tasks.Extensions, System.ValueTuple

```text
The MIT License (MIT)

Copyright (c) .NET Foundation and Contributors

All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```