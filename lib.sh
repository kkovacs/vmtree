#!/bin/bash

# lib.sh is a small collection of bash helper functions
# to be used in install scripts.
#
# You can update lib.sh by running:
# curl -sLf -o lib.sh https://raw.githubusercontent.com/kkovacs/vmtree/master/lib.sh
#
# Function names always start with underscore,
# and are trying to be close to either the bash command name,
# or the Ansible function name they replicate.

# _lineinfile replaces or appends a line to a file.
# The intended use is to ensure one-line settings in config files.
# More info: https://kkovacs.eu/ansible-lineinfile-blockinfile-in-bash/
#
# Use: _lineinfile <regex> <replacement> <file>
#
# Example: _lineinfile 'HISTFILESIZE=' 'HISTFILESIZE=10000' ~/.bashrc
function _lineinfile() { local line=${2//\//\\/} ; sed -i -e '/'"${1//\//\\/}"'/{s/.*/'"${line}"'/;:a;n;ba;q};$a'"${line}" "$3" ; }

# _blockinfile replaces or appends a block in a file.
# The intended use is to ensure multi-line blocks in config files.
# Reads the desired block of text from stdin.
# Don't forget to put your "marks" on the first and last line of the block of text you are inserting,
# because they are not added automatically.
# More info: https://kkovacs.eu/ansible-lineinfile-blockinfile-in-bash/
#
# Use: _blockinfile <startmark> <endmark> <file>
#
# Example:
# _blockinfile STARTMARK ENDMARK filename <<EOF
# # STARTMARK
# some text to
# put inside
# # ENDMARK
# EOF
function _blockinfile() { sed -i -ne '/'"${1//\//\\/}"'/{r/dev/stdin' -e ':a;n;/'"${2//\//\\/}"'/{:b;n;p;bb};ba};p;$r/dev/stdin' "$3" ; }

# _cp copies a file,
# but shows a diff,
# and if there will be a change and running interactively,
# gives the user a chance to revisit.
#
# Use: _cp <src> <dest> [<install-options> ...]
_cp() {
	local src="$1"
	local dest="$2"
	local install_args=("${@:3}")
	if ! diff "$dest" "$src"; then
		# Give user a chance to revisit if interactive
		[[ -f "$dest" && -t 0 ]] && read -r -p "$dest: CTRL-C to abort, ENTER to continue"
		install "${install_args[@]}" "$src" "$dest"
	fi
}

# _template is a poor man's bash-based template engine.
# (But watch out for double backslashes.)
# If there will be a file change and running interactively,
# gives the user a chance to revisit.
#
# Use: _template <src> <dest> [<install-options> ...]
_template() {
	local src="$1"
	local dest="$2"
	local install_args=("${@:3}")
	local tmp="$(mktemp)"
	# No ident allowed here, sorry
	eval "cat <<EOF
$(<"$src")
EOF" >"$tmp"
	# Copy the file (with diff and confirmation)
	_cp "$tmp" "$dest" "${install_args[@]}"
	# Clean up
	rm "$tmp"
}
