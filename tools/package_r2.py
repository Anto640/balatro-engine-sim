"""Build an r2modman / Thunderstore-format zip of the mod, for r2modman's "Import local mod" and for Thunderstore.

  usage: python tools/package_r2.py            -> dist/Anto640-EngineSim-<version>.zip

r2modman only lists mods recorded in its profile's mods.yml; a folder copied into the profile by hand loads in game
but never shows in the manager. Importing this zip registers it (installed as mods/Anto640-EngineSim/). The zip holds
the mod files at its root plus the three files Thunderstore requires: manifest.json, icon.png (256x256), README.md.
Version comes from your_mod.json, so bump it there.

The same zip is what gets uploaded to Thunderstore (thunderstore.io/c/balatro, team "Anto640"), which is how r2modman
users find the mod. The Thunderstore page shows packaging/README.md (player-facing, absolute links only). The icon is
packaging/icon.png at any size, centre-cropped to a square and resized to 256x256 here (a plain generated icon if it is
missing). Only files tracked by git are packed, so local scratch inside core/ engine/ ... never ships.
"""
import json, os, re, subprocess, zipfile
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGING = os.path.join(ROOT, "packaging")
MOD_DIRS = ["core", "engine", "model", "ui", "util"]
MOD_FILES = ["main.lua", "your_mod.json", "config.lua"]
AUTHOR, NAME = "Anto640", "EngineSim"
# Thunderstore "Owner-Name-Version" strings: the minimum versions this was tested on (the maintainer's r2modman
# profile). Steamodded itself depends on lovely; listing both keeps the install explicit.
DEPENDENCIES = ["Steamodded-Steamodded-26.1002.0", "Thunderstore-lovely-0.10.0"]
DESCRIPTION = ("Decision assistant: recommends the best play, discard, shop and pack choice from your deck, "
               "and can play whole runs by itself (F11). Single-player only.")

def png_bytes(img):
    b = BytesIO(); img.save(b, "PNG"); return b.getvalue()

def icon_png():
    path = os.path.join(PACKAGING, "icon.png")
    if os.path.exists(path):
        img = Image.open(path).convert("RGBA")
        side = min(img.size)
        left, top = (img.width - side) // 2, (img.height - side) // 2
        return png_bytes(img.crop((left, top, left + side, top + side)).resize((256, 256), Image.LANCZOS))
    img = Image.new("RGB", (256, 256), (0x4F, 0x86, 0xC6))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=110)
    except TypeError:
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), "ES", font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((256 - w) / 2 - box[0], (256 - h) / 2 - box[1]), "ES", fill=(255, 255, 255), font=font)
    return png_bytes(img)

def tracked(rel_dir):
    out = subprocess.run(["git", "ls-files", "-z", "--", rel_dir], cwd=ROOT, capture_output=True, check=True)
    return sorted(f for f in out.stdout.decode("utf-8").split("\0") if f)

def main():
    meta = json.load(open(os.path.join(ROOT, "your_mod.json"), encoding="utf-8"))
    version = meta["version"]
    # Thunderstore's manifest rules: name [A-Za-z0-9_], version Major.Minor.Patch, description <= 250 chars.
    assert re.fullmatch(r"[A-Za-z0-9_]+", NAME), NAME
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), "your_mod.json version must be Major.Minor.Patch: " + version
    assert len(DESCRIPTION) <= 250, len(DESCRIPTION)
    manifest = {
        "name": NAME,
        "version_number": version,
        "website_url": "https://github.com/Anto640/balatro-engine-sim",
        "description": DESCRIPTION,
        "dependencies": DEPENDENCIES,
    }
    readme = open(os.path.join(PACKAGING, "README.md"), encoding="utf-8").read()
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", "%s-%s-%s.zip" % (AUTHOR, NAME, version))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest, indent=2))
        z.writestr("icon.png", icon_png())
        z.writestr("README.md", readme)
        for f in MOD_FILES:
            z.write(os.path.join(ROOT, f), f)
        for d in MOD_DIRS:
            for f in tracked(d):
                z.write(os.path.join(ROOT, f), f)
    print(out)

if __name__ == "__main__":
    main()
