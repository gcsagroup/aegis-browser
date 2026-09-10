import asyncio
import importlib.metadata
import json
import os
import sys
from pathlib import Path


async def main() -> None:
	config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))

	# 必须在导入 browser_use 前由父进程注入，防止 import 阶段初始化遥测。
	assert os.environ['ANONYMIZED_TELEMETRY'] == 'false'
	assert os.environ['BROWSER_USE_CLOUD_SYNC'] == 'false'
	assert os.environ['BROWSER_USE_DISABLE_EXTENSIONS'] == '1'
	assert not list(Path.cwd().glob('.env*'))

	from browser_use import BrowserProfile, BrowserSession

	profile = BrowserProfile(
		executable_path=config['browser_executable'],
		headless=True,
		chromium_sandbox=True,
		disable_security=False,
		use_cloud=False,
		user_data_dir=config['profile_path'],
		keep_alive=False,
		allowed_domains=['127.0.0.1'],
		block_ip_addresses=False,
		enable_default_extensions=False,
		captcha_solver=False,
		permissions=[],
		accept_downloads=False,
		auto_download_pdfs=False,
		cross_origin_iframes=False,
		highlight_elements=False,
		dom_highlight_elements=False,
		downloads_path=config['downloads_path'],
		viewport={'width': 1280, 'height': 800},
		args=[
			f"--ignore-certificate-errors-spki-list={config['fixture_spki_sha256']}",
			'--disable-background-networking',
			'--disable-component-update',
			'--disable-sync',
			'--metrics-recording-only',
			'--no-first-run',
		],
	)
	session = BrowserSession(browser_profile=profile)
	try:
		await session.start()
		await session.navigate_to(config['target_url'])
		state = await session.get_state_as_text()
		result = {
			'version': importlib.metadata.version('browser-use'),
			'url': await session.get_current_page_url(),
			'title': await session.get_current_page_title(),
			'state': state,
			'allowed_domains': list(session.browser_profile.allowed_domains or []),
			'use_cloud': session.browser_profile.use_cloud,
			'disable_security': session.browser_profile.disable_security,
			'enable_default_extensions': session.browser_profile.enable_default_extensions,
		}
		print(f"AEGIS_RESULT={json.dumps(result, ensure_ascii=False)}")
	finally:
		await session.stop()


if __name__ == '__main__':
	asyncio.run(main())
