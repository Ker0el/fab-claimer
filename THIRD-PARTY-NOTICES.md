# 第三方组件

本程序分发时包含以下第三方组件。各自的许可证归各自作者所有。

## Node.js (`core/node.exe`)

运行时为 **Node.js v24.19.0**，按 MIT 许可证分发。

```
Copyright Node.js contributors. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.
```

Node.js 自身还内嵌了若干第三方组件（OpenSSL、V8、ICU、zlib 等），
完整清单见 <https://github.com/nodejs/node/blob/main/LICENSE>。

## Playwright Core (`core/node_modules/playwright-core`)

Microsoft Corporation 出品，Apache License 2.0。

许可证全文和第三方声明随包提供，见该目录下的：

- `LICENSE`
- `NOTICE`
- `ThirdPartyNotices.txt`

## Microsoft Edge / Google Chrome

本程序**不包含**任何浏览器二进制。它只是在运行时调用用户自己机器上已安装的
Chromium 内核浏览器。相关商标归 Microsoft / Google 各自所有。
