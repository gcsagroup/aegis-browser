import asyncio
import importlib.metadata
import json
import os
import sys
from pathlib import Path


def _json_payload(raw: str) -> str:
	text = raw.strip()
	if text.lower().startswith('```json'):
		text = text[7:]
	elif text.startswith('```'):
		text = text[3:]
	if text.endswith('```'):
		text = text[:-3]
	return text.strip()


def build_local_openai_llm(config):
	from browser_use.llm import ChatOpenAI
	from browser_use.llm.messages import SystemMessage
	from browser_use.llm.views import ChatInvokeCompletion

	class LocalJsonChatOpenAI(ChatOpenAI):
		async def ainvoke(self, messages, output_format=None, **kwargs):
			if output_format is None:
				return await super().ainvoke(messages, output_format=None, **kwargs)
			schema = output_format.model_json_schema()
			local_messages = [SystemMessage(content=(
				'只返回一个可被 JSON.parse 直接解析、符合下列 JSON Schema 的 JSON 值。'
				'禁止 Markdown 代码围栏、解释和额外文字。'
				'动作对象必须严格使用 schema 字段，禁止重复动作名；'
				'例如点击索引 1 必须写成 {"action":[{"click":{"index":1}}]}，'
				'不能写成 {"action":[{"click":{"click":1}}]}。\n'
				+ json.dumps(schema, ensure_ascii=False)
			))] + list(messages)
			raw = await super().ainvoke(local_messages, output_format=None, **kwargs)
			parsed = output_format.model_validate_json(_json_payload(raw.completion))
			return ChatInvokeCompletion(
				completion=parsed,
				thinking=raw.thinking,
				redacted_thinking=raw.redacted_thinking,
				usage=raw.usage,
				stop_reason=raw.stop_reason,
				stop_details=raw.stop_details,
			)

	return LocalJsonChatOpenAI(
		model=config['model']['model'],
		api_key='local-fixture-only',
		base_url=config['model']['base_url'],
		temperature=0,
		reasoning_effort=None,
		max_retries=1,
		max_completion_tokens=2048,
	)


def build_llm(config):
	from browser_use.llm import ChatAnthropic, ChatGoogle, ChatOpenAI

	provider = config['model']['provider']
	model = config['model']['model']
	base_url = config['model'].get('base_url')
	local = config['model'].get('local', False)
	if provider == 'openai':
		if local:
			return build_local_openai_llm(config)
		return ChatOpenAI(
			model=model,
			api_key=os.environ.get('OPENAI_API_KEY'),
			base_url=base_url,
			temperature=0,
			reasoning_effort=None,
			max_retries=1,
			max_completion_tokens=2048,
		)
	if provider == 'anthropic':
		return ChatAnthropic(
			model=model,
			api_key=os.environ.get('ANTHROPIC_API_KEY'),
			base_url=base_url,
			temperature=0,
			max_retries=1,
		)
	if provider == 'gemini':
		if base_url:
			raise ValueError('Browser Use 的 Gemini adapter 暂不接受自定义 base URL')
		return ChatGoogle(
			model=model,
			api_key=os.environ.get('GOOGLE_API_KEY'),
			temperature=0,
			max_retries=1,
		)
	raise ValueError(f'unsupported provider: {provider}')


async def main() -> None:
	config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
	assert os.environ['ANONYMIZED_TELEMETRY'] == 'false'
	assert os.environ['BROWSER_USE_CLOUD_SYNC'] == 'false'
	assert os.environ['BROWSER_USE_DISABLE_EXTENSIONS'] == '1'
	assert not list(Path.cwd().glob('.env*'))

	from browser_use import Agent, BrowserProfile, BrowserSession

	profile = BrowserProfile(
		executable_path=config['browser_executable'],
		headless=True,
		chromium_sandbox=True,
		disable_security=False,
		use_cloud=False,
		user_data_dir=config['profile_path'],
		keep_alive=True,
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
		agent = Agent(
			task=config['task'],
			llm=build_llm(config),
			browser_session=session,
			use_vision=False,
			use_judge=False,
			use_thinking=False,
			flash_mode=True,
			enable_planning=False,
			max_actions_per_step=1,
			max_failures=2,
			max_history_items=6,
			final_response_after_failure=False,
		)
		history = await agent.run(max_steps=config.get('max_steps', 8))
		state = await session.get_state_as_text()
		usage = history.usage.model_dump(mode='json') if history.usage else None
		result = {
			'version': importlib.metadata.version('browser-use'),
			'url': await session.get_current_page_url(),
			'title': await session.get_current_page_title(),
			'state': state,
			'final_result': history.final_result(),
			'is_done': history.is_done(),
			'is_successful': history.is_successful(),
			'has_errors': history.has_errors(),
			'errors': [error for error in history.errors() if error],
			'actions': history.model_actions(),
			'urls': history.urls(),
			'steps': history.number_of_steps(),
			'model_calls': len(history.model_outputs()),
			'usage': usage,
		}
		print(f"AEGIS_RESULT={json.dumps(result, ensure_ascii=False)}")
	finally:
		await session.stop()


if __name__ == '__main__':
	try:
		asyncio.run(main())
	except Exception as error:
		message = str(error)
		for key_name in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY'):
			secret = os.environ.get(key_name)
			if secret:
				message = message.replace(secret, '[REDACTED]')
		print(f'{type(error).__name__}: {message}', file=sys.stderr)
		raise SystemExit(1) from None
