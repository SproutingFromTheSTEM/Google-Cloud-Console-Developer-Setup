# Developer setup: use Gemini without the API key
#This one is the right one
Use Google's Gemini models, and other APIs your admin added, from your own Python code **without ever handling an API key**. Everything here runs from your computer's own terminal.

## How it works

```
Your computer                          Google Cloud (managed by your admin)
─────────────                          ─────────────────────────────────────────────
your code + gemini_access.py ──────►  gemini-app
  sends: your prompt + model             1. checks you're allowed (your Google sign-in)
         + your Google sign-in token     2. reads the API key from Secret Manager
                              ◄──────    3. calls Gemini, returns only the answer
  receives: the answer
```

- The API key lives only in Google Cloud. It never reaches your computer.
- You sign in with **your own Google account**. Access is granted and removed per person by your admin.
- The key is replaced automatically on a schedule. You don't need to do anything when that happens.

### What happens on each request

1. **Your code calls `gemini_access.py`**, for example `model.generate_content("...")`.
2. **It gets your sign-in token** by running `gcloud auth print-identity-token`. This proves who you are, not what you can access, and it expires after about an hour. The token is kept in memory and reused for 45 minutes. It's never written to disk.
3. **It sends the request to gemini-app** at the URL in `gemini_access.py`, or in the `GEMINI_APP_URL` environment variable if you set one. The request contains your prompt, the model name, and the token.
4. **gemini-app checks your account**, reads the API key from Secret Manager, and calls Gemini (or, for `api(NAME)`, the outside API at `/proxy/NAME/...`).
5. **Only the answer comes back.** The key stays in Google Cloud.

So `gemini_access.py` only needs two things on your machine: a signed-in `gcloud` and the gemini-app URL. `./dev.sh setup` takes care of both.

## What's in this folder

| File | What it is |
|---|---|
| `dev.sh` | Setup and everyday commands for **Mac** (and Linux) |
| `dev.ps1` | The same commands for **Windows** |
| `gemini_access.py` | Connects your code to the Gemini models. Import it; you write the prompts and logic. |
| `requirements.txt` | The Python libraries it needs (`requests`, and Google's `google-genai` for full Gemini features). |

---

## Setup (one time, a few minutes)

**1. Ask for access.** Send your admin the Google account email you'll use. They run `./admin.sh add-developer you@example.com` and send you this folder, usually with the gemini-app URL already filled in.

**2. Open a terminal in this folder.**
- **Mac:** open **Terminal** (Cmd+Space, type `Terminal`, Enter), then go to the folder, for example:
  ```
  cd ~/Downloads/developer-setup
  ```
- **Windows:** open **PowerShell** (Start menu → `PowerShell`), then:
  ```
  cd $HOME\Downloads\developer-setup
  ```
An IDE's built-in terminal (for example, VS Code: **Terminal → New Terminal**) works the same way.

**3. Run setup.**
- **Mac:**
  ```
  chmod +x dev.sh
  ./dev.sh setup
  ```
- **Windows** (the first line lets PowerShell run scripts you downloaded; you only need it once):
  ```
  Unblock-File .\dev.ps1; Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
  .\dev.ps1 setup
  ```

Setup installs anything missing (Python if needed, the Google Cloud CLI, and the Python library), opens your browser to sign in, asks for the gemini-app URL if it isn't filled in yet, and tests the connection. When it prints **Setup complete**, you're done. Running it again is safe; finished steps are skipped.

When you copy commands from this file, copy only the command lines themselves, not the ```` ``` ```` lines around them.

---

## Everyday commands

Run these from this folder. On Windows, use `.\dev.ps1` in place of `./dev.sh`.

| Command | What it does |
|---|---|
| `./dev.sh setup` | One-time setup; also fixes a broken setup |
| `./dev.sh status` | Shows who you're signed in as and the app URL, and tests the connection |
| `./dev.sh models` | Lists the models you're allowed to use |
| `./dev.sh ask "PROMPT"` | Sends one prompt from the terminal, using `gemini-3.5-flash-lite` |
| `./dev.sh ask "PROMPT" MODEL` | Same, with a model you choose, e.g. `gemini-3.8-flash` |
| `./dev.sh apis` | Lists the other APIs your admin added, by name |
| `./dev.sh login` | Signs in again, or switches to a different Google account |
| `./dev.sh set-url URL` | Saves the gemini-app URL your admin gave you |
| `./dev.sh help` | Lists these commands |

---

## Using it in your code

There are two ways to call Gemini:

- **`get_client()`**: Google's own Gemini library (`google-genai`), with every feature. Use this for anything beyond plain text. See [Full Gemini features](#full-gemini-features) below.
- **`get_model()`**: the simple way, with text in and text out. It's shown first because it's the quickest to try.

The simple way gives you three things:

| Call | Returns |
|---|---|
| `list_models()` | A list of model names you're allowed to use |
| `get_model(name)` | A model object |
| `model.generate_content(prompt)` | The model's response, as a string |

```python
from gemini_access import get_model, list_models

model = get_model("gemini-3.5-flash-lite")
response = model.generate_content(YOUR_PROMPT)
```

Everything else (prompts, loops, parsing responses) is your code.

`gemini_access.py` is a library, not a program, so `python3 gemini_access.py` does nothing. Import it from your own script instead.

### Full Gemini features

`get_client()` returns Google's own `genai.Client`, so you can follow **Google's Gemini documentation** (ai.google.dev) as written. The only change is how you create the client:

```python
# Google's docs say:        client = genai.Client(api_key="...")
# Here, instead (no key):
from gemini_access import get_client
client = get_client()
```

Everything after that line is the same as in Google's docs:

```python
from google.genai import types
from PIL import Image          # pip install pillow, for images

client = get_client()

# Settings and a system instruction
r = client.models.generate_content(
    model="gemini-3.5-flash-lite",
    contents="Explain recursion",
    config=types.GenerateContentConfig(system_instruction="Answer in two sentences.", temperature=0.2),
)
print(r.text)

# Images (and audio, video, PDFs)
r = client.models.generate_content(model="gemini-3.5-flash-lite",
                                   contents=[Image.open("chart.png"), "What does this chart show?"])

# Large files: upload once, then refer to them
doc = client.files.upload(file="report.pdf")
r = client.models.generate_content(model="gemini-3.5-flash-lite", contents=[doc, "Summarize this"])

# Chat with history
chat = client.chats.create(model="gemini-3.5-flash-lite")
print(chat.send_message("Hi, I'm planning a trip").text)
print(chat.send_message("What should I pack?").text)

# Streaming: print the answer as it's written
for chunk in client.models.generate_content_stream(model="gemini-3.5-flash-lite", contents="Write a story"):
    print(chunk.text, end="")
```

JSON output, function calling and tools, token counting, embeddings, and async (`client.aio`) work the same way. Your sign-in is refreshed automatically, so long-running programs keep working.

**What doesn't work through gemini-app:**
- **The Live API** (real-time voice and video conversations).
- **Listing uploaded files or caches** (`client.files.list()`, `client.caches.list()`). Everyone shares one key, so the list would include other people's uploads. Keep the `.name` your own calls return instead. Getting, using, and deleting by name all work. Uploaded files are deleted automatically after 48 hours.
- **Models your admin hasn't allowed.** These return a `403` error that lists the allowed ones.

### Connecting it to your other scripts

**Before you start:** run `./dev.sh setup` once. Every option below uses the same sign-in and URL.

**Option 1: copy the file into your project (simplest).** Put `gemini_access.py` next to your script:

```
my-project/
├── gemini_access.py
└── summarize.py
```

```python
# summarize.py
import sys
from gemini_access import get_model

model = get_model("gemini-3.5-flash-lite")

try:
    text = open(sys.argv[1]).read()
    print(model.generate_content("Summarize this in 3 bullet points:\n\n" + text))
except RuntimeError as e:      # sign-in, access, or URL problems
    sys.exit(f"Gemini error: {e}")
```

```
cd my-project
python3 summarize.py notes.txt
```

The project needs the libraries in `requirements.txt`. Setup installs them for the Python you used. If your project has its own virtual environment, run `pip install -r requirements.txt` (from this folder) inside it, or `pip install requests google-genai`.

**Option 2: leave the file here and point Python at this folder.** That way your projects always use this one copy.
- Mac (add the `export` line to `~/.zshrc` to make it permanent):
  ```
  export PYTHONPATH="$HOME/Downloads/developer-setup:$PYTHONPATH"
  python3 /path/to/your_script.py
  ```
- Windows (PowerShell, current window only):
  ```
  $env:PYTHONPATH = "$HOME\Downloads\developer-setup"
  python .\your_script.py
  ```
- Or set it inside the script itself, at the top:
  ```python
  import sys, os
  sys.path.insert(0, os.path.expanduser("~/Downloads/developer-setup"))
  from gemini_access import get_model
  ```

**Option 3: from shell scripts or other languages.**
- **Shell:** call `dev.sh` by its full path. It works from any folder, and only the answer goes to standard output:
  ```bash
  answer="$(~/Downloads/developer-setup/dev.sh ask "Write a haiku about Mondays")"
  echo "$answer"
  ```
- **Any language that can send HTTP requests:** send a `POST` to the gemini-app URL with your token as a Bearer header and a JSON body `{"model": ..., "prompt": ...}`. The reply is `{"text": "..."}`. For example, with curl:
  ```bash
  curl -s -X POST "$GEMINI_APP_URL" \
    -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
    -H "Content-Type: application/json" \
    -d '{"model": "gemini-3.5-flash-lite", "prompt": "Say hi"}'
  ```
  `GET $GEMINI_APP_URL/models` lists your models. Outside APIs are at `$GEMINI_APP_URL/proxy/NAME/<path from that API's docs>`.
- **Gemini's full REST API:** use the requests from Google's REST docs, with `https://generativelanguage.googleapis.com` replaced by the gemini-app URL and the key replaced by your token. For example, `POST $GEMINI_APP_URL/v1beta/models/gemini-3.5-flash-lite:generateContent` with the usual `{"contents": [...]}` body.

**Using a different URL without editing the file:** set `GEMINI_APP_URL` in your environment. It takes priority over the URL saved in `gemini_access.py`:
```
export GEMINI_APP_URL="https://gemini-app-....run.app"
```

### Choosing a model

| Model | Use it for |
|---|---|
| `gemini-3.5-flash-lite` | Default. Fastest and cheapest; good for testing and simple tasks. |
| `gemini-3.8-flash` | Better quality for harder tasks. |

`./dev.sh models` shows exactly which models you're allowed to use. Your admin may limit the list.

### Other APIs your admin added

Your admin can store keys for other services (OpenAI, Anthropic, weather or maps APIs, and so on) and tell you each one's **name**. `./dev.sh apis` lists them. Call them with `api(NAME)`, using paths and request bodies **exactly as that API's documentation shows, just without the key**:

```python
from gemini_access import api

r = api("openai").post("/v1/chat/completions", json={
    "model": "MODEL_NAME",
    "messages": [{"role": "user", "content": YOUR_PROMPT}],
})
print(r.status_code, r.json())

r = api("weather").get("/forecast", params={"city": "Chicago"})
```

| Call | What it does |
|---|---|
| `list_apis()` | Names of the APIs your admin added |
| `api(name)` | A client for that API |
| `.get(path, ...)`, `.post(path, json=...)`, `.put(...)`, `.patch(...)`, `.delete(...)` | Sends the request; returns a normal `requests` response (`.status_code`, `.json()`, `.text`) |

- Leave out the key and any `Authorization` header. gemini-app adds the key for you; if you pass your own, it's replaced.
- Errors from the API itself (for example `400` or `429`) come back as normal responses, so check `r.status_code`. Problems with *your* access raise an error with a message saying what to do.
- Responses aren't streamed; each request waits for the full answer.

### Limits of this setup

- **`get_model()` is text in, text out.** For everything else, use `get_client()` ([Full Gemini features](#full-gemini-features)).
- **Other providers' SDKs (OpenAI, Anthropic, ...) can't be used directly**, because they need the API key. Use `api(NAME)` instead.
- **No Live API** (real-time voice and video), and no listing of uploaded files or caches. See [Full Gemini features](#full-gemini-features).

---

## Troubleshooting

Start with `./dev.sh status`; it tells you what's wrong in most cases.

| Message | Fix |
|---|---|
| `You're not signed in` or `401 Unauthorized` | `./dev.sh login` |
| `403 Forbidden` / `your account doesn't have access` | Check `./dev.sh status` shows the account your admin approved. If it does, ask your admin to run `./admin.sh add-developer YOUR-EMAIL`. If not, `./dev.sh login` and pick the right account. |
| `HTTP 403: Model not allowed` | Use a model from `./dev.sh models`. |
| `No API key named ...` | Check the name with `./dev.sh apis`, or ask your admin. |
| An added API returns `401` | Its stored key is wrong or expired. Tell your admin (`./admin.sh update-key NAME`). |
| `The gemini-app URL isn't set` | `./dev.sh set-url https://...` with the URL from your admin |
| `HTTP 404` or a connection error | The URL is wrong. Get it again from your admin and run `./dev.sh set-url`. |
| `zsh: command not found: gcloud` (Mac) or `'gcloud' is not recognized` (Windows) | Open a new terminal window, then run setup again. |
| `ModuleNotFoundError: No module named 'gemini_access'` | Python can't find `gemini_access.py`. Copy it next to your script, or set `PYTHONPATH` (see [Connecting it to your other scripts](#connecting-it-to-your-other-scripts)). |
| `ModuleNotFoundError: No module named 'requests'` | Run setup again. In an IDE, also make sure it uses the same Python as your terminal (`which python3` on Mac). |
| Windows: `running scripts is disabled on this system` | Run the `Unblock-File ...` line from setup step 3, or use `powershell -ExecutionPolicy Bypass -File .\dev.ps1 setup` |
| Mac: you pasted a command and now see `bquote>` or `bash-3.2$` | You copied the ```` ``` ```` lines too. Press Ctrl+C (or type `exit`) and paste just the command. |
| `HTTP 429` | Too many requests. Wait a minute and retry; tell your admin if it keeps happening. |
| `HTTP 5xx` | Temporary problem. Retry; tell your admin if it keeps happening. |

## What you can and can't do

**You can:**
- Use Gemini from your own code and terminal.
- Choose among the models your admin allows.

**You can't, by design:**
- See, copy, or download any API key, whether from code, Secret Manager, the Cloud Console, or AI Studio.
- Add, change, or remove keys; only your admin can.
- View or change the gemini-app service.

## FAQ

**Do I need a Google Cloud project or billing account?**
No. Usage is billed to your team's project.

**What happens when the key rotates?**
Nothing you'll notice. gemini-app reads the newest key on every request.

**Is the gemini-app URL secret?**
No. Without access, calling it returns `403`. Even with access, you only get answers back, never the key.

**Is my usage logged?**
Yes. For Gemini: your email, the model, token counts, and whether the request worked. For other APIs: your email, which API, the path, and the status. Prompt text and request bodies aren't logged unless your admin turns that on for Gemini.

**Can I use this on a server or in CI?**
It works anywhere `gcloud` is signed in as an account with access. For automated systems, ask your admin about a service account instead of your personal login.
