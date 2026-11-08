"""Build an r2modman / Thunderstore-format zip of the mod, for r2modman's "Import local mod".

  usage: python tools/package_r2.py            -> dist/Anto640-EngineSim-<version>.zip

r2modman only lists mods recorded in its profile's mods.yml; a folder copied into the profile by hand loads in game
but never shows in the manager. Importing this zip registers it (installed as mods/Anto640-EngineSim/). The zip holds
the mod files at its root plus the three files Thunderstore requires: manifest.json, icon.png (256x256), README.md.
Version comes from your_mod.json, so bump it there.
"""
import json, os, zipfile
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD_DIRS = ["core", "engine", "model", "ui", "util"]
MOD_FILES = ["main.lua", "your_mod.json", "config.lua"]
AUTHOR, NAME = "Anto640", "EngineSim"

def icon_png():
    img = Image.new("RGB", (256, 256), (0x4F, 0x86, 0xC6))
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.load_default(size=110)
    except TypeError:
        font = ImageFont.load_default()
    box = d.textbbox((0, 0), "ES", font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text(((256 - w) / 2 - box[0], (256 - h) / 2 - box[1]), "ES", fill=(255, 255, 255), font=font)
    from io import BytesIO
    b = BytesIO(); img.save(b, "PNG"); return b.getvalue()

def main():
    meta = json.load(open(os.path.join(ROOT, "your_mod.json"), encoding="utf-8"))
    version = meta["version"]
    manifest = {
        "name": NAME,
        "version_number": version,
        "website_url": "https://github.com/Anto640/balatro-engine-sim",
        "description": "Decision assistant: recommends the best play, discard, shop and pack choice, and can self-play runs (F11).",
        "dependencies": [],
    }
    readme = ("# Engine Sim - Decision Assistant\n\n" + meta["description"] +
              "\n\nRequires Steamodded and Lovely. Source: https://github.com/Anto640/balatro-engine-sim\n")
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", "%s-%s-%s.zip" % (AUTHOR, NAME, version))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps(manifest, indent=2))
        z.writestr("icon.png", icon_png())
        z.writestr("README.md", readme)
        for f in MOD_FILES:
            z.write(os.path.join(ROOT, f), f)
        for d in MOD_DIRS:
            for dp, _, fs in os.walk(os.path.join(ROOT, d)):
                for f in sorted(fs):
                    full = os.path.join(dp, f)
                    z.write(full, os.path.relpath(full, ROOT).replace(os.sep, "/"))
    print(out)

if __name__ == "__main__":
    main()
