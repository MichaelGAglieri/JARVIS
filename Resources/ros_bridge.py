"""ROS 2 bridge for JARVIS.

Runs inside the lab's pixi environment (ROS 2 Jazzy, ROS_DOMAIN_ID 42) and
exposes to JARVIS, only on 127.0.0.1 and with a token, what it needs to talk
to the robots: graph of nodes and topics, reading and publishing on any topic,
lab commands and outcomes. Writes "PORT 12345" to stdout as soon as it is ready
and quits by itself when JARVIS exits.

GET  /graph                       nodes and topics with their types
POST /echo     {topic, timeout}   one message from the topic
POST /publish  {topic, data, type?}
POST /lab      {text, wait}       command to the lab, waits for the outcome
GET  /lab                          latest state, outcome and reply of the lab
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import rclpy
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from rosidl_runtime_py import message_to_ordereddict, set_message_fields
from rosidl_runtime_py.utilities import get_message
from std_msgs.msg import String

TOKEN = os.environ.get("JARVIS_BRIDGE_TOKEN", "")
LAB_TOPICS = ("/laboratorio/stato", "/laboratorio/esito", "/laboratorio/risposta")
LAB_COMMAND = "/laboratorio/testo"


class Bridge(Node):
    def __init__(self):
        super().__init__("jarvis_bridge")
        self.lock = threading.Lock()
        self.latest = {}          # topic -> (time, text)
        self.publishers_by_topic = {}
        for topic in LAB_TOPICS:
            self.create_subscription(String, topic, lambda msg, t=topic: self.remember(t, msg.data), 10)
        self.lab = self.create_publisher(String, LAB_COMMAND, 10)

    def remember(self, topic, text):
        with self.lock:
            self.latest[topic] = (time.time(), text)

    def lab_snapshot(self):
        now = time.time()
        with self.lock:
            return {t.rsplit("/", 1)[-1]: {"testo": v[1], "secondi_fa": round(now - v[0], 1)}
                    for t, v in self.latest.items()}

    def topic_type(self, topic):
        for name, types in self.get_topic_names_and_types():
            if name == topic and types:
                return types[0]
        return None

    def graph(self):
        nodes = sorted(f"{ns.rstrip('/')}/{n}" for n, ns in self.get_node_names_and_namespaces())
        topics = sorted((name, types[0] if types else "?") for name, types in self.get_topic_names_and_types())
        return {"nodi": nodes, "topic": [{"nome": n, "tipo": t} for n, t in topics]}

    def echo(self, topic, timeout):
        kind = self.topic_type(topic)
        if not kind:
            return {"errore": f"Il topic {topic} non esiste o nessuno lo pubblica."}
        received = threading.Event()
        box = {}

        def callback(msg):
            if not received.is_set():
                box["msg"] = message_to_ordereddict(msg)
                received.set()

        # Best effort: receives from both reliable and "sensor" publishers.
        qos = QoSProfile(depth=5, reliability=ReliabilityPolicy.BEST_EFFORT)
        sub = self.create_subscription(get_message(kind), topic, callback, qos)
        try:
            if not received.wait(timeout):
                return {"topic": topic, "tipo": kind, "errore": f"Nessun messaggio in {timeout} s."}
            text = json.dumps(box["msg"], ensure_ascii=False, default=str)
            return {"topic": topic, "tipo": kind, "messaggio": text[:4000]}
        finally:
            self.destroy_subscription(sub)

    def publish(self, topic, data, kind=None):
        kind = kind or self.topic_type(topic)
        if not kind:
            return {"errore": f"Tipo del topic {topic} sconosciuto: indicalo (es. std_msgs/msg/String)."}
        cls = get_message(kind)
        msg = cls()
        if isinstance(data, dict):
            set_message_fields(msg, data)
        elif hasattr(msg, "data"):
            msg.data = type(msg.data)(data)
        else:
            return {"errore": "Per questo tipo servono i campi del messaggio come oggetto JSON."}
        with self.lock:
            pub = self.publishers_by_topic.get((topic, kind))
            if pub is None:
                pub = self.create_publisher(cls, topic, 10)
                self.publishers_by_topic[(topic, kind)] = pub
        # A freshly created publisher can lose the first message: wait
        # briefly for someone to connect.
        for _ in range(20):
            if pub.get_subscription_count() > 0:
                break
            time.sleep(0.05)
        pub.publish(msg)
        return {"ok": True, "topic": topic, "tipo": kind, "ascoltatori": pub.get_subscription_count()}

    def lab_command(self, text, wait):
        sent = time.time()
        for _ in range(20):
            if self.lab.get_subscription_count() > 0:
                break
            time.sleep(0.05)
        if self.lab.get_subscription_count() == 0:
            return {"errore": "Il laboratorio non è in esecuzione (nessuno ascolta /laboratorio/testo)."}
        self.lab.publish(String(data=text))
        deadline = sent + wait
        while time.time() < deadline:
            with self.lock:
                esito = self.latest.get("/laboratorio/esito")
            if esito and esito[0] >= sent:
                time.sleep(0.3)   # the text reply arrives right after the outcome
                break
            time.sleep(0.1)
        result = self.lab_snapshot()
        result["inviato"] = text
        if not (self.latest.get("/laboratorio/esito", (0,))[0] >= sent):
            result["nota"] = f"Nessun esito entro {wait} s: il comando potrebbe essere ancora in corso."
        return result


def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, status, body):
            raw = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def authorized(self):
            # Right token and no requests from browser web pages (Origin / Host).
            host = self.headers.get("Host", "")
            if (self.headers.get("Authorization") != f"Bearer {TOKEN}" or self.headers.get("Origin")
                    or not host.startswith(("127.0.0.1:", "localhost:"))):
                self.reply(403, {"errore": "token non valido"})
                return False
            return True

        def do_GET(self):
            if not self.authorized():
                return
            if self.path == "/graph":
                self.reply(200, bridge.graph())
            elif self.path == "/lab":
                self.reply(200, bridge.lab_snapshot())
            else:
                self.reply(404, {"errore": "percorso sconosciuto"})

        def do_POST(self):
            if not self.authorized():
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
                if self.path == "/echo":
                    self.reply(200, bridge.echo(body["topic"], float(body.get("timeout", 3))))
                elif self.path == "/publish":
                    self.reply(200, bridge.publish(body["topic"], body.get("data"), body.get("type")))
                elif self.path == "/lab":
                    self.reply(200, bridge.lab_command(body["text"], float(body.get("wait", 30))))
                else:
                    self.reply(404, {"errore": "percorso sconosciuto"})
            except Exception as error:  # noqa: BLE001 - the error goes back to JARVIS
                self.reply(400, {"errore": str(error)})

        def log_message(self, *args):
            pass

    return Handler


def watch_jarvis():
    """Quits when JARVIS exits. The bridge starts through pixi, so the parent
    process is pixi: JARVIS's PID is checked directly."""
    pid = int(os.environ.get("JARVIS_PID", os.getppid()))
    while True:
        time.sleep(2)
        try:
            os.kill(pid, 0)
        except OSError:
            os._exit(0)


def main():
    threading.Thread(target=watch_jarvis, daemon=True).start()
    rclpy.init()
    bridge = Bridge()
    executor = MultiThreadedExecutor()
    executor.add_node(bridge)
    threading.Thread(target=executor.spin, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(bridge))
    print(f"PORT {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
