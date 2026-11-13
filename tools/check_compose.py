#!/usr/bin/env python3
"""Render Compose with synthetic credentials; never connect to the Docker daemon."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
env = dict(os.environ)
for key in list(env):
    if key.startswith(("COMPOSE_", "SEAFILE_", "ONLYOFFICE_", "SEADOC_", "REDIS_", "INIT_", "JWT_", "CADDY_")):
        env.pop(key)
env.update(SEAFILE_MYSQL_DB_PASSWORD="synthetic-test-only", JWT_PRIVATE_KEY="synthetic-test-only",
           ONLYOFFICE_JWT_SECRET="synthetic-test-only", SEAFILE_SERVER_HOSTNAME="192.0.2.10")
cmd = ["docker", "compose", "--project-name", "seafile-validation", "--env-file", str(ROOT / "tests/compose.env.example")]
for name in ("seafile-server.yml", "caddy.yml", "onlyoffice.yml", "seadoc.yml"):
    cmd += ["-f", str(ROOT / "installer/compose" / name)]
cmd += ["config", "--format", "json"]
result = subprocess.run(cmd, env=env, check=True, capture_output=True, text=True, encoding="utf-8")
cfg = json.loads(result.stdout)
assert set(cfg["services"]) == {"db", "redis", "seafile", "caddy", "onlyoffice", "seadoc"}
assert len(cfg["volumes"]) == 3 and all(v["external"] for v in cfg["volumes"].values())
assert cfg["services"]["onlyoffice"]["hostname"] == "05831744982c"
assert cfg["services"]["seadoc"]["environment"]["SEAHUB_SERVICE_URL"] == "http://seafile"
assert cfg["services"]["seafile"]["environment"]["ENABLE_SEADOC"] == "true"
print("Compose validated: six services, three external volumes, SeaDoc internal routing")
