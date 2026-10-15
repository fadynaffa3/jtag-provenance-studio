#!/usr/bin/env python3
"""Report AI-provenance signals in images and Illustrator/PDF files. Read-only.

For every input it reports:
  * metadata -- EXIF/XMP/IPTC/PNG-text/JPEG-comment/PDF fields that name an AI
    tool, carry generation settings (prompts, "Steps: .. Sampler: ..", Midjourney
    flags, ComfyUI graphs) or an AI digital source type (exiftool), plus file
    names that generators give their downloads ("ChatGPT Image ...");
  * C2PA -- a Content Credentials manifest, its claim generator and any
    AI actions/ingredients it declares (c2patool);
  * invisible watermarks the public can decode locally:
      - Adobe TrustMark (the open C2PA soft-binding watermark), variants Q and P;
      - the Stable Diffusion 1.x/2.x and SDXL `invisible-watermark` marks.
    Proprietary marks (Google SynthID, Meta, OpenAI) have no public decoder,
    so the report says they were not checkable rather than "absent".

An .ai or .pdf is inspected as a container (its own XMP and C2PA) and its
embedded images are extracted with pdfimages into --work and inspected too.
Embedded images usually lose their original metadata when placed in
Illustrator, so watermarks are the only signal they can still carry.

With --strip and/or --sign, every input is also written to the output folder
(--out, default ~/ai-provenance/output) and the copy is re-inspected. Inputs
are never modified.
  --strip  removes flagged tags. Images: all metadata and C2PA are dropped
           (exiftool), keeping the colour profile and orientation. .ai/.pdf:
           the flagged XMP entries and document properties are blanked in place
           (same length), so the file stays valid and Illustrator-editable
           without being rewritten. Placed images that keep their own EXIF
           inside the file are listed, to be replaced in Illustrator.
  --rename gives output copies with AI-generator file names a neutral name.
           Invisible watermarks are pixel data, not tags, and are left as is.
  --sign   embeds Content Credentials signed by the identity of the person
           using this Mac (set up once with --create-identity "Name"; kept in
           ~/Library/Application Support/JTag Provenance Studio/identity). When AI
           content was detected (or --ai), the manifest declares it; that
           can't be turned off. PDF/.ai can't carry an embedded manifest, so
           sign the exported images.

Usage:
  .venv/bin/python detect_ai_provenance.py INPUT... [--work DIR] [--json OUT]
                                           [--min-side 256] [--no-watermarks]
                                           [--strip [OUTDIR]] [--sign] [--rename] [--ai] [--out DIR]
  .venv/bin/python detect_ai_provenance.py --create-identity "Your Name"
"""
from __future__ import annotations

import argparse
import hashlib
import json
import mmap
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".heic", ".avif", ".gif", ".bmp", ".jp2"}
CONTAINER_SUFFIXES = {".ai", ".pdf"}

# IPTC DigitalSourceType values for generated or AI-composited media.
AI_SOURCE_TYPES = ("trainedAlgorithmicMedia", "compositeWithTrainedAlgorithmicMedia",
                   "algorithmicMedia", "compositeSynthetic")
AI_TOOL_PATTERN = re.compile(
    r"firefly|generative (fill|expand|edit|remove)|midjourney|niji ?journey|dall[-·]?e|openai|chatgpt|"
    r"gpt[- ]?image|gpt-4o|sora\b|stable ?diffusion|stability ?ai|dreamstudio|clipdrop|\bsdxl\b|\bsd ?3(\.5)?\b|"
    r"comfyui|automatic1111|invokeai|fooocus|swarmui|novelai|leonardo\.ai|ideogram|imagen\b|gemini|google ai|"
    r"nano ?banana|synthid|bing image creator|copilot|microsoft designer|meta ai|imagined with ai|grok\b|"
    r"\bflux(\.1)?\b|black ?forest ?labs|runway ?(ml|gen)|\bkling\b|\bkrea\b|recraft|playground ?(ai|v\d)|"
    r"nightcafe|dream machine|luma ai|freepik ai|pikaso|canva (magic media|dream lab)|magic media|"
    r"seedream|jimeng|doubao|hunyuan|qwen[- ]?image|kolors|minimax|hailuo|image playground|galaxy ai|"
    r"magic editor|adobe gen ?ai|made with ai|ai[- ]generated|generated (by|with) ai|trainedalgorithmic|"
    r"c2pa|contentcredentials|jumbf",
    re.IGNORECASE,
)
# Generation settings that betray a generator even when no tool is named: Stable Diffusion UIs write
# "Steps: 30, Sampler: ..., CFG scale: ..." (often into EXIF UserComment), Midjourney "Job ID" and
# "--ar 16:9" flags, ComfyUI JSON graphs, NovelAI's "uc" field.
AI_PROMPT_PATTERN = re.compile(
    r"negative prompt:|steps: ?\d+, ?sampler|cfg scale: ?\d|denoising strength|\bseed: ?\d{3,}|"
    r"job ?id: ?[0-9a-f]{8}-|--(ar|aspect) \d+:\d+|--(v|niji|stylize|chaos|style raw)\b|"
    r"\"class_type\"|\"ksampler|\"sampler_name\"|\"uc\": ?\"|invokeai_metadata|sd-metadata|sui_image_params",
    re.IGNORECASE,
)
# Fields that commonly carry generation parameters or provenance even when no
# tool name matches (A1111 `parameters`, ComfyUI `prompt`/`workflow`, InvokeAI, SwarmUI, Fooocus).
AI_FIELD_NAMES = re.compile(r"digitalsourcetype|parameters$|prompt$|workflow$|c2pa|jumbf|credit$|aigenerat|"
                            r"invokeai|sd-metadata|sui_image_params|generation_data|fooocus", re.IGNORECASE)
# File names that generators give their downloads (ChatGPT, Gemini, Midjourney, ComfyUI, A1111, ...).
AI_FILE_NAME = re.compile(
    r"chatgpt image|dall[-·]?e|gemini_generated|midjourney|firefly|ideogram|leonardo|grok|\bflux|sora|"
    r"kling|stable[_ -]?diffusion|comfyui|generated[_ -]image|ai[_ -]generated|"
    r"_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|^\d{5}-\d+(-|\.)",  # Midjourney, A1111
    re.IGNORECASE,
)
PDF_INFO_ENTRY = re.compile(rb"/(Title|Subject|Keywords|Creator|Producer|Author)\s*(\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f\s]*>)")

XMP_PACKET = re.compile(rb"<\?xpacket begin.*?<\?xpacket end[^>]*\?>", re.DOTALL)
XMP_LIST_ITEM = re.compile(rb"<rdf:li\b[^>]*>(?:(?!<rdf:li\b|</rdf:li>).)*</rdf:li>", re.DOTALL)  # innermost
XMP_ATTRIBUTE = re.compile(rb"""\s[\w.-]+:[\w.-]+=(?:"[^"]*"|'[^']*')""")
XMP_ELEMENT = re.compile(rb"<([\w.-]+:[\w.-]+)\b[^>]*>[^<]*</\1>")

IDENTITY_HOME = Path.home() / "Library" / "Application Support" / "JTag Provenance Studio" / "identity"
_OLD_IDENTITY_HOME = Path.home() / "Library" / "Application Support" / "Provenance Studio" / "identity"
if _OLD_IDENTITY_HOME.exists() and not IDENTITY_HOME.exists():  # from before the app was renamed
    IDENTITY_HOME.parent.mkdir(parents=True, exist_ok=True)
    _OLD_IDENTITY_HOME.rename(IDENTITY_HOME)
SIGNABLE_SUFFIXES = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp", ".heic", ".avif", ".gif"}
IPTC_SOURCE = "http://cv.iptc.org/newscodes/digitalsourcetype/"
TIMESTAMP_URL = "http://timestamp.digicert.com"

SD_V1_PAYLOAD = b"StableDiffusionV1"
SDXL_BITS = [int(b) for b in "101100111110110010010000011110111011000110011110"]


@dataclass
class Report:
    path: str
    kind: str
    metadata_hits: dict[str, str] = field(default_factory=dict)
    c2pa: dict | None = None
    watermarks: dict[str, str] = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    @property
    def flagged(self) -> bool:
        return bool(self.metadata_hits or self.c2pa or any(v.startswith("PRESENT") for v in self.watermarks.values()))


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def metadata_hits(path: Path) -> dict[str, str]:
    result = run(["exiftool", "-j", "-G1", "-a", "-u", "-struct", "-api", "LargeFileSupport=1", str(path)])
    if result.returncode not in (0, 1) or not result.stdout.strip():
        return {"exiftool": f"failed: {result.stderr.strip()[:200]}"}
    hits = {}
    for key, value in flatten(json.loads(result.stdout)[0]):
        text = str(value)
        if key == "SourceFile" or key.startswith(("System:", "ExifTool:")):  # File: stays: it holds the JPEG comment
            continue
        if AI_FIELD_NAMES.search(key) or looks_ai(text):
            hits[key] = text[:300]
    if AI_FILE_NAME.search(path.name):
        hits["FileName"] = f"{path.name} (name given by an AI generator)"
    return hits


def looks_ai(text: str) -> bool:
    return bool(AI_TOOL_PATTERN.search(text) or AI_PROMPT_PATTERN.search(text)) or any(t in text for t in AI_SOURCE_TYPES)


def flatten(obj, prefix=""):
    if isinstance(obj, dict):
        for key, value in obj.items():
            yield from flatten(value, f"{prefix}{key}" if not prefix else f"{prefix}.{key}")
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            yield from flatten(value, f"{prefix}[{index}]")
    else:
        yield prefix, obj


def c2pa_manifest(path: Path) -> dict | None:
    result = run(["c2patool", str(path)])
    if result.returncode != 0 or not result.stdout.strip().startswith("{"):
        return None
    store = json.loads(result.stdout)
    active = store.get("manifests", {}).get(store.get("active_manifest", ""), {})
    actions = []
    for assertion in active.get("assertions", []):
        if assertion.get("label", "").startswith("c2pa.actions"):
            for action in assertion.get("data", {}).get("actions", []):
                actions.append({k: action[k] for k in ("action", "softwareAgent", "digitalSourceType") if k in action})
    return {
        "claim_generator": active.get("claim_generator") or active.get("claim_generator_info"),
        "title": active.get("title"),
        "signature_issuer": active.get("signature_info", {}).get("issuer"),
        "actions": actions,
        "ingredients": [i.get("title") for i in active.get("ingredients", [])],
        "validation_status": [s.get("code") for s in store.get("validation_status", [])],
    }


class WatermarkDecoders:
    """Loaded once: TrustMark pulls model weights on first use."""

    def __init__(self):
        self.trustmark = {}
        try:
            from trustmark import TrustMark
            for variant in ("Q", "P"):
                # Decoder only: the package would otherwise also load its remover model.
                self.trustmark[variant] = TrustMark(verbose=False, model_type=variant, loadRemover=False)
        except Exception as error:  # noqa: BLE001 -- report, don't abort the scan
            self.trustmark_error = str(error)
        else:
            self.trustmark_error = None

    def check(self, path: Path) -> dict[str, str]:
        from PIL import Image
        import numpy as np

        results = {}
        with Image.open(path) as image:
            rgb = image.convert("RGB")
        for variant, decoder in self.trustmark.items():
            try:
                secret, present, schema = decoder.decode(rgb, MODE="binary")
                results[f"TrustMark-{variant}"] = f"PRESENT (schema {schema}, payload {secret})" if present else "absent"
            except Exception as error:  # noqa: BLE001
                results[f"TrustMark-{variant}"] = f"error: {error}"
        if self.trustmark_error:
            results["TrustMark"] = f"not checked: {self.trustmark_error}"

        bgr = np.array(rgb)[:, :, ::-1].copy()
        results.update(self.stable_diffusion(bgr))
        results["SynthID/Meta/OpenAI"] = "not checkable locally (no public decoder)"
        return results

    @staticmethod
    def stable_diffusion(bgr) -> dict[str, str]:
        from imwatermark import WatermarkDecoder
        results = {}
        try:
            decoded = WatermarkDecoder("bytes", len(SD_V1_PAYLOAD) * 8).decode(bgr, "dwtDct")
            results["StableDiffusion-v1/v2"] = "PRESENT" if decoded == SD_V1_PAYLOAD else "absent"
            bits = WatermarkDecoder("bits", len(SDXL_BITS)).decode(bgr, "dwtDct")
            matching = sum(int(a == b) for a, b in zip(bits, SDXL_BITS))
            # The mark is fragile; a near-match still means it was there.
            results["StableDiffusion-XL"] = (f"PRESENT ({matching}/{len(SDXL_BITS)} bits)"
                                             if matching >= len(SDXL_BITS) - 4 else "absent")
        except Exception as error:  # noqa: BLE001
            results["StableDiffusion"] = f"error: {error}"
        return results


def names_ai(text: bytes) -> bool:
    decoded = text.decode("utf-8", "replace")
    return looks_ai(decoded) or bool(AI_FILE_NAME.search(decoded))


def pdf_string(raw: bytes) -> str:
    """Decode a PDF literal (...) or hex <...> string, enough to pattern-match it."""
    if raw.startswith(b"<"):
        data = bytes.fromhex(re.sub(rb"\s", b"", raw[1:-1]).decode())
    else:
        data = re.sub(rb"\\(.)", rb"\1", raw[1:-1])
    return data[2:].decode("utf-16-be", "replace") if data.startswith(b"\xfe\xff") else data.decode("latin-1")


def scrub_pdf_info(data: mmap.mmap) -> int:
    """Blank AI-naming document properties (Title, Keywords, Creator, ...) with spaces, same length."""
    removed = 0
    for match in PDF_INFO_ENTRY.finditer(data):
        value = match.group(2)
        if not names_ai(pdf_string(value).encode()):
            continue
        if value.startswith(b"<"):
            blanked = b"<" + re.sub(rb"[0-9A-Fa-f]{2}", b"20", value[1:-1]) + b">"
        else:
            blanked = b"(" + b" " * (len(value) - 2) + b")"
        data[match.start(2):match.end(2)] = blanked
        removed += 1
    return removed


def scrub_xmp(packet: bytes) -> tuple[bytes, int]:
    """Blank AI-naming list items, attributes and elements with spaces: same length, still valid XMP."""
    removed = 0

    def blank(match: re.Match, name: bytes | None = None) -> bytes:
        nonlocal removed
        if name is not None and name.startswith(b"xmlns:"):
            return match.group(0)  # namespace declarations stay, or the remaining XML breaks
        named = name is not None and AI_FIELD_NAMES.search(name.decode("utf-8", "replace"))
        if not (named or names_ai(match.group(0))):
            return match.group(0)
        removed += 1
        return re.sub(rb"[^\n]", b" ", match.group(0))

    packet = XMP_LIST_ITEM.sub(blank, packet)
    packet = XMP_ATTRIBUTE.sub(lambda m: blank(m, m.group(0).split(b"=", 1)[0].strip()), packet)
    packet = XMP_ELEMENT.sub(lambda m: blank(m, m.group(1)), packet)
    return packet, removed


def strip_container(source: Path, target: Path) -> str:
    """Copy, then overwrite each XMP packet with its scrubbed twin at the same offset."""
    shutil.copyfile(source, target)
    removed = 0
    with open(target, "r+b") as handle, mmap.mmap(handle.fileno(), 0) as data:
        for match in XMP_PACKET.finditer(data):
            cleaned, count = scrub_xmp(match.group(0))
            if count:
                data[match.start():match.end()] = cleaned
                removed += count
        properties = scrub_pdf_info(data)
        data.flush()
    return f"{removed} XMP entries and {properties} document properties blanked"


def strip_image(source: Path, target: Path) -> str:
    target.unlink(missing_ok=True)
    result = run(["exiftool", "-all=", "--icc_profile:all", "-tagsfromfile", "@", "-Orientation",
                  "-o", str(target), str(source)])
    if result.returncode != 0:
        return f"exiftool failed: {result.stderr.strip()[:200]}"
    return "all metadata and C2PA removed (colour profile and orientation kept)"


def create_identity(name: str, home: Path = IDENTITY_HOME) -> str:
    """A signing certificate for the person using this Mac: a private root plus a signer issued by it.
    The root key is deleted afterwards, so nothing else can be issued from it."""
    name = re.sub(r"[/\\=+,;\"<>]", " ", name).strip()
    if not name:
        raise SystemExit("an identity needs a name")
    home.mkdir(parents=True, exist_ok=True)
    home.chmod(0o700)
    ext = home / "signer.ext"
    ext.write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                   "extendedKeyUsage=emailProtection\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n")
    ssl = shutil.which("openssl", path="/opt/homebrew/bin:/usr/local/bin:/usr/bin") or "openssl"
    f = lambda n: str(home / n)  # noqa: E731
    steps = [
        [ssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", f("root.key")],
        [ssl, "req", "-x509", "-new", "-key", f("root.key"), "-sha256", "-days", "3650",
         "-subj", f"/CN={name} Root/O={name}", "-addext", "basicConstraints=critical,CA:TRUE",
         "-addext", "keyUsage=critical,keyCertSign,cRLSign", "-out", f("root.pem")],
        [ssl, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", f("signer.key")],
        [ssl, "pkcs8", "-topk8", "-nocrypt", "-in", f("signer.key"), "-out", f("signer.p8")],
        [ssl, "req", "-new", "-key", f("signer.key"), "-subj", f"/CN={name}/O={name}", "-out", f("signer.csr")],
        [ssl, "x509", "-req", "-in", f("signer.csr"), "-CA", f("root.pem"), "-CAkey", f("root.key"),
         "-set_serial", str(int(datetime.now().timestamp())), "-days", "1825", "-sha256",
         "-extfile", f("signer.ext"), "-out", f("signer.pem")],
    ]
    for step in steps:
        result = run(step)
        if result.returncode != 0:
            raise SystemExit(f"identity setup failed at `{step[1]}`: {result.stderr.strip()[:300]}")
    (home / "chain.pem").write_text((home / "signer.pem").read_text() + (home / "root.pem").read_text())
    for leftover in ("root.key", "signer.key", "signer.csr", "signer.ext"):
        (home / leftover).unlink(missing_ok=True)
    (home / "signer.p8").chmod(0o600)
    (home / "identity.json").write_text(json.dumps({"name": name, "created": datetime.now().isoformat(timespec="seconds")}))
    return name


def identity(home: Path = IDENTITY_HOME) -> dict | None:
    file = home / "identity.json"
    return json.loads(file.read_text()) if file.exists() and (home / "signer.p8").exists() else None


def sign_file(target: Path, ai: bool, parent: Path | None, home: Path = IDENTITY_HOME) -> str:
    """Embed a Content Credentials manifest signed by this Mac's identity. AI content is always declared."""
    who = identity(home)
    if who is None:
        return "not signed: no signing identity set up yet"
    if target.suffix.lower() not in SIGNABLE_SUFFIXES:
        return f"not signed: Content Credentials can't be embedded in {target.suffix} files; sign the exported images"
    source_type = "compositeWithTrainedAlgorithmicMedia" if ai else "digitalCreation"
    manifest = {
        "alg": "es256", "private_key": str(home / "signer.p8"), "sign_cert": str(home / "chain.pem"),
        "ta_url": TIMESTAMP_URL,
        "claim_generator_info": [{"name": "JTag Provenance Studio", "version": "1.1"}],
        "title": target.name,
        "assertions": [
            {"label": "c2pa.actions",
             "data": {"actions": [{"action": "c2pa.created", "digitalSourceType": IPTC_SOURCE + source_type}]}},
            {"label": "stds.schema-org.CreativeWork",
             "data": {"@context": "https://schema.org", "@type": "CreativeWork",
                      "author": [{"@type": "Person", "name": who["name"]}]}},
        ],
    }
    signed = target.with_name(f".signing-{target.name}")
    manifest_file = target.with_name(f".manifest-{target.stem}.json")
    try:
        for attempt in (manifest, {k: v for k, v in manifest.items() if k != "ta_url"}):  # offline: no timestamp
            manifest_file.write_text(json.dumps(attempt))
            cmd = ["c2patool", str(target), "-m", str(manifest_file), "-o", str(signed), "-f"]
            result = run(cmd + (["-p", str(parent)] if parent else []))
            if result.returncode == 0:
                signed.replace(target)
                stamped = "timestamped" if "ta_url" in attempt else "no timestamp (offline)"
                return f"signed by {who['name']}, {'AI content declared' if ai else 'no AI declared'}, {stamped}"
        return f"signing failed: {(result.stderr or result.stdout).strip()[:300]}"
    finally:
        manifest_file.unlink(missing_ok=True)
        signed.unlink(missing_ok=True)


def make_output(report: Report, out_dir: Path, strip: bool, sign: bool, ai: bool, rename: bool = False,
                embedded: list[Report] = ()) -> Report:
    """Write the output copy: tags stripped and/or signed. The input is never modified."""
    source = Path(report.path)
    name = source.name
    if rename and AI_FILE_NAME.search(name):
        name = f"image-{hashlib.sha1(name.encode()).hexdigest()[:8]}{source.suffix.lower()}"
    target = out_dir / name
    if target.resolve() == source.resolve():
        raise SystemExit(f"the output would overwrite the input {source}; choose another output folder")
    out_dir.mkdir(parents=True, exist_ok=True)
    notes = []
    tagged = bool(report.metadata_hits or report.c2pa)
    if strip and tagged:
        container = source.suffix.lower() in CONTAINER_SUFFIXES
        notes.append(strip_container(source, target) if container else strip_image(source, target))
    else:
        shutil.copyfile(source, target)
        if strip:
            notes.append("no AI tags to remove")
    if sign:
        # Keep an existing manifest's history as the parent unless it was just stripped.
        notes.append(sign_file(target, ai, source if report.c2pa and not strip else None))
    if name != source.name:
        notes.append(f"renamed from {source.name}")
    out = Report(str(target), "output", metadata_hits(target), c2pa_manifest(target), notes=notes)
    carrying = [Path(r.path).name for r in embedded if r.metadata_hits]
    if strip and carrying:
        out.notes.append(f"{len(carrying)} placed image(s) keep their own metadata inside the file "
                         f"({', '.join(carrying[:5])}); replace them in Illustrator with cleaned copies")
    if strip and tagged and source.suffix.lower() in CONTAINER_SUFFIXES and out.c2pa:
        out.notes.append("C2PA inside a PDF/AI can't be removed in place; re-export it without Content Credentials")
    return out


def extract_embedded(container: Path, work: Path) -> list[Path]:
    target = work / container.stem
    target.mkdir(parents=True, exist_ok=True)
    if not any(target.iterdir()):
        result = run(["pdfimages", "-all", str(container), str(target / "img")])
        if result.returncode != 0:
            print(f"pdfimages failed on {container}: {result.stderr.strip()[:200]}", file=sys.stderr)
    return sorted(p for p in target.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES)


def large_enough(path: Path, min_side: int) -> bool:
    from PIL import Image
    try:
        with Image.open(path) as image:
            return min(image.size) >= min_side and image.mode not in ("1", "L", "LA", "P")
    except Exception:  # noqa: BLE001 -- unreadable: let the metadata pass report it
        return False


def inspect_image(path: Path, decoders: WatermarkDecoders | None, min_side: int, kind="image") -> Report:
    report = Report(str(path), kind, metadata_hits(path), c2pa_manifest(path))
    if decoders is None:
        report.notes.append("watermarks not checked (--no-watermarks)")
    elif not large_enough(path, min_side):
        report.notes.append(f"watermarks skipped: smaller than {min_side}px, or a mask/indexed graphic")
    else:
        report.watermarks = decoders.check(path)
    return report


def gather(inputs: list[str]) -> list[Path]:
    paths = []
    for raw in inputs:
        path = Path(raw).expanduser()
        if path.is_dir():
            paths += sorted(p for p in path.rglob("*")
                            if p.suffix.lower() in IMAGE_SUFFIXES | CONTAINER_SUFFIXES)
        elif path.exists():
            paths.append(path)
        else:
            print(f"not found: {path}", file=sys.stderr)
    return paths


def print_report(report: Report) -> None:
    marker = "FLAGGED" if report.flagged else "clean  "
    print(f"\n[{marker}] {report.kind}: {report.path}")
    for key, value in report.metadata_hits.items():
        print(f"    meta  {key} = {value}")
    if report.c2pa:
        print(f"    c2pa  {json.dumps(report.c2pa, ensure_ascii=False)}")
    for name, verdict in report.watermarks.items():
        if verdict != "absent" or report.flagged:
            print(f"    wm    {name}: {verdict}")
    for note in report.notes:
        print(f"    note  {note}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="*")
    parser.add_argument("--work", default=str(Path.home() / "ai-provenance" / "work"),
                        help="where embedded images of .ai/.pdf files are extracted")
    parser.add_argument("--json", help="also write the full report as JSON here")
    parser.add_argument("--min-side", type=int, default=256, help="smallest image side worth a watermark check")
    parser.add_argument("--no-watermarks", action="store_true", help="metadata and C2PA only (fast)")
    parser.add_argument("--strip", nargs="?", const="", metavar="OUTDIR",
                        help="write copies with the AI metadata/C2PA tags removed (to OUTDIR or --out)")
    parser.add_argument("--sign", action="store_true",
                        help="write copies signed with this Mac's Content Credentials identity")
    parser.add_argument("--rename", action="store_true",
                        help="give output copies with AI-generator file names (\"ChatGPT Image ...\") a neutral name")
    parser.add_argument("--ai", action="store_true", help="declare AI content even if none is detected")
    parser.add_argument("--out", default=str(Path.home() / "ai-provenance" / "output"), help="output folder")
    parser.add_argument("--create-identity", metavar="NAME", help="set up the signing identity for this Mac's user")
    parser.add_argument("--show-identity", action="store_true", help="print the signing identity as JSON")
    args = parser.parse_args()

    if args.create_identity:
        print(json.dumps({"name": create_identity(args.create_identity)}))
        return 0
    if args.show_identity:
        print(json.dumps(identity()))
        return 0
    if not args.inputs:
        parser.error("no inputs")
    strip = args.strip is not None
    out_dir = Path(args.strip or args.out).expanduser()
    if args.sign and identity() is None:
        raise SystemExit("--sign needs a signing identity first: --create-identity \"Your Name\"")

    decoders = None if args.no_watermarks else WatermarkDecoders()
    work = Path(args.work).expanduser()
    reports, outputs = [], []

    def maybe_output(report: Report, ai_found: bool, embedded: list[Report] = ()) -> None:
        if strip or args.sign:
            outputs.append(make_output(report, out_dir, strip, args.sign, ai_found or args.ai, args.rename, embedded))
            print_report(outputs[-1])

    for path in gather(args.inputs):
        if path.suffix.lower() in CONTAINER_SUFFIXES:
            container = Report(str(path), "container", metadata_hits(path), c2pa_manifest(path))
            reports.append(container)
            print_report(container)
            embedded = []
            for image in extract_embedded(path, work):
                embedded.append(inspect_image(image, decoders, args.min_side, kind=f"embedded in {path.name}"))
                print_report(embedded[-1])
            reports += embedded
            maybe_output(container, container.flagged or any(r.flagged for r in embedded), embedded)
        else:
            reports.append(inspect_image(path, decoders, args.min_side))
            print_report(reports[-1])
            maybe_output(reports[-1], reports[-1].flagged)
        sys.stdout.flush()

    flagged = sum(r.flagged for r in reports)
    print(f"\n{len(reports)} inspected, {flagged} flagged.")
    if outputs:
        print(f"{len(outputs)} output copies in {out_dir}.")
    reports += outputs
    if args.json:
        Path(args.json).write_text(json.dumps([asdict(r) | {"flagged": r.flagged} for r in reports], indent=2))
        print(f"JSON report: {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
