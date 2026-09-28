"""Document formats accepted by the regulation upload endpoint."""

import io
import zipfile

import pytest
from fastapi import HTTPException

from dean_agent.api import chunks_from_upload


def test_docx_text_is_extracted_for_search():
    document = io.BytesIO()
    with zipfile.ZipFile(document, "w") as archive:
        archive.writestr("word/document.xml", """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Академический </w:t></w:r><w:r><w:t>отпуск</w:t></w:r></w:p>
            <w:p><w:r><w:t>Заявление обучающегося</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """)
    chunks = chunks_from_upload("положение.docx", document.getvalue())
    assert chunks == [(None, "Академический отпуск Заявление обучающегося")]


def test_invalid_docx_is_rejected():
    with pytest.raises(HTTPException) as error:
        chunks_from_upload("положение.docx", b"invalid")
    assert error.value.status_code == 422
