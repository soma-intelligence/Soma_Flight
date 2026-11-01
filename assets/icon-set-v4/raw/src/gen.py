import base64, json, subprocess, sys, urllib.request, uuid, pathlib, time
OUT = pathlib.Path("/Users/quentin/Desktop/Soma/Soma_Flight/assets/icon-set-v4/raw")
LOG = pathlib.Path(__file__).parent / "calls.log"
DEP = "gpt-image-2.5-flare"
BG = {}
BASE = "https://temple-ai-provider.cognitiveservices.azure.com/openai/deployments/%s/images/%s?api-version=2025-04-01-preview"
COMMON = (" Absolutely no text, no letters, no numbers, no logos, no brand marks, no airline livery, no stripes, no flags, "
  "no registration marks, no watermark, no ground, no cast shadow.")
def key():
    return subprocess.check_output(["az","cognitiveservices","account","keys","list","-n","temple-ai-provider",
        "-g","temple-ai-rg","--query","key1","-o","tsv"], text=True).strip()
def call(name, prompt, refs=(), k=None):
    k = k or key()
    with open(LOG,"a") as f: f.write(f"{time.strftime('%X')} {name} refs={len(refs)}\n")
    fields = {"prompt": prompt + COMMON, "background": BG.get(name, "opaque"), "size": "1024x1024", "quality": "high", "output_format": "png", "n": "1"}
    if refs:
        b = uuid.uuid4().hex; body = b""
        for f_, v in fields.items():
            body += f"--{b}\r\nContent-Disposition: form-data; name=\"{f_}\"\r\n\r\n{v}\r\n".encode()
        for r_ in refs:
            p = pathlib.Path(r_)
            body += (f"--{b}\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"{p.name}\"\r\n"
                     f"Content-Type: image/png\r\n\r\n").encode() + p.read_bytes() + b"\r\n"
        body += f"--{b}--\r\n".encode()
        req = urllib.request.Request(BASE % (DEP, "edits"), data=body, method="POST",
              headers={"api-key": k, "Content-Type": f"multipart/form-data; boundary={b}"})
    else:
        req = urllib.request.Request(BASE % (DEP, "generations"), data=json.dumps({**fields, "n": 1}).encode(), method="POST",
              headers={"api-key": k, "Content-Type": "application/json"})
    for attempt in range(6):
        try:
            r = json.load(urllib.request.urlopen(req, timeout=600)); break
        except urllib.error.HTTPError as e:
            msg = e.read()[:400].decode(errors="replace")
            if e.code == 429: time.sleep(40); continue
            print(name, "HTTP", e.code, msg, flush=True); return
        except Exception as e:
            print(name, "retry", e, flush=True); time.sleep(15)
    else: return
    out = OUT / f"{name}.png"; out.write_bytes(base64.b64decode(r["data"][0]["b64_json"])); print(name, "->", out, flush=True)
if __name__ == "__main__":
    jobs = json.load(open(sys.argv[1]))
    BG.update({j["name"]: j.get("bg","opaque") for j in jobs})
    k = key()
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(4) as ex:
        list(ex.map(lambda j: call(j["name"], j["prompt"], j.get("refs", []), k), jobs))
