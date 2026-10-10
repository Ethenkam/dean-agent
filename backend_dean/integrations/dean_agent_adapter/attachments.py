"""Read only immutable versions bound by the backend to this trusted run."""
import hashlib
import json
from uuid import UUID

from dean_agent.attachments import MAX_BYTES, image_block, pdf_images
from .security import sign


class AttachmentContextError(ValueError):
    pass


class AttachmentReader:
    def __init__(self, http, backend, secret, claims):
        self.http, self.backend, self.secret, self.claims = http, backend, secret, claims
        self.versions = {}

    def get(self, suffix='', *, params=None, binary=False):
        token = sign(self.secret, self.claims, 'deanery-attachments', 60)
        with self.http.stream('GET', self.backend + '/api/v1/internal/agent/attachments' + suffix,
                              headers={'X-Delegation': token}, params=params) as response:
            response.raise_for_status()
            limit = MAX_BYTES if binary else 1_000_000
            raw = bytearray()
            for chunk in response.iter_bytes():
                raw.extend(chunk)
                if len(raw) > limit:
                    raise AttachmentContextError('Attachment response too large')
        return bytes(raw) if binary else json.loads(raw)

    def text(self, version_id, offset=0, limit=20):
        version_id = str(UUID(version_id))
        if version_id not in self.versions or type(offset) is not int or not 0 <= offset <= 10000 or type(limit) is not int or not 1 <= limit <= 50:
            raise AttachmentContextError('Attachment is not bound to this request or pagination is invalid')
        value = self.get('/' + version_id + '/text', params={'offset': offset, 'limit': limit})
        if value.get('version_id') != version_id or not isinstance(value.get('chunks'), list) or len(value['chunks']) > limit:
            raise AttachmentContextError('Invalid attachment text response')
        return value

    def download(self, item):
        raw = self.get('/' + item['version_id'] + '/download', binary=True)
        if len(raw) != item['byte_size'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise AttachmentContextError('Original size or checksum mismatch')
        return raw

    def prepare(self, references):
        context = self.get()
        if context.get('backend_run_id') != self.claims['run'] or context.get('session_id') != self.claims['session']:
            raise AttachmentContextError('Attachment run mismatch')
        items = context.get('attachments', [])
        expected = [(r['file_id'], r['version_id']) for r in references]
        if [(i['file_id'], i['version_id']) for i in items] != expected or len(items) > 5 or sum(i['byte_size'] for i in items) > MAX_BYTES:
            raise AttachmentContextError('Attachment references mismatch')
        self.versions = {i['version_id']: i for i in items}
        prepared = []
        for item in items:
            entry = {**item, 'text': '', 'blocks': []}
            if item['text_available']:
                value = self.text(item['version_id'])
                entry['text'] = '\n\n'.join(f"Страница {c['page']}, фрагмент {c['ordinal']}:\n{c['text']}" for c in value['chunks'])
                entry['next_offset'] = value.get('next_offset')
            if item['mime'].startswith('image/'):
                entry['blocks'] = [image_block(self.download(item), item['mime'])]
            elif item['mime'] == 'application/pdf' and (not item['text_available'] or (item.get('quality') or {}).get('images_not_extracted')):
                blocks, count = pdf_images(self.download(item))
                entry['blocks'] = blocks
                entry['visual_pages'] = min(count, 10)
                entry['visual_truncated'] = count > 10
            elif item['mime'] == 'text/csv' and not item['text_available']:
                raw = self.download(item)
                entry['text'] = raw.decode('utf-8-sig')[:60_000]
                entry['text_truncated'] = len(raw.decode('utf-8-sig')) > 60_000
            prepared.append(entry)
        return prepared
