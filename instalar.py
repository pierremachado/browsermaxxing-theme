#!/usr/bin/env python3
"""Install/restore Browsermaxxing CSS without replacing unrelated preferences."""
import argparse
import base64
import configparser
import hashlib
import json
import os
from pathlib import Path
import sys

SOURCE = Path(__file__).resolve().parent
ASSETS = tuple(sorted((SOURCE / "browsermaxxing").glob("*.css")))
PREF = 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'


def profiles():
    home = Path.home()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    roots = [home / ".librewolf", config_home / "librewolf",
             config_home / "librewolf/librewolf", home / ".mozilla/librewolf",
             home / ".var/app/io.gitlab.librewolf-community/.librewolf",
             home / ".var/app/io.gitlab.librewolf-community/.config/librewolf",
             home / ".var/app/io.gitlab.librewolf-community/.config/librewolf/librewolf"]
    result = []
    for root in roots:
        ini = root / "profiles.ini"
        if not ini.exists():
            continue
        config = configparser.ConfigParser(interpolation=None)
        config.read(ini)
        for section in config.sections():
            if not section.startswith("Profile") or not config.has_option(section, "Path"):
                continue
            raw = Path(config[section]["Path"])
            path = (root / raw if config[section].getboolean("IsRelative", True) else raw).resolve()
            if path.is_dir() and path not in result:
                result.append(path)
    return result


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_file(path):
    if path.is_symlink():
        raise ValueError(f"Arquivo gerenciado é um link simbólico: {path}")
    return path.read_bytes() if path.exists() else None


def checked_path(profile, relative):
    path = profile / relative
    if not path.resolve().is_relative_to(profile):
        raise ValueError(f"Caminho fora do perfil: {path}")
    return path


def check_current(profile, state):
    for relative, record in state["files"].items():
        data = read_file(checked_path(profile, relative))
        if data is None or digest(data) != record["installed_sha256"]:
            raise ValueError(f"Arquivo mudou após a instalação: {relative}. "
                             "Preservado; faça uma cópia antes de reconciliar as alterações.")


def write_file(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Preserve permissions on existing files; newly created settings stay private.
    mode = (path.stat().st_mode & 0o777) if path.exists() else 0o600
    temporary = path.with_name(path.name + ".browsermaxxing-tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as output:
        output.write(data)
    temporary.replace(path)


def run(args):
    if args.list_profiles:
        found = profiles()
        print("\n".join(map(str, found)) if found else "Nenhum perfil LibreWolf encontrado. Abra e feche o LibreWolf uma vez.")
        return
    if args.profile:
        profile = Path(args.profile).expanduser().resolve()
    elif args.librewolf:
        found = profiles()
        # Some installs create an empty legacy 'default' profile alongside the
        # initialized release profile. Do not mistake it for a usable target.
        found = [p for p in found if any((p / n).exists() for n in
                 ("prefs.js", "times.json", "compatibility.ini"))]
        if len(found) != 1:
            raise ValueError("É necessário um único perfil LibreWolf para seleção automática. "
                             "Use --list-profiles e depois --profile CAMINHO.")
        profile = found[0]
    else:
        raise ValueError("Informe --librewolf ou --profile CAMINHO.")
    if not profile.is_dir() or not any((profile / n).exists() for n in ("prefs.js", "times.json", "compatibility.ini")):
        raise ValueError("O diretório não parece um perfil inicializado. Abra e feche o navegador primeiro.")
    # Firefox uses a POSIX lock on Linux. Keep the lock for the whole install.
    lock = None
    if sys.platform.startswith("linux") and (profile / ".parentlock").exists():
        import fcntl
        lock = (profile / ".parentlock").open("r+")
        try:
            fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise ValueError("O navegador está aberto. Feche-o antes de alterar o tema.")
    state_path = checked_path(profile, "chrome/browsermaxxing/state.json")
    old = json.loads(state_path.read_text()) if state_path.exists() else None
    if old:
        if old.get("version") != 1:
            raise ValueError("Versão de backup desconhecida.")
        check_current(profile, old)
    if args.remove:
        if not old:
            raise ValueError("Este perfil não tem uma instalação gerenciada do tema.")
        for relative, record in old["files"].items():
            path = checked_path(profile, relative)
            if record["original"] is None:
                path.unlink()
            else:
                write_file(path, base64.b64decode(record["original"]))
        state_path.unlink()
        print("CSS e user.js anteriores restaurados. A preferência gravada em prefs.js pode continuar ativa; "
              "ela não aplica o tema removido. Se desejado, restaure-a manualmente em about:config.")
        return
    original = {}
    relatives = ["chrome/userChrome.css", "user.js"] + ["chrome/browsermaxxing/" + p.name for p in ASSETS]
    # Read/validate every destination before changing any file.
    for relative in relatives:
        path = checked_path(profile, relative)
        data = read_file(path)
        original[relative] = old["files"][relative]["original"] if old else (
            base64.b64encode(data).decode("ascii") if data is not None else None)
    def previous(relative):
        value = original[relative]
        return base64.b64decode(value) if value is not None else b""
    entry = (f'/* Browsermaxxing: managed imports. */\n'
             f'@import url("browsermaxxing/palette-{args.mode}.css");\n'
             f'@import url("browsermaxxing/theme.css");\n').encode()
    values = {"chrome/userChrome.css": entry + previous("chrome/userChrome.css"),
              "user.js": previous("user.js") + b"\n// Browsermaxxing: browser UI CSS only.\n" + PREF.encode() + b"\n"}
    values.update({"chrome/browsermaxxing/" + p.name: p.read_bytes() for p in ASSETS})
    state = {"version": 1, "mode": args.mode, "files": {
        relative: {"original": original[relative], "installed_sha256": digest(data)}
        for relative, data in values.items()}}
    # Save the complete restoration data before mutating settings.
    write_file(state_path, json.dumps(state, indent=2).encode())
    for relative, data in values.items():
        write_file(checked_path(profile, relative), data)
    print(f"Browsermaxxing instalado ({args.mode}): {profile}\nAbra o navegador para carregar o tema.")
    if lock:
        lock.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--profile", help="Diretório raiz do perfil, não o diretório de cache")
    target.add_argument("--librewolf", action="store_true", help="Seleciona se houver um único perfil LibreWolf")
    parser.add_argument("--list-profiles", action="store_true")
    parser.add_argument("--mode", choices=("dark", "light", "auto"), default="dark")
    parser.add_argument("--remove", action="store_true")
    try:
        run(parser.parse_args())
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"Erro: {error}\n")
