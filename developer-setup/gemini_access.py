"""Access Gemini, and other APIs your admin added, through gemini-app.
The API keys never reach this machine.

    from gemini_access import get_client, get_model, list_models, api, list_apis

    client = get_client()          # Google's google-genai client: every Gemini feature
    client.models.generate_content(model="gemini-3.5-flash-lite", contents="your prompt").text

    model = get_model("gemini-3.5-flash-lite")   # simple text in, text out
    text = model.generate_content("your prompt")

    r = api("openai").post("/v1/chat/completions", json={...})   # name from your admin
    r.json()

Requires: pip install -r requirements.txt, and `gcloud auth login` with an account your admin approved.
"""
import os
import subprocess
import sys
import time

import requests

APP_URL = os.environ.get("GEMINI_APP_URL", "https://gemini-app-vxykdvxkya-uc.a.run.app")  # from your admin

_token, _token_time = None, 0.0


def _auth_header() -> dict:
    """Your Google identity token from gcloud, reused for 45 minutes."""
    global _token, _token_time
    if not _token or time.time() - _token_time > 45 * 60:
        try:
            out = subprocess.run(["gcloud", "auth", "print-identity-token"], check=True,
                                 capture_output=True, text=True, shell=(sys.platform == "win32"))
        except FileNotFoundError:
            raise RuntimeError("gcloud not found. Install the Google Cloud CLI.") from None
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"Run 'gcloud auth login'. {e.stderr.strip()}") from None
        _token, _token_time = out.stdout.strip(), time.time()
    return {"Authorization": f"Bearer {_token}"}


def _check_url():
    if not APP_URL.startswith("https://"):
        raise RuntimeError("Set APP_URL in gemini_access.py or the GEMINI_APP_URL environment variable.")


def _call(method: str, path: str = "", **kwargs) -> dict:
    _check_url()
    r = requests.request(method, APP_URL + path, headers=_auth_header(), timeout=180, **kwargs)
    try:
        data = r.json()
    except ValueError:
        data = {"error": r.text[:300]}
    if r.status_code == 401:
        raise RuntimeError("401 Unauthorized: run 'gcloud auth login'.")
    if r.status_code == 403 and "error" not in data:
        raise RuntimeError("403 Forbidden: your account doesn't have access. Ask your admin.")
    if not r.ok:
        err = data.get("error", data)
        raise RuntimeError(f"HTTP {r.status_code}: {err.get('message', err) if isinstance(err, dict) else err}")
    return data


class GeminiModel:
    def __init__(self, name: str):
        self.name = name

    def generate_content(self, prompt: str) -> str:
        """Send a prompt to this model and return its text response."""
        return _call("POST", json={"model": self.name, "prompt": prompt})["text"]

    def __repr__(self):
        return f"GeminiModel({self.name!r})"


def get_model(name: str) -> GeminiModel:
    """Return a model you can call with .generate_content(prompt)."""
    return GeminiModel(name)


def list_models() -> list:
    """Names of the models you're allowed to use."""
    return _call("GET", "/models")["models"]


def get_client(timeout: float = 600):
    """Google's google-genai Client, sending every request through gemini-app.

    Use it exactly as in Google's Gemini docs: images, files, chat, system instructions,
    JSON output, tools, streaming, embeddings, and async (client.aio). Your sign-in is
    refreshed automatically, so long-running programs keep working.
        client = get_client()
        client.models.generate_content(model="gemini-3.5-flash-lite", contents=[image, "Describe this"])

    Not available: the Live API (real-time audio and video), and listing files or caches
    (everyone shares one key, so keep the names your own calls return).
    """
    _check_url()
    try:
        import httpx
        from google import genai
        from google.genai import types
    except ImportError:
        raise RuntimeError("Google's Gemini library isn't installed. Run ./dev.sh setup again "
                           "(or: pip install -r requirements.txt).") from None

    class _SignIn(httpx.Auth):
        def auth_flow(self, request):
            request.headers.update(_auth_header())
            yield request

    return genai.Client(
        api_key="not-used-gemini-app-adds-the-key",
        http_options=types.HttpOptions(
            base_url=APP_URL,
            httpx_client=httpx.Client(auth=_SignIn(), timeout=timeout),
            httpx_async_client=httpx.AsyncClient(auth=_SignIn(), timeout=timeout),
        ),
    )


# ---------------------------------------------------------------------------
# Other APIs your admin added (./admin.sh add-key NAME)
# ---------------------------------------------------------------------------
class ApiClient:
    """Calls an outside API through gemini-app, which attaches the key for you.

    Use paths and bodies exactly as in that API's documentation, without the key:
        r = api("openai").post("/v1/chat/completions", json={"model": "...", "messages": [...]})
        r.status_code, r.json()

    Returns a requests.Response. Errors from the API itself (e.g. 400, 429) come back as normal
    responses; problems with your access to gemini-app raise RuntimeError.
    """

    def __init__(self, name: str):
        self.name = name

    def request(self, method: str, path: str, **kwargs) -> requests.Response:
        _check_url()
        headers = dict(kwargs.pop("headers", None) or {})
        for k in list(headers):
            if k.lower() == "authorization":   # gemini-app supplies the API's key itself
                del headers[k]
        headers.update(_auth_header())
        url = f"{APP_URL}/proxy/{self.name}/{path.lstrip('/')}"
        r = requests.request(method, url, headers=headers, timeout=kwargs.pop("timeout", 300), **kwargs)
        ctype = r.headers.get("Content-Type", "")
        # Responses from gemini-app itself (not the outside API): sign-in, access, unknown name.
        if r.status_code in (401, 403) and "json" not in ctype:
            raise RuntimeError(f"{r.status_code}: your account can't use gemini-app. Run 'gcloud auth login' "
                               "with the account your admin approved, or ask your admin for access.")
        if r.status_code == 404 and "json" in ctype and "No API key named" in r.text:
            raise RuntimeError(r.json()["error"])
        return r

    def get(self, path, **kw):    return self.request("GET", path, **kw)
    def post(self, path, **kw):   return self.request("POST", path, **kw)
    def put(self, path, **kw):    return self.request("PUT", path, **kw)
    def patch(self, path, **kw):  return self.request("PATCH", path, **kw)
    def delete(self, path, **kw): return self.request("DELETE", path, **kw)

    def __repr__(self):
        return f"ApiClient({self.name!r})"


def api(name: str) -> ApiClient:
    """An outside API your admin added, by the name they gave you (e.g. api("openai"))."""
    return ApiClient(name)


def list_apis() -> list:
    """Names of the other APIs your admin added."""
    return [a["name"] for a in _call("GET", "/apis")["apis"]]
