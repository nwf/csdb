#!/bin/zsh

: ${LUA:=luajit} ${TMPDIR:=/tmp/cdbtest}
LOG1=${TMPDIR}/test-log1
LOG2=${TMPDIR}/test-log2
LOG3=${TMPDIR}/test-log3
LOG4=${TMPDIR}/test-log4

set -e -u -x

# Test digest-prefix
{ ${LUA} ./cdb-util digest-prefix foo <<HERE
0  a
1  🎵
\\2  a\\nb
3  ./d
4  /x
HERE
} | diff -u /dev/fd/3 - 3<<HERE
0  foo/a
1  foo/🎵
\\2  foo/a\\nb
3  foo/d
4  /x
HERE

# Test digest-relativize
cat >${LOG1} <<HERE
0  a
HERE
cat >${LOG2} <<HERE
1  /b
HERE
{ ${LUA} ./cdb-util digest-relativize <<HERE
${LOG1}
${LOG2}
HERE
} | diff -u /dev/fd/3 - 3<<HERE
0  ${TMPDIR}/a
1  /b
HERE

set +x
echo "OK"
