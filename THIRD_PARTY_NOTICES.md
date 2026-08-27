# Third-party notices

The device-control interaction patterns were informed by the open-source
HarmonyMacMVP project: <https://github.com/ufomaker/HarmonyMacMVP>.

Copyright (c) 2026 ufomaker

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

## scrcpy server

The application bundles the official `scrcpy-server` version 4.0 binary from
[Genymobile/scrcpy](https://github.com/Genymobile/scrcpy) for Android H.264
screen streaming.

- Copyright: Genymobile and scrcpy contributors
- License: Apache License 2.0
- Bundled license: `SCRCPY-LICENSE`
- Upstream source: <https://github.com/Genymobile/scrcpy/tree/v4.0>

The bundled binary SHA-256 is:

`84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a`

## HarmonyOS casting extension

The application includes the `libscreen_casting.z.so` device-side casting
extension obtained from the official Huawei DevEco Testing 26.0.0.400 macOS
package. It is temporarily deployed through HDC and is not installed as a HAP.

- Source product: Huawei DevEco Testing
- Binary SHA-256: `98bbc964fef1c4d17b446ec717102b855d09224b23fc1872bf70e1f928d010dd`

## gRPC Python runtime

The HarmonyOS local bridge bundles `grpcio` 1.83.0 and `protobuf` 7.36.0.
Their license texts are included as `GRPC-LICENSE` and `PROTOBUF-LICENSE`.

## hdctool UI test agent

The application bundles `uitest_agent_v1.2.4.so` obtained from Huawei DevEco
Testing for low-latency HarmonyOS touch RPC and casting-extension support.

- Source product: Huawei DevEco Testing
- Binary SHA-256: `789d15d69f107c945bc6ea1a0e7fd78860329ae7703a76d4d1bf8383bbdf503e`
