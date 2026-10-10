import hashlib
import json
from uuid import uuid4

import httpx
import pytest

from integrations.dean_agent_adapter.attachments import AttachmentContextError, AttachmentReader
from integrations.dean_agent_adapter.security import verify
from deanery_api.storage import validate_document, parse_document
from deanery_api.errors import ApiError

SECRET = 'attachment-test-delegation-key-not-production'


def reader_with(handler):
    claims = {'user': 1, 'run': str(uuid4()), 'session': str(uuid4()), 'auth_session': str(uuid4())}
    return AttachmentReader(httpx.Client(transport=httpx.MockTransport(handler)), 'http://backend', SECRET, claims)


def test_each_read_has_fresh_signed_nonce_and_bound_claims():
    requests = []
    version = str(uuid4())
    def handle(request):
        claims = verify(SECRET, request.headers['x-delegation'], 'deanery-attachments')
        requests.append(claims)
        assert request.url.params['offset'] == '20'
        return httpx.Response(200, json={'version_id': version, 'chunks': [], 'next_offset': None})
    reader = reader_with(handle)
    reader.versions[version] = {}
    reader.text(version, 20)
    reader.text(version, 20)
    assert requests[0]['nonce'] != requests[1]['nonce']
    assert all(r['run'] == reader.claims['run'] and r['auth_session'] == reader.claims['auth_session'] for r in requests)
    reader.http.close()


def test_foreign_version_and_invalid_pagination_do_not_fetch():
    def handle(request): pytest.fail('Must reject before HTTP')
    reader = reader_with(handle)
    version = str(uuid4()); reader.versions[version] = {}
    for arguments in [(str(uuid4()), 0, 20), (version, -1, 20), (version, 0, 51), (version, True, 20)]:
        with pytest.raises(AttachmentContextError): reader.text(*arguments)
    reader.http.close()


def test_original_checksum_mismatch_is_rejected():
    reader = reader_with(lambda r: httpx.Response(200, content=b'changed'))
    with pytest.raises(AttachmentContextError):
        reader.download({'version_id': str(uuid4()), 'byte_size': 7, 'sha256': hashlib.sha256(b'original').hexdigest()})
    reader.http.close()


def test_wrong_run_context_is_rejected():
    reader = reader_with(lambda r: httpx.Response(200, json={'backend_run_id': str(uuid4()), 'session_id': str(uuid4()), 'attachments': []}))
    with pytest.raises(AttachmentContextError): reader.prepare([])
    reader.http.close()


def test_photo_validation_and_no_fake_ocr():
    from PIL import Image
    import io
    output = io.BytesIO(); Image.new('RGB', (30, 20), 'red').save(output, format='PNG')
    raw = output.getvalue()
    assert validate_document('photo.png', 'image/png', raw) == 'image/png'
    value = parse_document('photo.png', raw)
    assert value['chunks'] == [] and value['quality']['ocr_performed'] is False
    assert value['quality']['incomplete_extraction'] is True
    with pytest.raises(ApiError): validate_document('photo.jpg', 'image/jpeg', raw)
    with pytest.raises(ApiError): validate_document('photo.png', 'image/png', b'fake')
