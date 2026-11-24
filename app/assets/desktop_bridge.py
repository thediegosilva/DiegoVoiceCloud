#!/usr/bin/env python3
"""
Ponte de tela/controle da IA para Linux (Wayland/GNOME) via portais XDG.

- Modo "view":    portal ScreenCast       → só vê a tela.
- Modo "control": portal RemoteDesktop    → vê a tela + mouse e teclado.

Na primeira vez o GNOME mostra um diálogo pedindo permissão; a escolha fica
salva (restore_token) e nas próximas vezes não pergunta de novo.

Protocolo (JSON por linha):
  stdout → {"type":"ready","w":..,"h":..} | {"type":"frame","data":b64jpeg}
           {"type":"result","id":..,"ok":bool,"msg":".."} | {"type":"error","msg":".."}
  stdin  ← {"id":..,"cmd":"click","x":0-1000,"y":0-1000,"button":"left|right|middle","double":bool}
           {"id":..,"cmd":"move","x":..,"y":..}
           {"id":..,"cmd":"type","text":".."}
           {"id":..,"cmd":"key","combo":"ctrl+c"}
           {"id":..,"cmd":"scroll","dir":"down|up","amount":3}
           {"cmd":"stop"}
Coordenadas x/y são normalizadas de 0 a 1000 sobre a imagem enviada.
"""
import argparse
import base64
import json
import os
import sys
import threading
import time

import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst  # noqa: E402

PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
RD_IFACE = "org.freedesktop.portal.RemoteDesktop"
SC_IFACE = "org.freedesktop.portal.ScreenCast"
REQ_IFACE = "org.freedesktop.portal.Request"

CONFIG_DIR = os.path.join(os.path.expanduser("~"), ".config", "assistente-desktop")

BUTTONS = {"left": 272, "esquerdo": 272, "right": 273, "direito": 273, "middle": 274, "meio": 274}

KEYSYMS = {
    "ctrl": 0xFFE3, "control": 0xFFE3, "shift": 0xFFE1, "alt": 0xFFE9, "altgr": 0xFE03,
    "super": 0xFFEB, "win": 0xFFEB, "meta": 0xFFEB,
    "enter": 0xFF0D, "return": 0xFF0D, "tab": 0xFF09, "esc": 0xFF1B, "escape": 0xFF1B,
    "backspace": 0xFF08, "apagar": 0xFF08, "delete": 0xFFFF, "del": 0xFFFF,
    "space": 0x20, "espaco": 0x20, "espaço": 0x20,
    "up": 0xFF52, "cima": 0xFF52, "down": 0xFF54, "baixo": 0xFF54,
    "left": 0xFF51, "esquerda": 0xFF51, "right": 0xFF53, "direita": 0xFF53,
    "home": 0xFF50, "end": 0xFF57, "pageup": 0xFF55, "pagedown": 0xFF56,
    "insert": 0xFF63, "printscreen": 0xFF61, "print": 0xFF61,
}
for _n in range(1, 13):
    KEYSYMS[f"f{_n}"] = 0xFFBE + _n - 1


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def char_keysym(c):
    if c == "\n":
        return 0xFF0D
    if c == "\t":
        return 0xFF09
    o = ord(c)
    if 0x20 <= o <= 0x7E or 0xA0 <= o <= 0xFF:
        return o
    return 0x01000000 + o


class Bridge:
    def __init__(self, mode, fps, width):
        self.mode = mode
        self.fps = fps
        self.width = width
        self.loop = GLib.MainLoop()
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")
        self.counter = 0
        self.session = None
        self.stream_node = None
        self.stream_size = (1920, 1080)
        self.pipeline = None
        self.sink = None
        self.last_jpeg = None
        self.last_sent = 0.0
        self.lock = threading.Lock()

    # ── portal helpers ────────────────────────────────────
    def _token(self):
        self.counter += 1
        return f"assist{os.getpid()}_{self.counter}"

    def _request(self, iface, method, args_builder, on_response):
        """Chama um método do portal que responde via sinal Request::Response."""
        token = self._token()
        path = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"

        def handler(_conn, _sender, _path, _iface, _signal, params):
            self.bus.signal_unsubscribe(sub_id)
            code, results = params.unpack()
            if code != 0:
                self.fail("Permissão negada no diálogo do sistema." if code == 1 else f"Portal respondeu código {code}.")
                return
            on_response(results)

        sub_id = self.bus.signal_subscribe(PORTAL, REQ_IFACE, "Response", path, None, Gio.DBusSignalFlags.NO_MATCH_RULE, handler)
        try:
            self.bus.call_sync(PORTAL, PORTAL_PATH, iface, method, args_builder(token), None, Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error as e:
            self.bus.signal_unsubscribe(sub_id)
            self.fail(f"Erro no portal ({method}): {e.message}")

    def _token_file(self):
        return os.path.join(CONFIG_DIR, f"{self.mode}_restore_token")

    def _load_restore(self):
        try:
            with open(self._token_file()) as f:
                return f.read().strip() or None
        except OSError:
            return None

    def _save_restore(self, tok):
        if not tok:
            return
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(self._token_file(), "w") as f:
            f.write(tok)
        os.chmod(self._token_file(), 0o600)

    # ── fluxo de início ──────────────────────────────────
    def start(self):
        iface = RD_IFACE if self.mode == "control" else SC_IFACE

        def created(results):
            self.session = results["session_handle"]
            if self.mode == "control":
                self._select_devices()
            else:
                self._select_sources(persist=True)

        self._request(iface, "CreateSession", lambda t: GLib.Variant("(a{sv})", ({
            "handle_token": GLib.Variant("s", t),
            "session_handle_token": GLib.Variant("s", t + "s"),
        },)), created)

    def _select_devices(self):
        opts = {
            "types": GLib.Variant("u", 3),  # teclado | ponteiro
            "persist_mode": GLib.Variant("u", 2),
        }
        tok = self._load_restore()
        if tok:
            opts["restore_token"] = GLib.Variant("s", tok)

        def build(t):
            opts["handle_token"] = GLib.Variant("s", t)
            return GLib.Variant("(oa{sv})", (self.session, opts))

        self._request(RD_IFACE, "SelectDevices", build, lambda _r: self._select_sources(persist=False))

    def _select_sources(self, persist):
        opts = {
            "types": GLib.Variant("u", 1),  # monitor
            "multiple": GLib.Variant("b", False),
            "cursor_mode": GLib.Variant("u", 2),  # cursor desenhado na imagem
        }
        if persist:
            opts["persist_mode"] = GLib.Variant("u", 2)
            tok = self._load_restore()
            if tok:
                opts["restore_token"] = GLib.Variant("s", tok)

        def build(t):
            opts["handle_token"] = GLib.Variant("s", t)
            return GLib.Variant("(oa{sv})", (self.session, opts))

        self._request(SC_IFACE, "SelectSources", build, lambda _r: self._start_session())

    def _start_session(self):
        iface = RD_IFACE if self.mode == "control" else SC_IFACE

        def started(results):
            if self.mode == "control":
                devices = int(results.get("devices", 0))
                if "devices" in results and devices & 3 != 3:
                    # Usuário deixou "Permitir interação remota" desligado.
                    try:
                        os.remove(self._token_file())
                    except OSError:
                        pass
                    self.fail("O controle não foi liberado: na janela do Ubuntu, ative a chave "
                              "\"Permitir interação remota\" antes de compartilhar.")
                    return
            self._save_restore(results.get("restore_token"))
            streams = results.get("streams") or []
            if not streams:
                self.fail("Nenhuma tela foi compartilhada.")
                return
            node, props = streams[0]
            self.stream_node = node
            if "size" in props:
                self.stream_size = tuple(props["size"])
            self._open_pipewire()

        self._request(iface, "Start", lambda t: GLib.Variant("(osa{sv})", (self.session, "", {"handle_token": GLib.Variant("s", t)})), started)

    def _open_pipewire(self):
        try:
            res, fds = self.bus.call_with_unix_fd_list_sync(
                PORTAL, PORTAL_PATH, SC_IFACE, "OpenPipeWireRemote",
                GLib.Variant("(oa{sv})", (self.session, {})), GLib.VariantType("(h)"),
                Gio.DBusCallFlags.NONE, -1, None, None)
            fd = fds.get(res.unpack()[0])
        except GLib.Error as e:
            self.fail(f"Erro ao abrir o PipeWire: {e.message}")
            return

        Gst.init(None)
        desc = (
            f"pipewiresrc fd={fd} path={self.stream_node} do-timestamp=true keepalive-time=1000 always-copy=true ! "
            "videoconvert ! videorate ! "
            f"video/x-raw,framerate={max(1, self.fps)}/1 ! videoscale ! "
            f"video/x-raw,width={self.width},height={self._scaled_height()} ! "
            "jpegenc quality=60 ! appsink name=sink emit-signals=true max-buffers=1 drop=true sync=false"
        )
        try:
            self.pipeline = Gst.parse_launch(desc)
        except GLib.Error as e:
            self.fail(f"Erro no GStreamer: {e.message}")
            return
        self.sink = self.pipeline.get_by_name("sink")
        self.sink.connect("new-sample", self._on_sample)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", lambda _b, m: self.fail(f"Captura: {m.parse_error()[0].message}"))
        self.pipeline.set_state(Gst.State.PLAYING)
        emit({"type": "ready", "mode": self.mode, "w": self.stream_size[0], "h": self.stream_size[1]})
        GLib.timeout_add(int(1000 / max(1, self.fps)), self._send_frame)

    def _scaled_height(self):
        w, h = self.stream_size
        return max(2, int(round(self.width * h / max(1, w) / 2)) * 2)

    def _on_sample(self, sink):
        sample = sink.emit("pull-sample")
        if sample is None:
            return Gst.FlowReturn.OK
        buf = sample.get_buffer()
        ok, info = buf.map(Gst.MapFlags.READ)
        if ok:
            with self.lock:
                self.last_jpeg = bytes(info.data)
            buf.unmap(info)
        return Gst.FlowReturn.OK

    def _send_frame_once(self):
        self._send_frame()
        return False

    def _send_frame(self):
        with self.lock:
            data = self.last_jpeg
        if data:
            emit({"type": "frame", "data": base64.b64encode(data).decode()})
        return True

    # ── controle ─────────────────────────────────────────
    def _rd(self, method, signature, *args):
        self.bus.call_sync(PORTAL, PORTAL_PATH, RD_IFACE, method,
                           GLib.Variant(signature, (self.session, {}) + args),
                           None, Gio.DBusCallFlags.NONE, -1, None)

    def _to_px(self, x, y):
        w, h = self.stream_size
        x = min(max(float(x), 0), 1000) / 1000 * (w - 1)
        y = min(max(float(y), 0), 1000) / 1000 * (h - 1)
        return x, y

    def _move(self, x, y):
        px, py = self._to_px(x, y)
        self._rd("NotifyPointerMotionAbsolute", "(oa{sv}udd)", self.stream_node, px, py)

    def _button(self, code, pressed):
        self._rd("NotifyPointerButton", "(oa{sv}iu)", code, 1 if pressed else 0)

    def _key(self, keysym, pressed):
        self._rd("NotifyKeyboardKeysym", "(oa{sv}iu)", keysym, 1 if pressed else 0)

    def handle(self, msg):
        cmd = msg.get("cmd")
        rid = msg.get("id")
        if cmd == "stop":
            self.quit()
            return False
        try:
            if self.mode != "control":
                raise RuntimeError("Controle não está ativado (modo só visualização).")
            if self.session is None or self.stream_node is None:
                raise RuntimeError("Tela ainda não está pronta.")
            if cmd == "move":
                self._move(msg["x"], msg["y"])
                out = "Mouse movido."
            elif cmd == "click":
                self._move(msg["x"], msg["y"])
                time.sleep(0.05)
                code = BUTTONS.get(str(msg.get("button", "left")).lower(), 272)
                for _ in range(2 if msg.get("double") else 1):
                    self._button(code, True)
                    time.sleep(0.04)
                    self._button(code, False)
                    time.sleep(0.08)
                out = "Clique feito."
            elif cmd == "type":
                text = str(msg.get("text", ""))[:2000]
                for c in text:
                    ks = char_keysym(c)
                    self._key(ks, True)
                    self._key(ks, False)
                    time.sleep(0.012)
                out = f"Digitado ({len(text)} caracteres)."
            elif cmd == "key":
                parts = [p.strip().lower() for p in str(msg.get("combo", "")).replace(" ", "").split("+") if p.strip()]
                if not parts:
                    raise RuntimeError("Combinação vazia.")
                syms = []
                for p in parts:
                    if p in KEYSYMS:
                        syms.append(KEYSYMS[p])
                    elif len(p) == 1:
                        syms.append(char_keysym(p))
                    else:
                        raise RuntimeError(f"Tecla desconhecida: {p}")
                for s in syms:
                    self._key(s, True)
                    time.sleep(0.02)
                for s in reversed(syms):
                    self._key(s, False)
                    time.sleep(0.02)
                out = f"Teclas {'+'.join(parts)} pressionadas."
            elif cmd == "scroll":
                amount = max(1, min(int(msg.get("amount", 3)), 30))
                up = str(msg.get("dir", "down")).lower() in ("up", "cima")
                if "x" in msg and "y" in msg:
                    self._move(msg["x"], msg["y"])
                self._rd("NotifyPointerAxisDiscrete", "(oa{sv}ui)", 0, -amount if up else amount)
                out = f"Rolou {'para cima' if up else 'para baixo'}."
            else:
                raise RuntimeError(f"Comando desconhecido: {cmd}")
            emit({"type": "result", "id": rid, "ok": True, "msg": out})
            # Imagem nova logo após a ação, para a IA conferir o resultado.
            GLib.timeout_add(350, self._send_frame_once)
        except Exception as e:  # noqa: BLE001
            emit({"type": "result", "id": rid, "ok": False, "msg": str(e)})
        return False

    # ── ciclo de vida ────────────────────────────────────
    def fail(self, msg):
        emit({"type": "error", "msg": msg})
        self.quit()

    def quit(self):
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
        if self.session:
            try:
                self.bus.call_sync(PORTAL, self.session, "org.freedesktop.portal.Session", "Close",
                                   None, None, Gio.DBusCallFlags.NONE, -1, None)
            except GLib.Error:
                pass
        self.loop.quit()

    def stdin_reader(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            GLib.idle_add(self.handle, msg)
        GLib.idle_add(self.quit)  # app fechou o stdin → encerra

    def run(self):
        threading.Thread(target=self.stdin_reader, daemon=True).start()
        GLib.idle_add(lambda: (self.start(), False)[1])
        self.loop.run()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["view", "control"], default="view")
    ap.add_argument("--fps", type=int, default=1)
    ap.add_argument("--width", type=int, default=1280)
    a = ap.parse_args()
    Bridge(a.mode, a.fps, a.width).run()


if __name__ == "__main__":
    main()
