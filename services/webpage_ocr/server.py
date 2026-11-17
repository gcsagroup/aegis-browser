"""Aegis 网页图片 OCR。只在内存中处理单张 PNG。"""

import argparse
import hmac
import io
import json
import logging
import os
import re
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image, UnidentifiedImageError


MAX_BODY = 8 * 1024 * 1024
MAX_PIXELS = 12_000_000
MAX_EDGE = 8192
MAX_RESPONSE_TEXT = 24_000
OCR_PATH = "/v1/ocr"
LOGGER = logging.getLogger("aegis.ocr")


class BadImage(ValueError):
    pass


def decode_image(data):
    """解码经过客户端重新编码的 PNG，不向识别引擎传递元数据。"""
    try:
        with Image.open(io.BytesIO(data), formats=["PNG"]) as source:
            width, height = source.size
            if (
                not 0 < width <= MAX_EDGE
                or not 0 < height <= MAX_EDGE
                or width * height > MAX_PIXELS
                or getattr(source, "is_animated", False)
            ):
                raise BadImage()
            rgba = source.convert("RGBA")
            pixels = Image.new("RGB", rgba.size, "white")
            pixels.paste(rgba, mask=rgba.getchannel("A"))
            return pixels
    except (UnidentifiedImageError, OSError, SyntaxError, Image.DecompressionBombError) as error:
        raise BadImage() from error


class PaddleEngine:
    def __init__(self, detection_dir, recognition_dir):
        # 两个模型由部署时预先准备，启动和推理均使用固定的本地路径。
        self._model_paths = (Path(detection_dir), Path(recognition_dir))
        for directory in self._model_paths:
            if not (directory / "inference.json").is_file() or not (
                directory / "inference.pdiparams"
            ).is_file():
                raise RuntimeError("缺少 OCR 模型文件")
        os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
        from paddleocr import PaddleOCR

        self._ocr = PaddleOCR(
            device="cpu",
            enable_mkldnn=False,
            text_detection_model_name="PP-OCRv5_server_det",
            text_detection_model_dir=str(self._model_paths[0]),
            text_recognition_model_name="PP-OCRv5_server_rec",
            text_recognition_model_dir=str(self._model_paths[1]),
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
        )

    def __call__(self, image):
        import numpy

        bgr = numpy.ascontiguousarray(numpy.asarray(image)[:, :, ::-1])
        return [
            text
            for page in self._ocr.predict(bgr)
            for text in page["rec_texts"]
        ]


class OCRServer(ThreadingHTTPServer):
    def __init__(self, address, token, engine, *, max_per_minute=60, max_connections=8):
        if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
            raise ValueError("OCR 凭证应为 32 至 256 位 URL 安全字符")
        super().__init__(address, OCRHandler)
        self.authorization = ("Bearer " + token).encode("ascii")
        self.engine = engine
        self.inference = threading.Lock()
        self.connections = threading.BoundedSemaphore(max_connections)
        self.rate_lock = threading.Lock()
        self.recent = deque()
        self.max_per_minute = max_per_minute

    def process_request(self, request, client_address):
        if not self.connections.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.connections.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connections.release()

    def admit(self):
        now = time.monotonic()
        with self.rate_lock:
            while self.recent and self.recent[0] <= now - 60:
                self.recent.popleft()
            if len(self.recent) >= self.max_per_minute:
                return False
            self.recent.append(now)
            return True

    def handle_error(self, _request, _client_address):
        LOGGER.info("connection_failed")


class OCRHandler(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    # 保留标准库的回调签名，避免默认日志记录客户端地址和原始请求行。
    def log_message(self, format, *args):  # pylint: disable=redefined-builtin
        pass

    def _reply(self, status, **payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        started = time.monotonic()
        status, result = self._recognize()
        LOGGER.info("status=%d elapsed_ms=%d", status, (time.monotonic() - started) * 1000)
        self._reply(status, **result)

    def _recognize(self):
        if self.path != OCR_PATH:
            return 404, {"error": "not_found"}
        offered = self.headers.get_all("Authorization") or []
        if len(offered) != 1 or not hmac.compare_digest(
            offered[0].encode("latin-1"), self.server.authorization
        ):
            return 401, {"error": "unauthorized"}
        if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Encoding"):
            return 415, {"error": "unsupported_encoding"}
        if self.headers.get_content_type() != "image/png":
            return 415, {"error": "unsupported_image"}
        lengths = self.headers.get_all("Content-Length") or []
        if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,12}", lengths[0]):
            return 400, {"error": "invalid_length"}
        length = int(lengths[0])
        if not 0 < length <= MAX_BODY:
            return 413, {"error": "image_too_large"}
        if not self.server.admit():
            return 429, {"error": "rate_limited"}
        if not self.server.inference.acquire(blocking=False):
            return 503, {"error": "busy"}
        try:
            data = self.rfile.read(length)
            if len(data) != length:
                return 400, {"error": "incomplete_image"}
            with decode_image(data) as image:
                texts = self.server.engine(image)
            text = "\n".join(line.strip() for line in texts if line.strip())
            return 200, {"text": text[:MAX_RESPONSE_TEXT]}
        except BadImage:
            return 422, {"error": "invalid_image"}
        except TimeoutError:
            return 408, {"error": "request_timeout"}
        except Exception:
            return 503, {"error": "engine_unavailable"}
        finally:
            self.server.inference.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8789)
    parser.add_argument("--detection-model", required=True)
    parser.add_argument("--recognition-model", required=True)
    options = parser.parse_args()
    token = os.environ.get("AEGIS_OCR_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        parser.error("请设置 AEGIS_OCR_TOKEN")
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    engine = PaddleEngine(options.detection_model, options.recognition_model)
    with OCRServer(("127.0.0.1", options.port), token, engine) as server:
        LOGGER.info("listening port=%d", server.server_port)
        server.serve_forever()


if __name__ == "__main__":
    main()
