"""
Porta multiplataforma (Linux + Windows) do controle de PC do projeto original.

Mudanças de segurança em relação ao original:
- Todos os caminhos precisam ficar dentro da pasta home do usuário.
- Ações destrutivas (deletar, limpar pasta, desligar/reiniciar) só funcionam se
  ASSISTENTE_PERMITIR_DESTRUTIVO=1 no .env.
- Abrir programas não usa mais shell=True.
"""

import os
import platform
import shutil
import subprocess
import webbrowser
from pathlib import Path


def _env(nome: str, padrao: str = "") -> str:
    """Lê ASSISTENTE_<nome> (ou o nome antigo JARVIS_<nome>, por compatibilidade)."""
    return os.getenv(f"ASSISTENTE_{nome}") or os.getenv(f"JARVIS_{nome}", padrao)

WINDOWS = platform.system() == "Windows"
LINUX = platform.system() == "Linux"


def _desktop_dir(home: Path) -> Path:
    if LINUX:
        try:
            out = subprocess.run(["xdg-user-dir", "DESKTOP"], capture_output=True, text=True, timeout=2)
            p = Path(out.stdout.strip())
            if out.returncode == 0 and p.is_dir():
                return p
        except Exception:
            pass
    return home / "Desktop"


def _abrir_com_sistema(alvo: str) -> None:
    if WINDOWS:
        os.startfile(alvo)  # type: ignore[attr-defined]
    else:
        subprocess.Popen(["xdg-open", alvo], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class ControlePc:
    IGNORAR = {"venv", ".venv", "env", "node_modules", "__pycache__", ".git", ".idea", ".vscode"}

    LINUX_APPS = {
        "calculadora": ["gnome-calculator"],
        "bloco de notas": ["gnome-text-editor"],
        "editor de texto": ["gnome-text-editor"],
        "terminal": ["gnome-terminal"],
        "explorador de arquivos": ["nautilus"],
        "arquivos": ["nautilus"],
        "configuracoes": ["gnome-control-center"],
        "configurações": ["gnome-control-center"],
        "vscode": ["code"],
        "chrome": ["google-chrome"],
        "spotify": ["spotify"],
    }
    WINDOWS_APPS = {
        "calculadora": "calc.exe",
        "bloco de notas": "notepad.exe",
        "paint": "mspaint.exe",
        "cmd": "cmd.exe",
        "terminal": "wt.exe",
        "explorador de arquivos": "explorer.exe",
        "navegador": "msedge",
        "word": "winword",
        "excel": "excel",
        "powerpoint": "powerpnt",
        "configuracoes": "ms-settings:",
        "configurações": "ms-settings:",
        "vscode": "code",
        "chrome": "chrome",
        "spotify": "spotify:",
    }

    def __init__(self):
        self.home = Path.home().resolve()
        self.desktop = _desktop_dir(self.home)
        self.documents = self.home / "Documents"
        self.downloads = self.home / "Downloads"
        self.base_folders = {
            "area de trabalho": self.desktop,
            "área de trabalho": self.desktop,
            "desktop": self.desktop,
            "documentos": self.documents,
            "documents": self.documents,
            "downloads": self.downloads,
            "home": self.home,
        }
        self.permitir_destrutivo = _env("PERMITIR_DESTRUTIVO", "0") == "1"

    # ── caminhos ───────────────────────────────────────────
    def _resolver(self, caminho: str) -> Path:
        c = caminho.strip("'\"").replace("\\", "/")
        low = c.lower()
        destino = None
        for alias, real in self.base_folders.items():
            if low == alias:
                destino = real
                break
            if low.startswith(alias + "/"):
                destino = real / c[len(alias) + 1 :]
                break
        if destino is None:
            p = Path(c).expanduser()
            destino = p if p.is_absolute() else self.desktop / p
        destino = destino.resolve()
        if destino != self.home and self.home not in destino.parents:
            raise PermissionError(f"Caminho fora da pasta do usuário não é permitido: {destino}")
        return destino

    def _walk(self, base: Path):
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in self.IGNORAR and not d.startswith(".")]
            yield dirpath, dirnames, filenames

    def _bloqueado(self) -> str | None:
        if not self.permitir_destrutivo:
            return ("Ação destrutiva bloqueada. Para permitir, defina ASSISTENTE_PERMITIR_DESTRUTIVO=1 "
                    "no .env do backend.")
        return None

    # ── arquivos e pastas ──────────────────────────────────
    def cria_pasta(self, caminho):
        try:
            p = self._resolver(caminho)
            p.mkdir(parents=True, exist_ok=True)
            return f"Pasta criada com sucesso: {p}"
        except Exception as e:
            return f"Erro ao criar pasta: {e}"

    def abrir_pasta(self, nome_pasta):
        try:
            direto = self.base_folders.get(nome_pasta.lower())
            if direto and direto.exists():
                _abrir_com_sistema(str(direto))
                return f"Abrindo {nome_pasta}."
            for base in {self.desktop, self.documents, self.downloads}:
                for dirpath, dirnames, _ in self._walk(base):
                    for d in dirnames:
                        if d.lower() == nome_pasta.lower():
                            full = os.path.join(dirpath, d)
                            _abrir_com_sistema(full)
                            return f"Pasta encontrada e aberta em: {full}"
            return f"Pasta '{nome_pasta}' não encontrada nos locais padrão."
        except Exception as e:
            return f"Erro ao abrir pasta: {e}"

    def buscar_e_abrir_arquivo(self, nome_arquivo):
        try:
            for base in {self.desktop, self.documents, self.downloads}:
                for dirpath, _, filenames in self._walk(base):
                    for f in filenames:
                        if nome_arquivo.lower() in f.lower():
                            full = os.path.join(dirpath, f)
                            _abrir_com_sistema(full)
                            return f"Arquivo encontrado e aberto: {full}"
            return f"Arquivo '{nome_arquivo}' não encontrado."
        except Exception as e:
            return f"Erro ao buscar/abrir arquivo: {e}"

    def deletar_arquivo(self, caminho):
        if msg := self._bloqueado():
            return msg
        try:
            p = self._resolver(caminho)
            if p == self.home or p in self.base_folders.values():
                return f"Recusado: não vou apagar uma pasta base ({p})."
            if p.is_file():
                p.unlink()
                return f"Arquivo deletado: {p}"
            if p.is_dir():
                shutil.rmtree(p)
                return f"Diretório deletado: {p}"
            return f"Caminho não encontrado: {p}"
        except Exception as e:
            return f"Erro ao deletar: {e}"

    def limpar_diretorio(self, caminho):
        if msg := self._bloqueado():
            return msg
        try:
            p = self._resolver(caminho)
            if p == self.home:
                return "Recusado: não vou limpar a pasta home inteira."
            if not p.is_dir():
                return "Diretório não encontrado."
            for item in p.iterdir():
                shutil.rmtree(item) if item.is_dir() else item.unlink()
            return f"Diretório limpo: {p}"
        except Exception as e:
            return f"Erro ao limpar diretório: {e}"

    def mover_item(self, origem, destino):
        try:
            o, d = self._resolver(origem), self._resolver(destino)
            shutil.move(str(o), str(d))
            return f"Movido de {o} para {d}."
        except Exception as e:
            return f"Erro ao mover: {e}"

    def copiar_item(self, origem, destino):
        try:
            o, d = self._resolver(origem), self._resolver(destino)
            if d.is_dir():
                d = d / o.name
            shutil.copytree(o, d) if o.is_dir() else shutil.copy2(o, d)
            return f"Copiado de {o} para {d}."
        except Exception as e:
            return f"Erro ao copiar: {e}"

    def renomear_item(self, caminho, novo_nome):
        try:
            p = self._resolver(caminho)
            novo = self._resolver(str(p.parent / Path(novo_nome).name))
            p.rename(novo)
            return f"Renomeado para {novo.name}."
        except Exception as e:
            return f"Erro ao renomear: {e}"

    def organizar_pasta(self, caminho):
        try:
            p = self._resolver(caminho)
            ext = {
                "Imagens": [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"],
                "Documentos": [".pdf", ".doc", ".docx", ".txt", ".xlsx", ".pptx", ".csv", ".odt"],
                "Videos": [".mp4", ".mkv", ".avi", ".mov"],
                "Musicas": [".mp3", ".wav", ".flac", ".ogg"],
                "Compactados": [".zip", ".rar", ".7z", ".tar", ".gz"],
                "Executaveis": [".exe", ".msi", ".bat", ".sh", ".appimage", ".deb"],
            }
            for item in p.iterdir():
                if not item.is_file():
                    continue
                pasta = next((k for k, v in ext.items() if item.suffix.lower() in v), "Outros")
                (p / pasta).mkdir(exist_ok=True)
                shutil.move(str(item), str(p / pasta / item.name))
            return "Pasta organizada com sucesso."
        except Exception as e:
            return f"Erro ao organizar pasta: {e}"

    def compactar_pasta(self, caminho):
        try:
            p = self._resolver(caminho)
            shutil.make_archive(str(p), "zip", str(p))
            return f"Compactado em: {p}.zip"
        except Exception as e:
            return f"Erro ao compactar: {e}"

    # ── programas ──────────────────────────────────────────
    def abrir_aplicativo(self, nome_app):
        try:
            chave = nome_app.lower().strip()
            if WINDOWS:
                alvo = self.WINDOWS_APPS.get(chave, nome_app)
                subprocess.Popen(["cmd", "/c", "start", "", alvo])
            else:
                if chave == "navegador":
                    webbrowser.open("https://www.google.com")
                else:
                    cmd = self.LINUX_APPS.get(chave, [chave])
                    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return f"Abrindo {nome_app}."
        except FileNotFoundError:
            return f"Não encontrei o aplicativo '{nome_app}'."
        except Exception as e:
            return f"Erro ao abrir aplicativo: {e}"

    def fechar_programa(self, programa):
        if WINDOWS:
            exe = programa if programa.lower().endswith(".exe") else f"{programa}.exe"
            r = subprocess.run(["taskkill", "/f", "/im", exe], capture_output=True)
        else:
            r = subprocess.run(["pkill", "-i", "-x", programa], capture_output=True)
        return f"Programa '{programa}' fechado." if r.returncode == 0 else f"Não encontrei o processo '{programa}'."

    # ── sistema ────────────────────────────────────────────
    def controle_volume(self, nivel):
        try:
            n = max(0, min(100, int(nivel)))
            if WINDOWS:
                import comtypes
                from pycaw.pycaw import AudioUtilities

                comtypes.CoInitialize()
                AudioUtilities.GetSpeakers().EndpointVolume.SetMasterVolumeLevelScalar(n / 100, None)
            else:
                subprocess.run(["pactl", "set-sink-volume", "@DEFAULT_SINK@", f"{n}%"], check=True)
            return f"Volume ajustado para {n}%."
        except Exception as e:
            return f"Erro ao ajustar volume: {e}"

    def controle_brilho(self, nivel):
        try:
            n = max(1, min(100, int(nivel)))
            if WINDOWS:
                import screen_brightness_control as sbc

                sbc.set_brightness(n)
            else:
                subprocess.run(["brightnessctl", "set", f"{n}%"], check=True, capture_output=True)
            return f"Brilho ajustado para {n}%."
        except Exception as e:
            return f"Erro ao ajustar brilho: {e}"

    def energia_pc(self, acao):
        acao = acao.lower().strip()
        try:
            if acao == "bloquear":
                if WINDOWS:
                    subprocess.run(["rundll32.exe", "user32.dll,LockWorkStation"])
                else:
                    subprocess.run(["loginctl", "lock-session"])
                return "Computador bloqueado."
            if acao not in ("desligar", "reiniciar"):
                return "Ação inválida."
            if msg := self._bloqueado():
                return msg
            if WINDOWS:
                subprocess.run(["shutdown", "/s" if acao == "desligar" else "/r", "/t", "5"])
            else:
                subprocess.run(["systemctl", "poweroff" if acao == "desligar" else "reboot"])
            return "Desligando o computador." if acao == "desligar" else "Reiniciando o computador."
        except Exception as e:
            return f"Erro: {e}"
