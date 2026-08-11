return [==[#!/usr/bin/env bash
# Compare two files or directories and print a human-readable report.
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: compare.sh <path-a> <path-b>
EOF
	exit 2
}

[[ $# -eq 2 ]] || usage

a=$1
b=$2

if [[ ! -e $a ]]; then
	echo "ERROR: not found: $a"
	exit 1
fi
if [[ ! -e $b ]]; then
	echo "ERROR: not found: $b"
	exit 1
fi

a=$(readlink -f "$a")
b=$(readlink -f "$b")

echo "Compare"
echo "  A: $a"
echo "  B: $b"
echo

if [[ $a == "$b" ]]; then
	echo "RESULT: IDENTICAL (same path)"
	exit 0
fi

if [[ -f $a && -f $b ]]; then
	size_a=$(stat -c%s "$a" 2>/dev/null || stat -f%z "$a")
	size_b=$(stat -c%s "$b" 2>/dev/null || stat -f%z "$b")

	echo "Type: file"
	echo "  A size: $(numfmt --to=iec-i --suffix=B "$size_a" 2>/dev/null || echo "${size_a} bytes")"
	echo "  B size: $(numfmt --to=iec-i --suffix=B "$size_b" 2>/dev/null || echo "${size_b} bytes")"

	if [[ $size_a != "$size_b" ]]; then
		echo
		echo "RESULT: DIFFERENT (size)"
		exit 0
	fi

	if cmp -s "$a" "$b"; then
		echo
		echo "RESULT: IDENTICAL (byte-for-byte)"
	else
		echo "  A md5: $(md5sum "$a" | awk '{print $1}')"
		echo "  B md5: $(md5sum "$b" | awk '{print $1}')"
		echo
		echo "RESULT: DIFFERENT"
	fi
	exit 0
fi

if [[ -d $a && -d $b ]]; then
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/yazi-compare.XXXXXX")
	trap 'rm -rf "$tmp"' EXIT

	list_a=$tmp/a.files
	list_b=$tmp/b.files
	shared=$tmp/shared.files
	diffs=$tmp/diffs

	find "$a" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$list_a" || find "$a" -type f | sed "s|^$a/||" | LC_ALL=C sort >"$list_a"
	find "$b" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort >"$list_b" || find "$b" -type f | sed "s|^$b/||" | LC_ALL=C sort >"$list_b"

	files_a=$(wc -l <"$list_a" | tr -d ' ')
	files_b=$(wc -l <"$list_b" | tr -d ' ')
	size_a=$(du -sh "$a" 2>/dev/null | awk '{print $1}')
	size_b=$(du -sh "$b" 2>/dev/null | awk '{print $1}')

	only_a=$(comm -23 "$list_a" "$list_b" | wc -l | tr -d ' ')
	only_b=$(comm -13 "$list_a" "$list_b" | wc -l | tr -d ' ')
	comm -12 "$list_a" "$list_b" >"$shared"

	echo "Type: directory"
	echo "  A files: $files_a   size: $size_a"
	echo "  B files: $files_b   size: $size_b"
	echo "  Only in A: $only_a"
	echo "  Only in B: $only_b"

	if [[ ! -s $shared ]]; then
		echo "  Shared files that differ: 0"
		echo
		if [[ $only_a -eq 0 && $only_b -eq 0 ]]; then
			echo "RESULT: IDENTICAL"
		elif [[ $only_b -eq 0 ]]; then
			echo "RESULT: B is a SUBSET of A (all B files match A; A has $only_a extra)"
		elif [[ $only_a -eq 0 ]]; then
			echo "RESULT: A is a SUBSET of B (all A files match B; B has $only_b extra)"
		else
			echo "RESULT: DIFFERENT"
		fi
		exit 0
	fi

	workers=$(nproc 2>/dev/null || echo 4)
	export CMP_A=$a CMP_B=$b
	xargs -a "$shared" -P "$workers" -I{} sh -c '
		rel="$1"
		fa="$CMP_A/$rel"
		fb="$CMP_B/$rel"
		sa=$(stat -c%s "$fa" 2>/dev/null || stat -f%z "$fa")
		sb=$(stat -c%s "$fb" 2>/dev/null || stat -f%z "$fb")
		if [[ $sa != "$sb" ]] || ! cmp -s "$fa" "$fb"; then
			printf "%s\n" "$rel"
		fi
	' _ {} >"$diffs"

	differ=$(wc -l <"$diffs" | tr -d ' ')
	echo "  Shared files that differ: $differ"
	echo

	if [[ $only_a -eq 0 && $only_b -eq 0 && $differ -eq 0 ]]; then
		echo "RESULT: IDENTICAL"
		exit 0
	fi

	if [[ $only_b -eq 0 && $differ -eq 0 ]]; then
		echo "RESULT: B is a SUBSET of A (all B files match A; A has $only_a extra)"
	elif [[ $only_a -eq 0 && $differ -eq 0 ]]; then
		echo "RESULT: A is a SUBSET of B (all A files match B; B has $only_b extra)"
	else
		echo "RESULT: DIFFERENT"
	fi

	if [[ -s $diffs ]]; then
		echo
		echo "Sample differing shared files:"
		head -n 50 "$diffs" | sed 's|^|  |'
		if [[ $differ -gt 50 ]]; then
			echo "  ... ($((differ - 50)) more)"
		fi
	fi

	if [[ $only_a -gt 0 ]]; then
		echo
		echo "Sample only in A:"
		comm -23 "$list_a" "$list_b" | head -n 50 | sed 's|^|  |'
		if [[ $only_a -gt 50 ]]; then
			echo "  ... ($((only_a - 50)) more)"
		fi
	fi

	if [[ $only_b -gt 0 ]]; then
		echo
		echo "Sample only in B:"
		comm -13 "$list_a" "$list_b" | head -n 50 | sed 's|^|  |'
		if [[ $only_b -gt 50 ]]; then
			echo "  ... ($((only_b - 50)) more)"
		fi
	fi

	exit 0
fi

echo "Type: mixed (one file, one directory)"
echo "RESULT: DIFFERENT (not comparable as the same kind)"
exit 0
]==]
