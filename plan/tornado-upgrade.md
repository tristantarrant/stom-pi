# Tornado upgrade plan — mod-ui 4.3 → modern (6.x)

Status: **researched, not started**. Probe evidence below is from tornado 6.5.10 on Python 3.14; target runtime is Pi OS trixie / Python 3.13 (tornado ≥6 requires py≥3.9 ✓).

## Goal

Replace the `tornado==4.3` pin with a maintained release (`>=6,<7`) so we stop shipping an unpatched-2015 web framework and can drop both of our build-time compatibility hacks from packaging (the collections-ABC fixer in `debian/scripts/stage-build.sh` + the conditional `backports.ssl-match-hostname` install).

## Verified findings (probe: `.tprobe/` venv, tornado 6.5.10)

Reproduce with:
```bash
cd /home/tst/Work/Dataforte/stom-pi      # workspace root (outside both git repos)
rm -rf .tprobe && python3 -m venv .tprobe
.tprobe/bin/pip install "Pillow>=8.2" pyserial==3.0 pycryptodomex==3.18.0 aggdraw==1.3.11 tornado
```
(probe venv lives at `/home/tst/Work/Dataforte/stom-pi/.tprobe`; recreate if wiped)

| API | Status in 6.x | mod-ui usage | Work needed |
|---|---|---|---|
| `@web.asynchronous` | **removed (Tornado 5)** — app fails at import on any ≥5 (`mod/webserver.py:309` is the first crash site) | **33 methods**, all in `mod/webserver.py` | Convert each to a coroutine. The real work + regression surface. File receivers (:309, :359) are the most intricate; most others share one shape (callback-style internal call → response written from callback). |
| `tornado.gen.Task` | **removed** — but every site wraps mod-ui's own helper functions whose contract is a plain trailing callback (`def f(self, …, callback)` then `callback(result)`) | 140 sites: ~6 files (webserver.py, session.py, host.py, hmi.py, addressings.py, control_chain.py), all spelled `yield gen.Task(fn, args…)` | One compat shim restores the semantics; **zero call-site changes** (keeps rebase cost vs upstream minimal). |
| legacy callback-style IOStream calls (`read_*(…, cb)`, `write(data, cb)`) | removed in 5.x — signatures now `(self, …)` only | **0 found** by scan (incl. pi-ede's new TCP HMI transport code) | none |
| websocket handlers / `open()` override | present; modern signature compatible (`def open(self)` at webserver.py:1219 area) | 3 classes in webserver.py (:1163, :1184, :1219) | runtime verification only |
| `tornado.escape.{squeeze,url_escape,xhtml_escape}` | all present (incl. the unusual `squeeze`) | webserver.py imports | none |
| IOLoop.instance/add_callback/call_later/PeriodicCallback, template.Loader, StaticFileHandler | present (`instance()` deprecated but functional) | pervasive | leave as-is to minimize diff; revisit at 7.x |

## Implementation (one feature commit on `stomp-pi` branch of the fork)

1. **New file `mod/tornado_compat.py`** (~25 lines): legacy-semantics replacement for removed `gen.Task`:
   - wraps a trailing-callback function: build a `tornado.concurrent.Future`, append a callback that resolves it (guard double-resolve; capture exceptions raised synchronously by the wrapped fn), return the future.
   - wiring: one guarded line in `mod/__init__.py` — patch `tornado.gen.Task = compat_Task` **only if missing**, so the tree still runs under old 4.3 too (keeps the diff applicable in both worlds; no per-file import edits).
2. **Convert the 33 `@web.asynchronous` methods** in webserver.py: drop decorator, make method a coroutine (`async def … await`, or `@gen.coroutine` + `yield Task(…)` where internal calls are legacy-callback style — our shim makes that mechanical), write/finish at the end.
3. **`requirements.txt`**: `tornado==4.3` → `tornado>=6,<7`.
4. **Packaging** (`debian/scripts/stage-build.sh`): delete the ABC-fixer invocation + conditional backport install; drop `debian/scripts/tornado-abc-fix.py`; changelog note on pointer bump.

## Verification plan

Per-commit signal (this box, no hardware needed) — probe venv with first-party code staged:
```bash
R=/home/tst/Work/Dataforte/stom-pi; M=$R/stom-pi-ui/mod-ui   # R = workspace root, M = mod-ui submodule checkout
SP=$($R/.tprobe/bin/python -c "import site; print(site.getsitepackages()[0])")
cp -a "$M"/mod "$SP"/ && mkdir -p "$SP/modtools" \
  && cp -a "$M"/modtools/*.py "$SP/modtools"/ && cp "$M"/utils/libmod_utils.so "$SP/modtools"/   # .so must sit next to utils.py (tryPath1); rebuild it first: make -C $M/utils
MOD_HTML_DIR=$R/stom-pi-ui/debian/stomp-pi-ui/usr/share/stomp-pi/html MOD_DATA_DIR=$(mktemp -d) \
  $R/.tprobe/bin/python <in-process probe: import webserver → application.listen(127.0.0.1:<hi-port>) in a thread → GET /system/info (JSON) + GET settings.html>
```
- gate 1: `import mod.webserver` succeeds under tornado 6.x (currently fails at :309 — flips green when handlers are converted)
- gate 2: `/system/info` returns JSON incl. our `ui_build`, settings page serves
- final (on Pi, real runtime): all three websocket clients, HMI serial **and** TCP transport (`MOD_HMI_TRANSPORT=tcp`, pi-ede's mod-ui.sh pattern), control-chain file transfer endpoints, pedalboard save/load + screenshot path

## Risks / notes

- All effort and regression risk sits in the 33 handler conversions; the Task shim is low-risk (contract verified against actual helper code).
- `gen.coroutine` / `IOLoop.instance()` are deprecated-but-working in 6.x — deliberately left untouched to keep upstream diff small; they go away at Tornado 7, so pin `<7`.
- Unrelated observation seen during probing: HMI serial open fails with `SerialBase.__init__() got an unexpected keyword argument 'writeTimeout'` (upstream code vs pyserial 3.0) → always falls back to FakeHMI on this box; pre-existing, out of scope here but worth a look when touching hmi.py anyway.
- House convention: land as one feature commit with `[stom-pi]` prefix per the fork SOP in root AGENTS.md; bump wrapper gitlink + changelog note only after gates are green; force-push `stomp-pi` branch (never master).
