import io
import logging
import uuid
import zipfile
from xml.etree import ElementTree

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from pypdf import PdfReader
from sqlalchemy import text

from dean_agent.agent import ask_agent
from dean_agent.config import settings
from dean_agent.db import SessionLocal, engine
from dean_agent.models import AuditLog, ChangeProposal, Regulation, RegulationChunk
from dean_agent.services import ProposalError, resolve_proposal
from dean_agent.vector_search import index_regulation, qdrant_client


app = FastAPI(title="Dean Agent API", version="0.1.0")
logger = logging.getLogger(__name__)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=8000)


class DecisionRequest(BaseModel):
    approve: bool


@app.get("/health")
def health() -> dict:
    with engine.connect() as connection:
        connection.execute(text("SELECT 1"))
    return {"status": "ok", "database": "postgresql"}


@app.get("/health/vector")
def vector_health() -> dict:
    try:
        client = qdrant_client()
        try:
            client.get_collections()
        finally:
            client.close()
        with httpx.Client(trust_env=False, timeout=5) as http:
            response = http.get(f"{settings.bge_m3_url.rstrip('/')}/health")
            response.raise_for_status()
            bge = response.json().get("status")
    except Exception as exc:
        raise HTTPException(503, f"Векторный поиск недоступен: {type(exc).__name__}") from exc
    if bge != "ok":
        raise HTTPException(503, "BGE-M3 ещё загружается")
    return {"status": "ok", "qdrant": "local", "bge_m3": "remote via SSH tunnel"}


@app.post("/chat")
def chat(body: ChatRequest, x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    if settings.openai_model == "your-tool-calling-model":
        raise HTTPException(503, "Настройте OPENAI_MODEL в .env")
    try:
        return ask_agent(body.message, x_actor_id)
    except Exception as exc:
        # Do not expose provider credentials or database connection details.
        raise HTTPException(502, f"Агент не ответил: {type(exc).__name__}") from exc


@app.get("/proposals/{proposal_id}")
def get_proposal(proposal_id: uuid.UUID, x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    with SessionLocal() as db:
        proposal = db.get(ChangeProposal, proposal_id)
        if proposal is None:
            raise HTTPException(404, "Предложение не найдено")
        return {"id": str(proposal.id), "student_id": proposal.student_id, "field": proposal.field,
                "old": proposal.old_value, "new": proposal.new_value, "status": proposal.status,
                "created_by": proposal.actor_id}


@app.post("/proposals/{proposal_id}/decision")
def decide(proposal_id: uuid.UUID, body: DecisionRequest,
           x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    with SessionLocal() as db:
        try:
            proposal = resolve_proposal(db, proposal_id, x_actor_id, body.approve)
        except ProposalError as exc:
            db.rollback()
            raise HTTPException(409, str(exc)) from exc
        return {"id": str(proposal.id), "status": proposal.status}


def chunks_from_upload(filename: str, data: bytes) -> list[tuple[int | None, str]]:
    if filename.lower().endswith(".pdf"):
        reader = PdfReader(io.BytesIO(data))
        pages = [(i + 1, page.extract_text() or "") for i, page in enumerate(reader.pages)]
    elif filename.lower().endswith(".txt"):
        pages = [(None, data.decode("utf-8"))]
    elif filename.lower().endswith(".docx"):
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                with archive.open("word/document.xml") as document:
                    xml = document.read(20_000_001)
            if len(xml) > 20_000_000:
                raise HTTPException(413, "Слишком большой текст внутри DOCX")
            root = ElementTree.fromstring(xml)
            namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
            paragraphs = ["".join(node.text or "" for node in paragraph.findall(".//w:t", namespace))
                          for paragraph in root.findall(".//w:p", namespace)]
        except (zipfile.BadZipFile, KeyError, ElementTree.ParseError) as exc:
            raise HTTPException(422, "Не удалось прочитать DOCX") from exc
        pages = [(None, "\n".join(paragraphs))]
    else:
        raise HTTPException(415, "Поддерживаются PDF, DOCX и UTF-8 TXT")
    chunks = []
    for page, content in pages:
        content = " ".join(content.split())
        for start in range(0, len(content), 1200):
            part = content[start:start + 1200]
            if part.strip():
                chunks.append((page, part))
    if not chunks:
        raise HTTPException(422, "Текст не найден; для сканов нужен OCR")
    return chunks


@app.post("/regulations")
async def upload_regulation(file: UploadFile = File(...),
                            title: str | None = Form(default=None, max_length=255),
                            source: str | None = Form(default=None, max_length=512),
                            x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    data = await file.read(10_000_001)
    if len(data) > 10_000_000:
        raise HTTPException(413, "Максимальный размер 10 МБ")
    filename = (file.filename or "document").split("/")[-1].split("\\")[-1]
    try:
        chunks = chunks_from_upload(filename, data)
    except (UnicodeDecodeError, ValueError) as exc:
        raise HTTPException(422, "Не удалось прочитать документ") from exc
    with SessionLocal() as db:
        doc = Regulation(title=title or filename, source=source or filename, content="")
        db.add(doc)
        db.flush()
        db.add_all(RegulationChunk(regulation_id=doc.id, page=page, content=content)
                   for page, content in chunks)
        db.add(AuditLog(actor_id=x_actor_id, agent_run_id="manual-upload",
                        action="upload_regulation", entity_type="regulation",
                        entity_id=str(doc.id), old_value=None,
                        new_value={"title": doc.title, "source": doc.source, "chunks": len(chunks)}))
        db.commit()
        doc_id = doc.id
        doc_title = doc.title
    try:
        index_regulation(doc_id)
    except Exception as exc:
        logger.exception("Failed to index regulation %s", doc_id)
        with SessionLocal.begin() as db:
            db.get(Regulation, doc_id).index_status = "failed"
        return JSONResponse(status_code=202, content={
            "id": doc_id, "title": doc_title, "chunks": len(chunks),
            "index_status": "failed", "error_type": type(exc).__name__,
        })
    return {"id": doc_id, "title": doc_title, "chunks": len(chunks), "index_status": "ready"}


@app.get("/regulations/{regulation_id}")
def get_regulation(regulation_id: int, x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    with SessionLocal() as db:
        doc = db.get(Regulation, regulation_id)
        if doc is None:
            raise HTTPException(404, "Документ не найден")
        return {"id": doc.id, "title": doc.title, "source": doc.source,
                "index_status": doc.index_status}


@app.post("/regulations/{regulation_id}/reindex")
def reindex_regulation(regulation_id: int,
                       x_actor_id: str = Header(min_length=1, max_length=128)) -> dict:
    with SessionLocal() as db:
        if db.get(Regulation, regulation_id) is None:
            raise HTTPException(404, "Документ не найден")
    try:
        count = index_regulation(regulation_id)
    except Exception as exc:
        logger.exception("Failed to reindex regulation %s", regulation_id)
        with SessionLocal.begin() as db:
            db.get(Regulation, regulation_id).index_status = "failed"
        raise HTTPException(503, f"Индексация не удалась: {type(exc).__name__}") from exc
    return {"id": regulation_id, "index_status": "ready", "chunks": count}
