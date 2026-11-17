# Aegis 网页图片文字识别服务

浏览器本机识别失败或用户主动重试时，可以在预览所选图片后发送。服务接收一张 PNG，返回按行排列的 UTF-8 文本。四个平台使用同一个接口。

- `POST /v1/ocr`，请求类型 `image/png`，请求体是重新编码的 PNG 字节。
- 成功响应为 `{"text":"第一行\n第二行"}`。没识别到文字时返回空字符串。
- 错误响应包含 `error`。客户端保留预览和已有结果，让用户决定是否重试。
- 输入上限 8 MiB、1,200 万像素、任一边不超过 8192 像素。响应与缓存代理均应使用 `Cache-Control: no-store`。

## 在测试环境启动

使用 Python 3.11–3.12 的独立环境安装 `requirements.txt`。下载 `PP-OCRv5_server_det` 和 `PP-OCRv5_server_rec` 的推理模型并解包到服务专用目录。由运行环境注入随机的 `AEGIS_OCR_TOKEN`，然后执行下面的命令启动服务。[PaddleOCR 官方模型表](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/OCR.html)

```sh
python -m services.webpage_ocr.server \
  --port 8789 \
  --detection-model /path/to/PP-OCRv5_server_det_infer \
  --recognition-model /path/to/PP-OCRv5_server_rec_infer
```

HTTP 服务只监听 `127.0.0.1`，要求 `Authorization: Bearer <token>`。生产环境由自有 HTTPS 网关对外提供 `/v1/ocr`，按客户端来源限流，并使用网关持有的凭证调用回环服务。浏览器发出的生产请求仅包含所选 PNG，服务凭证由网关注入。关闭网关的请求体日志、响应体日志和磁盘请求缓冲，限制网关的请求大小与并发，并为推理进程配置 CPU、内存和超时上限。服务本身的日志只记录请求状态与用时，服务接口不接收图片 URL。

在浏览器的「设置 → Aegis 设置 → 图片文字识别」选择「使用 Aegis 服务」「自定义服务器」或「仅本机识别」。自定义服务器填写完整的 HTTPS 接口地址，例如 `https://ocr.example.com/v1/ocr`。保存后即时生效，每次发送前仍要确认预览和服务器地址。

Chromium 发行构建可通过 GN 参数 `aegis_ocr_service_url` 预置 Aegis 服务地址。iOS 通过构建设置 `AEGIS_OCR_SERVICE_URL` 指定同一地址。选择「使用 Aegis 服务」时，Chromium 的 `--aegis-image-ocr-endpoint` 和 iOS Debug 的 `AEGIS_OCR_TEST_URL` 可覆盖该预置值。回环测试时，Chromium 另需 `--aegis-image-ocr-loopback-test` 和进程环境变量 `AEGIS_OCR_TEST_TOKEN`，iOS Debug 需要 `AEGIS_OCR_TEST_TOKEN`。

执行接口回归测试。

```sh
python -m unittest services.webpage_ocr.test_server -v
```
