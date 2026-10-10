import io
import json
import zipfile

from fastapi.testclient import TestClient
from PIL import Image
import pymupdf
import pytest

from dean_agent.api import app
from dean_agent.attachments import AttachmentError, image_block, prepare_upload, user_content


def image_bytes(format='PNG'):
    output = io.BytesIO()
    Image.new('RGB', (30, 20), 'red').save(output, format=format)
    return output.getvalue()


def test_document_text_and_image_are_distinct_model_blocks():
    doc = prepare_upload('заявление.txt', 'Прошу академический отпуск'.encode())
    photo = prepare_upload('фото.png', image_bytes())
    content, history = user_content('Проверь заявление', [doc, photo])
    assert any('Прошу академический отпуск' in b.get('text', '') for b in content)
    assert any(b['type'] == 'image_url' for b in content)
    assert 'data:image/' not in history
    assert 'фото.png' in history


@pytest.mark.parametrize('filename,data', [('bad.png', b'not-image'), ('bad.txt', b'\x00'), ('bad.txt', b'\xff'), ('bad.exe', b'file')])
def test_invalid_attachments_fail(filename, data):
    with pytest.raises(AttachmentError):
        prepare_upload(filename, data)


def test_docx_table_text_is_included():
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as z:
        z.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Иванов</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>')
    assert prepare_upload('x.docx', output.getvalue())['text'] == 'Иванов'


def test_scan_pdf_is_visual_and_page_limit_is_explicit():
    with pymupdf.open() as pdf:
        for _ in range(11):
            pdf.new_page(width=100, height=100).insert_image(pymupdf.Rect(0, 0, 100, 100), stream=image_bytes())
        doc = prepare_upload('scan.pdf', pdf.tobytes())
    assert sum(b['type'] == 'image_url' for b in doc['blocks']) == 10
    assert doc['quality']['incomplete_extraction'] is True
    assert doc['quality']['total_pages'] == 11


def test_forged_image_mime_and_animated_image_fail():
    with pytest.raises(AttachmentError):
        image_block(image_bytes(), 'image/jpeg')
    output = io.BytesIO()
    Image.new('RGB', (10, 10), 'red').save(output, format='PNG', save_all=True, append_images=[Image.new('RGB', (10, 10), 'blue')])
    with pytest.raises(AttachmentError):
        image_block(output.getvalue(), 'image/png')


@pytest.mark.parametrize('stream', [False, True])
def test_multipart_passes_prepared_attachments_and_preserves_response(monkeypatch, stream):
    captured = []
    def fake(message, actor_id, session_id, trace_callback=None, attachments=None):
        captured.extend(attachments)
        return {'run_id': 'run', 'session_id': 'session', 'answer': 'OK', 'proposals': [], 'tools_used': []}
    monkeypatch.setattr('dean_agent.api.ask_agent', fake)
    response = TestClient(app).post('/chat/files' + ('/stream' if stream else ''),
        headers={'X-Actor-ID': 'staff'}, data={'message': 'Прочитай'},
        files=[('files', ('x.txt', b'hello', 'text/plain')), ('files', ('x.png', image_bytes(), 'image/png'))])
    assert response.status_code == 200
    assert captured[0]['text'] == 'hello' and captured[1]['blocks'][0]['type'] == 'image_url'
    if stream:
        assert 'event: done' in response.text
    else:
        assert response.json()['answer'] == 'OK'


def test_file_count_and_size_rejected_before_model(monkeypatch):
    def fail(*args, **kwargs):
        pytest.fail('Model must not be invoked')
    monkeypatch.setattr('dean_agent.api.ask_agent', fail)
    client = TestClient(app)
    args = dict(headers={'X-Actor-ID': 'staff'}, data={'message': 'Прочитай'})
    assert client.post('/chat/files', files=[('files', ('x.txt', b'hello'))] * 6, **args).status_code == 422
    assert client.post('/chat/files', files=[('files', ('x.txt', b'x' * 10_000_001))], **args).status_code == 413


def test_direct_json_does_not_silently_drop_file_references():
    response = TestClient(app).post('/chat', headers={'X-Actor-ID': 'staff'},
        json={'message': 'Read', 'attachments': [{'file_id': 'untrusted', 'version_id': 'untrusted'}]})
    assert response.status_code == 422
