#!/bin/zsh

: ${LUA:=luajit} ${TMPDIR:=/tmp/cdbtest}
DB1=${TMPDIR}/test-db1
DB2=${TMPDIR}/test-db2
LOG1=${TMPDIR}/test-log1
LOG2=${TMPDIR}/test-log2
LOG3=${TMPDIR}/test-log3
LOG4=${TMPDIR}/test-log4

set -e -u
mkdir -p ${TMPDIR}
rm -f ${DB1} ${LOG1} ${LOG2} ${LOG3} ${LOG4}

set -x

# Test 'init' and that we can invoke from a different directory
pushd tmp
${LUA} ../cdb --db ${DB1} init
popd

# Seed test database with some data
cat >${LOG1} <<HERE
1  ordinary
4  ti'cky
7  twinned
8  twinned
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} addhash <${LOG1}) <<HERE
Processed 4 records
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} addhash --progress <${LOG1} 2>&1 1>/dev/null) <<HERE
Processed 4 records
HERE

diff -u /dev/null <(printf '\\2  fi\\\\le\x003  another\x00' |
        ${LUA} ./cdb --db ${DB1} addhash --no-progress --graft graft/ --inul)

# Test 'look'
diff -u - <(${LUA} ./cdb --db ${DB1} look '*' | sort) <<HERE
1  ordinary
\\2  graft/fi\\\\le
3  graft/another
4  ti'cky
7  twinned
8  twinned
HERE

# and via stdin
diff -u - <(${LUA} ./cdb --db ${DB1} look <<<"graft/*"$'\n'"ordinary" | sort) <<HERE
1  ordinary
\\2  graft/fi\\\\le
3  graft/another
HERE

# Test conflict detection (see TODO)
diff -u - <(${LUA} ./cdb --db ${DB1} conflicts | sed -e 's/ at.*$//') <<HERE
PATH	twinned
 observed hash 7 with id 3
 observed hash 8 with id 4
HERE

# Replace path with newer observation
diff -u - <(${LUA} ./cdb --db ${DB1} addhash --replace-paths <<<"9  twinned") <<HERE
Processed 1 records
HERE

# Test --format of 'look' and that replacement succeeded
diff -u - <(${LUA} ./cdb --db ${DB1} look --format '$e $h $f$z' '*' | sort) <<HERE
 1 ordinary
\\ 2 graft/fi\\\\le
 3 graft/another
 4 ti'cky
 9 twinned
HERE

# Test glob, --unescape, and --nul of 'look'
cmp <(printf '2  graft/fi\\le\x003  graft/another\x00') \
    <(${LUA} ./cdb --db ${DB1} look --unescape --nul 'graft/*' | sort -z)

# Test 'stats'
diff -u - <(${LUA} ./cdb --db ${DB1} stats) <<HERE
nhash=7 npath=5 nobsv=5 nsuper=0
HERE

# Test 'GC': we expect "hashes" 7 and 8 gone after --replace-paths above
diff -u - <(${LUA} ./cdb --db ${DB1} gc) <<HERE
-- DEAD HASH	7
DELETE FROM hashes WHERE hashid = 3;
-- DEAD HASH	8
DELETE FROM hashes WHERE hashid = 4;
HERE

# Execute expected statements, verify no more garbage
sqlite3 ${DB1} <<HERE
DELETE FROM hashes WHERE hashid = 3;
DELETE FROM hashes WHERE hashid = 4;
HERE
diff -u /dev/null <(${LUA} ./cdb --db ${DB1} gc)

# Test verifyhash (see TODO)
diff -u - <(${LUA} ./cdb --db ${DB1} verifyhash <<<"1  ordinary") <<HERE
OK:	ordinary
HERE

diff -u - <(${LUA} ./cdb --db ${DB1} verifyhash <<<"2  ordinary") <<HERE
Path 'ordinary' not associated with that hash in database
1 total errors
HERE

diff -u - <(${LUA} ./cdb --db ${DB1} verifyhash --also-mismatch <<<"2  ordinary") <<HERE
Path 'ordinary' not associated with that hash in database
... additional hash '1' in database
1 total errors
HERE

diff -u - <(printf "1  ordinary\x009  twinned\x00" | ${LUA} ./cdb --db ${DB1} verifyhash -1) <<HERE
OK:	ordinary
OK:	twinned
HERE

diff -u - <(${LUA} ./cdb --db ${DB1} verifyhash --graft graft <<<"3  another") <<HERE
OK:	graft/another
HERE

# Test 'maphash' and 'mappath'.  The other args can probably be presumed to
# work, since they're interpreted the same way throughout the code
diff -u - <(${LUA} ./cdb --db ${DB1} maphash <<<"1") <<<"1  ordinary"
diff -u - <(${LUA} ./cdb --db ${DB1} mappath <<<"ordinary") <<<"1  ordinary"

# Test 'ingeset'
cat >${LOG1} <<HERE
5  new
9  twinned copy 🎵
\\6  new\\\\esc
4  ti'cky copy
4  ti'cky copy with \$extra
HERE
${LUA} ./cdb --db ${DB1} ingest --target x --prune=${LOG4} --verbose <${LOG1} >${LOG2} 2>${LOG3}
# Import commands on stdout
diff -u - ${LOG2} <<HERE
cp -- 'new' 'x/new'
cp -- 'new\\esc' 'x/new\\esc'
HERE
# Log on stderr
diff -u - ${LOG3} <<HERE
Import 'new' to 'x/new'
Import hash 9 from path 'twinned copy 🎵' already in database at 'twinned'
Import 'new\\esc' to 'x/new\\esc'
Import hash 4 from path "ti'cky copy" already in database at "ti'cky"
Import hash 4 from path 'ti'"'"'cky copy with \$extra' already in database at "ti'cky"
HERE
# Prunelog
diff -u - <(tr '\000' '\n' <${LOG4}) <<HERE
twinned copy 🎵
ti'cky copy
ti'cky copy with \$extra
HERE

# Again, with intermixed pruning commands
${LUA} ./cdb --db ${DB1} ingest --target x --prune <${LOG1} >${LOG2} 2>${LOG3}
diff -u - ${LOG2} <<HERE
cp -- 'new' 'x/new'
rm -- 'twinned copy 🎵'
cp -- 'new\\esc' 'x/new\\esc'
rm -- 'ti'"'"'cky copy'
rm -- 'ti'"'"'cky copy with \$extra'
HERE
diff -u /dev/null ${LOG3}

# With move
diff -u - <(${LUA} ./cdb --db ${DB1} ingest --move --target x --digest-log ${LOG2} <${LOG1}) <<HERE
mv -- 'new' 'x/new'
mv -- 'new\\esc' 'x/new\\esc'
HERE
diff -u - ${LOG2} <<HERE
5  x/new
\\6  x/new\\\\esc
HERE

diff -u /dev/null <(${LUA} ./cdb --db ${DB1} gc)

# And without actually doing the import
${LUA} ./cdb --db ${DB1} ingest --prune=${LOG3} --verbose >${LOG1} 2>${LOG2} \
  <<<'5  new'$'\n''4  copy'
# No output stdout
diff -u /dev/null ${LOG1}
# One prunelog entry
echo -n 'copy\0' | cmp - ${LOG3}
# Log on stderr
diff -u - ${LOG2} <<HERE
Not importing new 'new'
Import hash 4 from path 'copy' already in database at "ti'cky"
HERE

# And with some rude characters in the path name
diff -u - <(${LUA} ./cdb --db ${DB1} ingest --target x <<<'5  rude'$'\r''new') \
          <<<"cp -- 'rude"$'\r'"new' 'x/rude"$'\r'"new'"
diff -u - <(${LUA} ./cdb --db ${DB1} ingest --target x --extended-escapes <<<'5  rude'$'\t''new') \
          <<<"cp -- 'rude'\$'\\x09''new' 'x/rude'\$'\\x09''new'"
diff -u - <(${LUA} ./cdb --db ${DB1} ingest --target x --verbose 2>&1 <<<'9  rude'$'\r''copy') \
          <<<"Import hash 9 from path 'rude'$'\\x0d''copy' already in database at 'twinned'"

# Test 'filterpath'
cat >${LOG1} <<HERE
\\6  new\\\\esc
9  twinned
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} filterpath --predicate=in <${LOG1}) <<HERE
9  twinned
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} filp --format='$h$e$f$z' --predicate=out <${LOG1}) <<HERE
6\\new\\\\esc
HERE

# Test 'filterpath' --in-paths handling
cat >${LOG1} <<HERE
new\\esc
twinned
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} filterpath --predicate=in --in-paths <${LOG1}) <<HERE
-  twinned
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} filp --in-paths="0123" --predicate=out <${LOG1}) <<HERE
\\0123  new\\\\esc
HERE

# Test 'filterhash'
cat >${LOG1} <<HERE
\\6  hocus\\rpocus
9  abracadabra
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} filterhash --predicate=in <${LOG1}) <<<"9  abracadabra"
diff -u - <(${LUA} ./cdb --db ${DB1} filterhash --predicate=out --unescape <${LOG1}) \
  <<<"6  hocus"$'\r'"pocus"

# Test domv
${LUA} ./cdb --db ${DB1} addh --no-progress <<<"1  ordinary again"
diff -u - <(${LUA} ./cdb --db ${DB1} maph 1) <<HERE
1  ordinary
1  ordinary again
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} domv --verbose "ordinary again") <<HERE
Trying mv:	ordinary again
Found path	ordinary
OK	1
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} maph 1) <<HERE
1  ordinary
HERE

diff -u /dev/null <(${LUA} ./cdb --db ${DB1} gc)

# TODO: test diff

# Add some superseders and check that we can dump them back out
cp ${DB1} ${DB2}

${LUA} ./cdb --db ${DB1} addsh --no-progress <<HERE
11 1 pre-ordinary replace
14 4
21 20 supersuper
20 0 badsuper
HERE

${LUA} ./cdb --db ${DB1} addh --no-progress <<HERE
4  graft/better
HERE

${LUA} ./cdb --db ${DB1} addsuper graft/another graft/better getting better

diff -u - <(${LUA} ./cdb --db ${DB1} dumpsuper | sort) <<HERE
11 1 pre-ordinary replace
14 4 
20 0 badsuper
21 20 supersuper
3 4 getting better
HERE

# checksuper
diff -u - <(${LUA} ./cdb --db ${DB1} checksuper) <<HERE
Superseder record without replacement:
 note:	badsuper
 old:	20
 new:	0

HERE

# Test domv with supers
${LUA} ./cdb --db ${DB1} addh --no-progress <<HERE
11  pre-ordinary
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} maph 11) <<HERE
11  pre-ordinary
HERE
diff -u - <(${LUA} ./cdb --db ${DB1} domv --verbose "pre-ordinary" | sed -e "s/\tat\t.*//") <<HERE
Trying mv:	pre-ordinary
Found super	pre-ordinary replace
OK	1
HERE
diff -u /dev/null <(${LUA} ./cdb --db ${DB1} maph 11)

diff -u /dev/null <(${LUA} ./cdb --db ${DB1} gc)

# Test ingest with supers
${LUA} ./cdb --db ${DB1} ingest --target x --prune=${LOG3} --digest-log=${LOG4} --verbose \
  >${LOG1} 2>${LOG2} <<HERE
0  won't fix super
11  pre-ordinary again
20  badsuper but still super
HERE
diff -u - ${LOG1} <<HERE
HERE
# Log on stderr
diff -u - ${LOG2} <<HERE
Import hash 0 from path "won't fix super" in database without explanation!  Leaving in place.
Import hash 11 from path 'pre-ordinary again' already in database but superseded
Import hash 20 from path 'badsuper but still super' already in database but superseded
HERE
# Two files pruned
(tr '\n' '\000' | diff -u - ${LOG3}) <<HERE
pre-ordinary again
badsuper but still super
HERE
# Nothing imported
diff -u /dev/null ${LOG4}

# Fix supers and re-run checksuper
${LUA} ./cdb --db ${DB1} addhash --no-progress <<<"0  fixed super"
diff -u /dev/null <(${LUA} ./cdb --db ${DB1} checksuper)

diff -u - <(${LUA} ./cdb --db ${DB1} diff ${DB2} | sed -e 's/(.*)/TS/') <<HERE
-- Paths in local database not in remote:
  fixed super
  graft/better
-- Paths in remote database not in local:
-- Hashes in local database not in remote:
0  fixed super
-- Hashes in remote database not in local:
-- Superseders in local database not in remote:
11 1 TS pre-ordinary replace
14 4 TS 
21 20 TS supersuper
20 0 TS badsuper
3 4 TS getting better
-- Superseders in remote database not in local:
-- End of diff report
HERE

diff -u - <(${LUA} ./cdb --db ${DB2} diff --no-headers ${DB1} | sed -e 's/(.*)/TS/') <<HERE
  fixed super
  graft/better
0  fixed super
11 1 TS pre-ordinary replace
14 4 TS 
21 20 TS supersuper
20 0 TS badsuper
3 4 TS getting better
HERE

set +x
echo "OK"
