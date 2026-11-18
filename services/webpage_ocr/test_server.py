import http.client
import io
import json
import secrets
import threading
import unittest

from PIL import Image, PngImagePlugin

from services.webpage_ocr.server import MAX_BODY, OCR_PATH, OCRServer


def png(size=(5, 7)):
    output = io.BytesIO()
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("source", "https://internal.example/private")
    Image.new("RGBA", size, (10, 20, 30, 255)).save(output, "PNG", pnginfo=metadata)
    return output.getvalue()


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.images = []
        self.token = secrets.token_urlsafe(32)
        self.allow_engine = threading.Event()
        self.allow_engine.set()
        self.engine_entered = threading.Event()

        def recognize(image):
            self.images.append((image.size, image.getpixel((0, 0)), dict(image.info)))
            self.engine_entered.set()
            if not self.allow_engine.wait(5):
                raise RuntimeError()
            return ["简体订单", "繁體資料", "E1024"]

        self.server = OCRServer(("127.0.0.1", 0), self.token, recognize, max_per_minute=6)
        self.server_thread = threading.Thread(target=self.server.serve_forever)
        self.server_thread.start()
        self.addCleanup(self.server_thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.allow_engine.set)

    def call(self, body=None, *, path=OCR_PATH, token=None, headers=None):
        client = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=8)
        try:
            client.request("POST", path, body if body is not None else png(), {
                "Authorization": "Bearer " + (self.token if token is None else token),
                "Content-Type": "image/png",
                **(headers or {}),
            })
            response = client.getresponse()
            return response.status, json.loads(response.read()), response.getheader("Cache-Control")
        finally:
            client.close()

    def test_exact_route_and_credentials_before_decode(self):
        self.assertEqual(self.call(token=secrets.token_urlsafe(32))[0], 401)
        self.assertEqual(self.call(path=OCR_PATH + "?url=https://internal")[0], 404)
        self.assertEqual(self.images, [])

    def test_returns_lines_and_passes_only_pixels(self):
        self.assertEqual(self.call(), (200, {"text": "简体订单\n繁體資料\nE1024"}, "no-store"))
        self.assertEqual(self.images, [((5, 7), (10, 20, 30), {})])

    def test_rejects_invalid_images_and_excessive_dimensions(self):
        self.assertEqual(self.call(b"not a png")[0], 422)
        self.assertEqual(self.call(png((8193, 1)))[0], 422)
        self.assertEqual(self.call(headers={"Content-Length": str(MAX_BODY + 1)})[0], 413)
        self.assertEqual(self.call(headers={"Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.images, [])

    def test_rate_limits_and_rejects_concurrent_inference(self):
        self.allow_engine.clear()
        first_request = []
        worker = threading.Thread(target=lambda: first_request.append(self.call()))
        worker.start()
        try:
            self.assertTrue(self.engine_entered.wait(5))
            self.assertEqual(self.call()[0], 503)
            for _ in range(4):
                self.assertEqual(self.call()[0], 503)
            self.assertEqual(self.call()[0], 429)
        finally:
            self.allow_engine.set()
            worker.join(timeout=8)
        self.assertEqual(first_request[0][0], 200)
        self.assertEqual(len(self.images), 1)


if __name__ == "__main__":
    unittest.main()
