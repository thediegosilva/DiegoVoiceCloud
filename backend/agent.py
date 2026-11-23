"""
Agente Jarvis unificado (modo LiveKit do app Flutter).

Junta o que estava espalhado no projeto antigo:
- Jarvis- Aula 01      → persona + Gemini Realtime + cancelamento de ruído
- Jarvis Mem0          → memória de longo prazo
- Controle_PC / HOME   → ferramentas de PC (agora Linux + Windows) e casa (Voice Monkey)

Rodar:  python agent.py dev
"""

import asyncio
import logging
import os
import webbrowser
from urllib.parse import quote_plus

from dotenv import load_dotenv
from livekit import agents
from livekit.agents import Agent, AgentSession, ChatContext, function_tool
from livekit.agents.voice import room_io
from livekit.plugins import google, noise_cancellation

from pc_control import JarvisControl
from prompts import AGENT_INSTRUCTION, SESSION_INSTRUCTION

load_dotenv()

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("jarvis")

USER_ID = os.getenv("JARVIS_USER_ID", "PedroLucas")
MEM0_ATIVO = bool(os.getenv("MEM0_API_KEY"))
VOICEMONKEY_ATIVO = bool(os.getenv("VOICEMONKEY_TOKEN") or os.getenv("VOICEMONKEY_ACCESS_TOKEN"))

_voicemonkey = None


def get_voicemonkey():
    global _voicemonkey
    if _voicemonkey is None:
        from voicemonkey import VoiceMonkey

        _voicemonkey = VoiceMonkey()
    return _voicemonkey


class Assistant(Agent):
    def __init__(self, chat_ctx: ChatContext | None = None):
        super().__init__(
            instructions=AGENT_INSTRUCTION,
            llm=google.realtime.RealtimeModel(
                voice=os.getenv("JARVIS_VOICE", "Charon"),
                temperature=0.6,
            ),
            chat_ctx=chat_ctx,
        )
        self.pc = JarvisControl()

    async def _run(self, fn, *args):
        """As funções de PC são bloqueantes: roda fora do event loop."""
        return await asyncio.to_thread(fn, *args)

    # ── Web ───────────────────────────────────────────────
    @function_tool
    async def pesquisar_na_web(self, consulta: str, tipo: str = "google") -> str:
        """Faz uma busca no Google, abre a busca do YouTube ou abre uma URL no navegador do PC.

        Args:
            consulta: termo de busca ou URL
            tipo: 'google' (padrão), 'youtube' ou 'url'
        """
        t = tipo.lower()
        if t == "youtube":
            url = f"https://www.youtube.com/results?search_query={quote_plus(consulta)}"
        elif t == "url":
            url = consulta if consulta.startswith("http") else f"https://{consulta}"
        else:
            url = f"https://www.google.com/search?q={quote_plus(consulta)}"
        await self._run(webbrowser.open, url)
        return f"Abrindo {url}"

    # ── Programas ─────────────────────────────────────────
    @function_tool
    async def abrir_aplicativo(self, nome_app: str) -> str:
        """Abre um aplicativo pelo nome (ex: 'calculadora', 'vscode', 'spotify', 'terminal')."""
        return await self._run(self.pc.abrir_aplicativo, nome_app)

    @function_tool
    async def fechar_programa(self, programa: str) -> str:
        """Fecha um programa pelo nome do processo (ex: 'chrome', 'spotify')."""
        return await self._run(self.pc.fechar_programa, programa)

    # ── Arquivos e pastas ─────────────────────────────────
    @function_tool
    async def criar_pasta(self, caminho: str) -> str:
        """Cria uma pasta. Caminhos relativos ficam na Área de Trabalho (ex: 'Projetos/Python', 'documentos/Notas')."""
        return await self._run(self.pc.cria_pasta, caminho)

    @function_tool
    async def deletar_item(self, caminho: str) -> str:
        """Deleta um arquivo ou pasta pelo caminho."""
        return await self._run(self.pc.deletar_arquivo, caminho)

    @function_tool
    async def limpar_diretorio(self, caminho: str) -> str:
        """Remove todo o conteúdo de uma pasta, sem deletar a pasta em si."""
        return await self._run(self.pc.limpar_diretorio, caminho)

    @function_tool
    async def mover_item(self, origem: str, destino: str) -> str:
        """Move um arquivo ou pasta de origem para destino."""
        return await self._run(self.pc.mover_item, origem, destino)

    @function_tool
    async def copiar_item(self, origem: str, destino: str) -> str:
        """Copia um arquivo ou pasta para um novo local."""
        return await self._run(self.pc.copiar_item, origem, destino)

    @function_tool
    async def renomear_item(self, caminho: str, novo_nome: str) -> str:
        """Renomeia um arquivo ou pasta."""
        return await self._run(self.pc.renomear_item, caminho, novo_nome)

    @function_tool
    async def organizar_pasta(self, caminho: str) -> str:
        """Organiza os arquivos de uma pasta por tipo (Imagens, Documentos, etc.)."""
        return await self._run(self.pc.organizar_pasta, caminho)

    @function_tool
    async def compactar_pasta(self, caminho: str) -> str:
        """Compacta uma pasta em um arquivo .zip."""
        return await self._run(self.pc.compactar_pasta, caminho)

    @function_tool
    async def abrir_pasta(self, nome_pasta: str) -> str:
        """Abre uma pasta no gerenciador de arquivos pelo nome."""
        return await self._run(self.pc.abrir_pasta, nome_pasta)

    @function_tool
    async def buscar_e_abrir_arquivo(self, nome_arquivo: str) -> str:
        """Busca um arquivo por nome (Área de Trabalho, Documentos, Downloads) e o abre."""
        return await self._run(self.pc.buscar_e_abrir_arquivo, nome_arquivo)

    # ── Sistema ───────────────────────────────────────────
    @function_tool
    async def controle_volume(self, nivel: int) -> str:
        """Ajusta o volume do sistema de 0 a 100."""
        return await self._run(self.pc.controle_volume, nivel)

    @function_tool
    async def controle_brilho(self, nivel: int) -> str:
        """Ajusta o brilho da tela de 0 a 100."""
        return await self._run(self.pc.controle_brilho, nivel)

    @function_tool
    async def energia_pc(self, acao: str) -> str:
        """Controla a energia do PC. Ações: 'desligar', 'reiniciar', 'bloquear'."""
        return await self._run(self.pc.energia_pc, acao)

    # ── Casa inteligente ──────────────────────────────────
    @function_tool
    async def controlar_casa(self, dispositivo: str, acao: str = "ligar") -> str:
        """Controla dispositivos inteligentes da casa (luzes, ventilador, ar-condicionado, tomada)
        via Voice Monkey + Alexa. Use quando o usuário pedir para ligar ou desligar algo em casa.

        Args:
            dispositivo: nome do dispositivo (ex: 'ventilador', 'luz', 'ar')
            acao: 'ligar' (padrão) ou 'desligar'
        """
        if not VOICEMONKEY_ATIVO:
            return "Voice Monkey não configurado no .env do backend."
        vm = get_voicemonkey()
        base = dispositivo.lower().replace(" ", "")
        ligar = acao.lower().strip() != "desligar"
        if ligar:
            variacoes = [f"ligar-{base}", f"ligar{base}", base, f"{base}-on", f"{base}-ligar", f"ligar_{base}"]
        else:
            variacoes = [f"desligar-{base}", f"desligar{base}", f"{base}-off", f"{base}-desligar", f"desligar_{base}"]
        for tentativa in variacoes:
            resultado = await asyncio.to_thread(vm.trigger_monkey, tentativa)
            if "sucesso" in resultado:
                return f"Comando executado para '{dispositivo}' (ID: {tentativa})."
        return f"Não consegui controlar {dispositivo}. Tentei: {', '.join(variacoes)}."


async def _carregar_memorias(mem0) -> str | None:
    try:
        response = await mem0.search(
            query="histórico, preferências e informações pessoais do usuário",
            filters={"user_id": USER_ID},
            limit=20,
        )
        results = response.get("results", []) if isinstance(response, dict) else (response or [])
        memorias = [
            f"- {r.get('memory') or r.get('text') or r.get('content')}"
            for r in results
            if isinstance(r, dict) and (r.get("memory") or r.get("text") or r.get("content"))
        ]
        logger.info(f"[Mem0] {len(memorias)} memórias carregadas.")
        return "\n".join(memorias) if memorias else None
    except Exception as e:
        logger.error(f"[Mem0] Erro ao carregar memória: {e}")
        return None


async def entrypoint(ctx: agents.JobContext):
    mem0 = None
    initial_ctx = ChatContext()
    if MEM0_ATIVO:
        from mem0 import AsyncMemoryClient

        mem0 = AsyncMemoryClient()
        bloco = await _carregar_memorias(mem0)
        if bloco:
            initial_ctx.add_message(
                role="assistant",
                content=f"O nome do usuário é {USER_ID}.\n[Memória carregada — informações sobre o usuário]\n{bloco}",
            )

    await ctx.connect()

    session = AgentSession()
    await session.start(
        room=ctx.room,
        agent=Assistant(chat_ctx=initial_ctx),
        room_options=room_io.RoomOptions(
            audio_input=room_io.AudioInputOptions(noise_cancellation=noise_cancellation.BVC()),
            video_input=True,
        ),
    )

    async def salvar_memoria():
        if mem0 is None:
            return
        try:
            msgs = []
            for item in session.history.items:
                if getattr(item, "role", None) not in ("user", "assistant") or not getattr(item, "content", None):
                    continue
                texto = "".join(c for c in item.content if isinstance(c, str)).strip()
                if texto and "[Memória carregada" not in texto:
                    msgs.append({"role": item.role, "content": texto})
            if msgs:
                await mem0.add(msgs, user_id=USER_ID)
                logger.info(f"[Mem0] {len(msgs)} mensagens salvas.")
        except Exception as e:
            logger.warning(f"[Mem0] Erro ao salvar memória: {e}")

    ctx.add_shutdown_callback(salvar_memoria)

    await session.generate_reply(
        instructions=SESSION_INSTRUCTION + "\nCumprimente o usuário de forma breve e confiante."
    )


if __name__ == "__main__":
    agents.cli.run_app(agents.WorkerOptions(entrypoint_fnc=entrypoint))
