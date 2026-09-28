"""Register local Qdrant and an SSH tunnel to the existing remote BGE-M3 API."""

from pathlib import Path
import plistlib
import subprocess


ROOT = Path(__file__).resolve().parents[1]
AGENTS = Path.home() / "Library" / "LaunchAgents"
LOGS = ROOT / ".data" / "logs"
QDRANT = Path.home() / ".local" / "opt" / "qdrant" / "1.19.1" / "qdrant"
API_UVICORN = Path.home() / ".local" / "opt" / "dean-agent" / "venv" / "bin" / "uvicorn"


def install(label: str, arguments: list[str]) -> None:
    path = AGENTS / f"{label}.plist"
    data = {
        "Label": label,
        "ProgramArguments": arguments,
        "WorkingDirectory": str(ROOT),
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(LOGS / f"{label}.out.log"),
        "StandardErrorPath": str(LOGS / f"{label}.err.log"),
    }
    path.write_bytes(plistlib.dumps(data))
    domain = f"gui/{subprocess.check_output(['id', '-u'], text=True).strip()}"
    subprocess.run(["launchctl", "bootout", domain, str(path)], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", domain, str(path)], check=True)
    print(f"Started {label}")


def main() -> None:
    if not QDRANT.is_file():
        raise SystemExit(f"Qdrant binary missing: {QDRANT}")
    if not API_UVICORN.is_file():
        raise SystemExit(f"API runtime missing: {API_UVICORN}")
    AGENTS.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    install("org.dean-agent.qdrant", [str(QDRANT), "--config-path",
                                       str(ROOT / "config" / "qdrant.yaml"),
                                       "--disable-telemetry"])
    install("org.dean-agent.bge-tunnel", ["/usr/bin/ssh", "-N", "-T",
                                           "-o", "BatchMode=yes",
                                           "-o", "ExitOnForwardFailure=yes",
                                           "-o", "ServerAliveInterval=30",
                                           "-o", "ServerAliveCountMax=3",
                                           "-L", "127.0.0.1:8231:127.0.0.1:8231",
                                           "mlspace"])
    install("org.dean-agent.api", [str(API_UVICORN),
                                   "dean_agent.api:app", "--host", "127.0.0.1",
                                   "--port", "8080"])


if __name__ == "__main__":
    main()
