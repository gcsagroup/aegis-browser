#!/usr/bin/env python3
"""仅监听本机的模拟器验收服务；网页与模型响应均为明确的合成资料。"""
import argparse
import hashlib
import json
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.client import HTTPConnection
from urllib.parse import parse_qs, urlsplit

PAYLOAD = b"GCSA Aegis simulator download verification\n" * 1024
ARTICLE = """<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>模拟器验收文章</title><style>body{font:20px -apple-system;margin:24px;line-height:1.6}a{display:block;margin:20px 0}</style>
<main><h1>城市绿地观察</h1><p>这是一份合成验收资料。青林公园面积为 12 公顷，开放时间为每天 06:00 至 21:00，步道总长 3 公里。</p>
<p>2026 年的改造计划包括增加 40 棵乔木和两个饮水点。本文没有提供项目预算。</p></main>
<a href="/article-two" target="_blank">打开第二篇来源</a><a href="/download.bin" download>下载验收文件</a>
<a href="/sensitive">登录表单测试</a><input placeholder="输入框不应进入助手" value="private form text">
</html>"""
SECOND = """<!doctype html><html lang="zh-CN"><meta name="viewport" content="width=device-width,initial-scale=1"><title>第二篇合成来源</title>
<main><h1>绿地改造补充说明</h1><p>青林公园将增加 40 棵乔木，两个饮水点。施工期间部分步道临时关闭。该说明没有列出日期和预算。</p></main></html>"""


class Handler(BaseHTTPRequestHandler):
    dropped_paths = set()
    drop_lock = threading.Lock()
    request_counts = {}
    watch_count = 0
    request_lock = threading.Lock()

    @classmethod
    def count_request(cls, marker, kind):
        # 只保存合成验收标记及次数，不记录模型输入或页面正文。
        if not re.fullmatch(r"(?:AEGISPRIVATE_[A-F0-9-]+|SECURITY_[A-Za-z0-9_-]{1,80})", marker):
            return
        with cls.request_lock:
            counts = cls.request_counts.setdefault(marker, {"model": 0, "download": 0})
            counts[kind] = counts.get(kind, 0) + 1

    def log_message(self, *_):
        pass

    def respond(self, status, data, mime="application/json; charset=utf-8", headers=None):
        if not isinstance(data, bytes):
            data = data.encode("utf-8") if isinstance(data, str) else json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        query = parse_qs(urlsplit(self.path).query)
        if path in ("/enhancements/page", "/enhancements/frame"):
            html = """<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>网站增强验收</title>
<script>window.aegisOrder=!!document.documentElement.dataset.early;
window.addEventListener('contextmenu',e=>{window.contextBlocked=true;e.preventDefault();});
window.addEventListener('copy',e=>{window.copyBlocked=true;e.preventDefault();});</script>
<style>body{font:20px system-ui;margin:24px;user-select:none}main{max-width:600px}aside{padding:20px;background:#ddd}button{font:inherit;padding:10px}</style></head>
<body><main><h1>网站增强验收文章</h1><p>这段文字用于检查选取、复制、脚本样式和存储。</p><button id="normal-button" onclick="this.textContent='普通按钮正常'">普通按钮</button><input placeholder="保留未提交输入"></main><aside>右侧栏</aside><div id="frames"></div></body></html>"""
            if path.endswith("page"):
                html = html.replace('<div id="frames"></div>', '<iframe src="/enhancements/frame"></iframe><iframe src="http://localhost:8768/enhancements/frame"></iframe>')
            return self.respond(200, html, "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path in ("/enhancements/document.md", "/enhancements/attachment.md"):
            text = "# Markdown 验收\n\n城市绿地观察：中文长文与 **粗体**。\n\n## 重复标题\n\n- [x] 完成项目\n- [ ] 待办项目\n\n|名称|数值|\n|---|---|\n|绿地|12 公顷|\n\n## 重复标题\n\n```js\nconst value = 42;\n```\n\n<script>window.markdownExecuted=true</script>\n\n[危险链接](javascript:alert(1))\n"
            headers = {"Content-Disposition": 'attachment; filename="document.md"'} if path.endswith("attachment.md") else {}
            return self.respond(200, text, "text/markdown; charset=utf-8", headers)
        if path == "/enhancements/fake.md":
            return self.respond(200, "<h1>实际为 HTML，不能接管</h1>", "text/html; charset=utf-8")
        if path == "/test-request-counts":
            marker = query.get("case", [""])[0]
            with self.request_lock:
                counts = dict(self.request_counts.get(marker, {"model": 0, "download": 0}))
            return self.respond(200, counts)
        if path.startswith("/security-fixture/"):
            category = path.split("/")[2]
            self.count_request(query.get("case", [""])[0], category)
            return self.respond(200, "globalThis.fixtureExecuted=true;", "application/javascript", {"Cache-Control": "no-store"})
        if path == "/security/resources":
            marker = query.get("case", [""])[0]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", marker):
                return self.respond(400, "invalid marker")
            page = f'''<!doctype html><meta name="viewport" content="width=device-width"><title>安全资源验收</title>
            <main>安全资源验收：检查脚本、Worker 和请求是否被拦截。</main>
            <script src="/security-fixture/mining/script.js?case={marker}"></script>
            <script src="/security-fixture/fingerprinting/script.js?case={marker}"></script>
            <script>try {{ new Worker('/security-fixture/mining/worker.js?case={marker}'); }} catch {{}}
            fetch('/security-fixture/mining/endpoint?case={marker}').catch(()=>{{}});
            fetch('/security-fixture/fingerprinting/endpoint?case={marker}').catch(()=>{{}});
            window.fixtureReady=true;</script>'''
            return self.respond(200, page, "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path in ("/security/login", "/security/safe", "/security/dynamic"):
            malicious = path != "/security/safe"
            title = "PayPal verify your account" if malicious else "本机登录示例"
            form = '<form action="http://untrusted.example.invalid/collect"><input type=password><button>提交</button></form>' if malicious else '<form action="/security/safe"><input type=password><button>登录</button></form>'
            if path == "/security/dynamic":
                form = '<script>setTimeout(()=>{document.body.insertAdjacentHTML("beforeend",' + json.dumps(form) + ')},500);</script>'
            return self.respond(200, f'<!doctype html><meta name="viewport" content="width=device-width"><title>{title}</title><body><main>{title}</main>{form}</body>', "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/security/redirect":
            return self.respond(302, "", headers={"Location": "http://paypal.example.top/login"})
        if path == "/security/canvas":
            return self.respond(200, '''<!doctype html><meta name="viewport" content="width=device-width"><title>指纹兼容验收</title><main>绘图与读取验收</main><canvas id="canvas" width="32" height="32"></canvas>
            <script>const ctx=document.getElementById('canvas').getContext('2d');ctx.fillStyle='red';ctx.fillRect(0,0,32,32);window.drawingWorked=true;
            try{canvas.toDataURL();window.canvasReadable=true;}catch(e){window.canvasReadable=false;window.canvasError=e.name;}
            if(parent!==window)parent.postMessage({kind:"security-frame",readable:canvasReadable},"*");
            const ac=new AudioContext();const ab=ac.createBuffer(1,16,ac.sampleRate);try{ab.getChannelData(0);window.audioReadable=true;}catch{window.audioReadable=false;}ac.close();

            </script>''', "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/security/worker":
            return self.respond(200, "onmessage=()=>{let result={offscreen:typeof OffscreenCanvas!=='undefined'};try{const c=new OffscreenCanvas(4,4);c.getContext('2d').getImageData(0,0,1,1);result.readable=true;}catch{result.readable=false;}postMessage(result)};", "application/javascript")
        if path == "/article":
            marker = query.get("case", [""])[0]
            article = ARTICLE
            if re.fullmatch(r"AEGISPRIVATE_[A-F0-9-]+", marker):
                article = ARTICLE.replace("</main>", "<p>" + marker + "</p></main>")
            return self.respond(200, article, "text/html; charset=utf-8")
        if path == "/long-article":
            return self.respond(200, ARTICLE.replace("</main>", "<p>合成长页面滚动验收。</p>" * 150 + "</main>"), "text/html; charset=utf-8")
        if path == "/test.txt":
            return self.respond(200, "这是文件预览验收资料。", "text/plain; charset=utf-8")
        if path == "/article-two":
            return self.respond(200, SECOND, "text/html; charset=utf-8")
        if path == "/sensitive":
            return self.respond(200, "<main>测试登录页</main><input type=password value='private'>", "text/html; charset=utf-8")
        if path == "/download.bin":
            self.count_request(query.get("case", [""])[0], "download")
            return self.respond(200, PAYLOAD, "application/octet-stream", {"Content-Disposition": f'attachment; filename="aegis-test-{time.time_ns()}.bin"', "Accept-Ranges": "bytes"})
        if path == "/oversize.bin":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "100000001")
            self.end_headers()
            try:
                for _ in range(8):
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
                    time.sleep(0.03)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path in ("/slow.bin", "/drop.bin"):
            with self.drop_lock:
                drop = path == "/drop.bin" and self.path not in self.dropped_paths
                self.dropped_paths.add(self.path)
            data = PAYLOAD * 32
            start = 0
            match = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range", ""))
            if match:
                start = min(int(match[1]), len(data))
            self.send_response(206 if start else 200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data) - start))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '"aegis-slow-v1"')
            if start:
                self.send_header("Content-Range", f"bytes {start}-{len(data)-1}/{len(data)}")
            self.end_headers()
            try:
                for offset in range(start, len(data), 16384):
                    self.wfile.write(data[offset:offset + 16384])
                    self.wfile.flush()
                    time.sleep(0.05)
                    if drop:
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                        return
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if path == "/preferences":
            return self.respond(200, '<!doctype html><title>JavaScript disabled</title><main id="status">JavaScript disabled</main><script>document.title="JavaScript enabled";document.getElementById("status").textContent="JavaScript enabled";</script>', mime="text/html; charset=utf-8", headers={"Cache-Control": "no-store"})
        if path == "/watch":
            with self.request_lock:
                Handler.watch_count += 1
                count = Handler.watch_count
            return self.respond(200, f'<!doctype html><title>Watch fixture</title><main>Revision {count}</main>', mime="text/html; charset=utf-8", headers={"Cache-Control": "no-store"})
        if path == "/v1/models":
            return self.respond(200, {"data": [{"id": "aegis-simulator-fixture"}]})
        if path == "/redirect-model":
            return self.respond(302, {}, headers={"Location": "/v1/models"})
        return self.respond(404, {"error": "合成服务未提供此路径"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/v1/chat/completions", "/v1/messages", "/v1/models/aegis-simulator-fixture:streamGenerateContent"):
            return self.respond(404, {"error": "未知接口"})
        if path == "/v1/models/aegis-simulator-fixture:streamGenerateContent":
            provider = "gemini"
        else:
            provider = "anthropic" if path == "/v1/messages" else "compatible"
        length = int(self.headers.get("Content-Length", "0"))
        if length > 200_000:
            return self.respond(413, {"error": "输入过大"})
        try:
            value = json.loads(self.rfile.read(length))
            for marker in set(re.findall(r"AEGISPRIVATE_[A-F0-9-]+", json.dumps(value))):
                self.count_request(marker, "model")
            model = value.get("model", "aegis-simulator-fixture")
            if model in ("error-401", "error-429", "error-503"):
                return self.respond(int(model[-3:]), {"error": "合成错误"}, headers={"Retry-After": "3"})
            if provider == "gemini":
                content = value["contents"][-1]["parts"][0]["text"]
            else:
                content = value["messages"][-1]["content"]
            if model == "aegis-simulator-fixture" and "AEGIS_READING_TRANSLATION" in content and "城市绿地观察" in content:
                result = json.dumps({"translation": "Urban green space survey. Qinglin Park covers 12 hectares, opens daily from 06:00 to 21:00, and has 3 kilometres of trails. Plans include 40 trees and two drinking fountains. No budget is provided."})
                return self.respond(200, {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": result}}]})
            if model == "aegis-simulator-fixture" and "AEGIS_BROWSER_PLAN" in content and "模拟器验收文章" in content:
                result = json.dumps({"steps": [{"kind": "groupTabs", "name": "模型建议分组"}, {"kind": "saveWorkspace", "name": "模型建议工作区"}]})
                return self.respond(200, {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": result}}]})
            if model not in ("aegis-simulator-fixture", "stream-slow", "stream-cut", "json-fallback") or "城市绿地观察" not in content:
                return self.respond(400, {"error": "没有收到预期的真实页面正文"})
            result = "合成模型验收结果：青林公园面积为 12 公顷，每天 06:00 至 21:00 开放，步道长 3 公里。[1]\n改造计划增加 40 棵乔木和两个饮水点；资料未提供预算。[1]"
            if "来源 [2]" in content:
                result += "\n第二篇来源还说明施工期间部分步道临时关闭，未提供具体日期。[2]"
            if (value.get("stream") or provider == "gemini") and model != "json-fallback":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                def event(value):
                    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
                    self.wfile.write(("data: " + text + "\n\n").encode())
                    self.wfile.flush()
                try:
                    if provider == "anthropic":
                        event({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
                    for offset in range(0, len(result), 8):
                        part = result[offset:offset+8]
                        if provider == "compatible":
                            event({"choices": [{"index": 0, "delta": {"content": part}, "finish_reason": None}]})
                        elif provider == "anthropic":
                            event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": part}})
                        else:
                            event({"candidates": [{"index": 0, "content": {"parts": [{"text": part}]}}]})
                        # 为原生界面的取消操作保留窗口，避免响应在滚动或动画中结束。
                        time.sleep(1.0 if model == "stream-slow" else 0.07)
                        if model == "stream-cut":
                            return
                    if provider == "compatible":
                        event({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
                        event("[DONE]")
                    elif provider == "anthropic":
                        event({"type": "message_delta", "delta": {"stop_reason": "end_turn"}})
                        event({"type": "message_stop"})
                    else:
                        event({"candidates": [{"index": 0, "finishReason": "STOP", "content": {"parts": []}}]})
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            return self.respond(200, {"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": result}}]})
        except (KeyError, ValueError, TypeError):
            return self.respond(400, {"error": "请求格式不正确"})


def self_test():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # 仅连接刚启动的本机服务，不接受 URL，也不自动跟随重定向。
    def request(method, path, body=None):
        connection = HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        try:
            connection.request(method, path, body=body, headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            data = response.read()
            if response.status != 200:
                raise RuntimeError(f"验收请求失败：{path} HTTP {response.status}")
            return data
        finally:
            connection.close()

    try:
        if "城市绿地观察" not in request("GET", "/article").decode():
            raise RuntimeError("文章内容不匹配")
        if request("GET", "/download.bin") != PAYLOAD:
            raise RuntimeError("下载内容不匹配")
        if json.loads(request("GET", "/v1/models"))["data"][0]["id"] != "aegis-simulator-fixture":
            raise RuntimeError("模型列表不匹配")
        payload = {"model": "aegis-simulator-fixture", "messages": [{"role": "user", "content": "城市绿地观察 来源 [2]"}]}
        result = json.loads(request("POST", "/v1/chat/completions", json.dumps(payload).encode()))
        if "[2]" not in result["choices"][0]["message"]["content"]:
            raise RuntimeError("模型响应缺少第二篇来源")
        payload["stream"] = True
        stream = request("POST", "/v1/chat/completions", json.dumps(payload).encode()).decode()
        if "[DONE]" not in stream or "delta" not in stream:
            raise RuntimeError("流式响应缺少结束标记")
        stream = request("POST", "/v1/messages", json.dumps(payload).encode()).decode()
        if "message_stop" not in stream:
            raise RuntimeError("Anthropic 流未结束")
        payload = {"contents": [{"parts": [{"text": "城市绿地观察"}]}]}
        stream = request("POST", "/v1/models/aegis-simulator-fixture:streamGenerateContent?alt=sse", json.dumps(payload).encode()).decode()
        if "STOP" not in stream:
            raise RuntimeError("Gemini 流未结束")
        marker = "AEGISPRIVATE_00000000-0000-4000-8000-000000000001"
        if json.loads(request("GET", "/test-request-counts?case=" + marker)) != {"model": 0, "download": 0}:
            raise RuntimeError("确认前计数不是零")
        payload = {"model": "aegis-simulator-fixture", "messages": [{"role": "user", "content": "城市绿地观察 " + marker}]}
        request("POST", "/v1/chat/completions", json.dumps(payload).encode())
        if json.loads(request("GET", "/test-request-counts?case=" + marker)) != {"model": 1, "download": 0}:
            raise RuntimeError("模型请求计数不匹配")
        request("GET", "/download.bin?case=" + marker)
        if json.loads(request("GET", "/test-request-counts?case=" + marker)) != {"model": 1, "download": 1}:
            raise RuntimeError("下载请求计数不匹配")
        for marker, body, field in [("AEGIS_READING_TRANSLATION", "城市绿地观察", "translation"), ("AEGIS_BROWSER_PLAN", "模拟器验收文章", "steps")]:
            payload = {"model": "aegis-simulator-fixture", "messages": [{"role": "user", "content": marker + " " + body}]}
            result = json.loads(request("POST", "/v1/chat/completions", json.dumps(payload).encode()))
            structured = json.loads(result["choices"][0]["message"]["content"])
            if field not in structured:
                raise AssertionError("结构化模型响应无效")
        if "JavaScript enabled" not in request("GET", "/preferences").decode():
            raise AssertionError("脚本设置网页缺失")
        if request("GET", "/watch") == request("GET", "/watch"):
            raise AssertionError("网页更新样例未变化")
        if "fixtureReady" not in request("GET", "/security/resources?case=SECURITY_SELF_TEST").decode():
            raise AssertionError("安全资源样例缺失")
        request("GET", "/security-fixture/mining/script.js?case=SECURITY_SELF_TEST")
        if json.loads(request("GET", "/test-request-counts?case=SECURITY_SELF_TEST")).get("mining") != 1:
            raise AssertionError("安全资源真实请求计数无效")
        for route in ("login", "safe", "dynamic", "canvas"):
            if "<title>" not in request("GET", "/security/" + route).decode():
                raise AssertionError("安全页面样例缺失")
        print("SIMULATOR_FIXTURE_SELF_TEST=PASS cases=20")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8768)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        print(json.dumps({"base_url": f"http://127.0.0.1:{server.server_port}", "download_sha256": hashlib.sha256(PAYLOAD).hexdigest(), "model": "aegis-simulator-fixture"}), flush=True)
        server.serve_forever()
