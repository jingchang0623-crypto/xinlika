"""Configurable, authorized OpenAI-compatible ASR; no vendor input-method protocol."""
import importlib.util
import os
from pathlib import Path
from urllib.parse import urlparse
from openai import OpenAI


class CompatibleASR:
    def __init__(self, config):
        address = urlparse(config['base_url'])
        if address.username or address.password or address.query or address.fragment:
            raise ValueError('ASR endpoint must not embed credentials, query or fragment')
        if not address.hostname or not (address.scheme == 'https' or address.scheme == 'http' and address.hostname in {'127.0.0.1', 'localhost', '::1'}):
            raise ValueError('ASR requires HTTPS or loopback HTTP')
        if 'api_key_env' in config:
            key = os.environ[config['api_key_env']]
        elif 'api_key_file' in config:
            key = Path(config['api_key_file']).expanduser().read_text().strip()
        else:
            raise ValueError('ASR needs api_key_env or api_key_file')
        self.client = OpenAI(base_url=config['base_url'], api_key=key, timeout=330, max_retries=0)
        self.model = config['model']
        self.format = config.get('response_format', 'json')
        if self.format not in {'json', 'verbose_json'}:
            raise ValueError('ASR must return json or verbose_json with a text field')
        self.language = config.get('language')
        self.provider = 'compatible-asr:' + self.model
        spec = importlib.util.spec_from_file_location('xinlika_cb08_codec', Path(__file__).with_name('analyze-cb08-capture.py'))
        self.codec = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.codec)

    def transcribe(self, raw, destination):
        # The current ingestion contract is CB08 40-byte Opus frames; do not
        # label arbitrary files as this format. Reuse the strict Ogg wrapper.
        ogg = destination.with_suffix('.ogg')
        if not ogg.exists():
            self.codec.wrap_cb08(raw, ogg)
            ogg.chmod(0o600)
        options = {'model': self.model, 'response_format': self.format}
        if self.language:
            options['language'] = self.language
        with ogg.open('rb') as source:
            value = self.client.audio.transcriptions.create(file=('audio.ogg', source, 'audio/ogg'), **options)
        data = value.model_dump()
        if not isinstance(data.get('text'), str):
            raise ValueError('ASR did not return a text field')
        return {'text': data['text'], 'segments': data.get('segments') or [], 'provider': self.provider,
                'timing_precision': 'provider_segments_not_verified_word_alignment', 'raw_response': data}
