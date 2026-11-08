#!/bin/sh
# Recovery uninstall for when `tmsm uninstall` can't run. Installed as ~/.tmsm/uninstall.sh.
#   /bin/sh ~/.tmsm/uninstall.sh
# Same rules as `tmsm uninstall`: it removes only what tmsm can prove is its own and refuses
# (and reports) anything uncertain, so the exit code is 1 if something was left alone.
#
# - the tmsm home ($TMSM_HOME, default ~/Library/Application Support/tmsm): only with its
#   .tmsm-home marker and nothing but models/, cache/, config.json in it
# - ~/.tmsm, ~/.tmsm.new, ~/.tmsm.old: only with a .tmsm-program manifest that lists everything
# - the PATH line marked "# tmsm" in .zprofile, .bash_profile, .bash_login, .profile (edited in
#   place, so symlinked files stay links and keep their permissions)
# - the fish snippet conf.d/tmsm.fish, only if it is exactly tmsm's
# - the Keychain item of service "tmsm", account "huggingface"
# - the account's ~/Library/Caches/tmsm and ~/Library/HTTPStorages/tmsm, which macOS creates
#   for the tmsm process
set -u

home="${HOME:?HOME is not set}"
failed=0
say() { printf '%s\n' "$*" >&2; }
refuse() { say "left alone: $*"; failed=1; }

# Everything in folder $1 (but .DS_Store) must be one of the names in $2 (newline-separated).
only_listed() {
  folder="$1"; allowed="$2"
  for entry in "$folder"/* "$folder"/.[!.]* "$folder"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    [ "$name" = .DS_Store ] && continue
    printf '%s\n' "$allowed" | grep -Fxq -- "$name" || { say "  not tmsm's: $entry"; return 1; }
  done
  return 0
}

# The manifest's listed items, plus the manifest itself.
manifest_items() {
  sed -n 's/^item //p' "$1/.tmsm-program"
  echo .tmsm-program
}

# Folders the install created (fish conf.d and parents), read before the program folder goes.
created=""
if [ -f "$home/.tmsm/.tmsm-program" ]; then
  created="$(sed -n 's/^created //p' "$home/.tmsm/.tmsm-program")"
fi

# 1. The tmsm home.
default_home="$home/Library/Application Support/tmsm"
tmsm_home="${TMSM_HOME:-$default_home}"
if [ -d "$tmsm_home" ]; then
  if [ ! -f "$tmsm_home/.tmsm-home" ]; then
    refuse "$tmsm_home (no .tmsm-home marker: tmsm did not create it)"
  elif only_listed "$tmsm_home" "$(printf 'models\ncache\nconfig.json\n.tmsm-home')"; then
    rm -rf "$tmsm_home" && say "removed $tmsm_home"
    if [ "$tmsm_home" = "$default_home" ]; then
      rmdir "$home/Library/Application Support" "$home/Library" 2>/dev/null || true
    fi
  else
    refuse "$tmsm_home"
  fi
fi

# 2. PATH lines (marked "# tmsm" and naming /.tmsm:), edited through symlinks.
for f in .zprofile .bash_profile .bash_login .profile; do
  p="$home/$f"
  [ -f "$p" ] || continue
  grep -q '/\.tmsm:.*# tmsm[[:space:]]*$' "$p" || continue
  tmp="$(mktemp)" || { refuse "$p (no temp file)"; continue; }
  grep -v '/\.tmsm:.*# tmsm[[:space:]]*$' "$p" > "$tmp"
  if [ ! -L "$p" ] && ! grep -q '[^[:space:]]' "$tmp"; then
    rm -f "$p" && say "removed $p (it held only the tmsm line)"
  elif cat "$tmp" > "$p"; then
    say "removed the tmsm line from $p"
  else
    refuse "$p (could not write it)"
  fi
  rm -f "$tmp"
done

# 3. The fish snippet, only if it is exactly ours; then the folders the install created.
config="${XDG_CONFIG_HOME:-$home/.config}"
case "$config" in /*) ;; *) config="$home/.config" ;; esac
fish_file="$config/fish/conf.d/tmsm.fish"
if [ -e "$fish_file" ]; then
  expected="$(mktemp)"
  # Must match Installer.fishSnippet byte for byte.
  printf '%s\n' \
    '# tmsm: added by `tmsm install`, removed by `tmsm uninstall`.' \
    'if not contains -- $HOME/.tmsm $PATH' \
    '    set -gx PATH $HOME/.tmsm $PATH' \
    'end' > "$expected"
  if cmp -s "$fish_file" "$expected"; then
    rm -f "$fish_file" && say "removed $fish_file"
    printf '%s\n' "$created" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- |
      while IFS= read -r dir; do [ -n "$dir" ] && rmdir "$dir" 2>/dev/null; done
  else
    refuse "$fish_file (not tmsm's snippet)"
  fi
  rm -f "$expected"
fi

# 4. The program folders, only with a manifest that lists everything in them.
for d in "$home/.tmsm" "$home/.tmsm.new" "$home/.tmsm.old"; do
  [ -e "$d" ] || continue
  if [ ! -f "$d/.tmsm-program" ]; then
    refuse "$d (no .tmsm-program manifest)"
  elif only_listed "$d" "$(manifest_items "$d")"; then
    rm -rf "$d" && say "removed $d"
  else
    refuse "$d"
  fi
done

# 5. The Keychain item (tmsm's own account only). Tests set TMSM_SKIP_KEYCHAIN=1.
if [ "${TMSM_SKIP_KEYCHAIN:-0}" != 1 ]; then
  if security delete-generic-password -s tmsm -a huggingface >/dev/null 2>&1; then
    say "removed the Keychain item tmsm/huggingface"
  fi
fi

# 6. The folders macOS creates for the tmsm process, in the account's home (not $HOME).
account="${TMSM_ACCOUNT_HOME:-$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')}"
if [ -n "$account" ]; then
  for d in "$account/Library/Caches/tmsm" "$account/Library/HTTPStorages/tmsm"; do
    [ -e "$d" ] && rm -rf "$d" && say "removed $d"
  done
fi

if [ "$failed" = 0 ]; then say "tmsm removed."; else say "tmsm removed, apart from what is listed as left alone."; fi
exit "$failed"
