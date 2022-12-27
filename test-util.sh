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

# Test the various shell escapes
#
# Full credit to https://github.com/jwilk/url.sh (MIT license) for the
# example.com URL below.  That's nicely evil.  Note that we have had to escape
# the dollar signs ourselves in the test input and outputs!  I'm not convinced
# that the "human" version is doing very well on that example, but it's so
# pathological that if you have file names like that you deserve what you get.
ARB=$(echo "a\rb")
cat >${LOG1} <<HERE
a	b
a\$b
${ARB}
x'
🎵
🎶"
α
α'
http://example.com/;'\$(gt=\$(perl\$IFS-E\$IFS's//62/;s/62/chr/e;say');eval\$IFS''cowsay\$IFS''pwned\$IFS\$gt/dev/tty)';cowsay\$IFS''pwned
HERE

${LUA} ./cdb-util escape posix <${LOG1} | diff -au /dev/fd/3 - 3<<HERE
'a	b'
'a\$b'
'${ARB}'
'x'"'"''
'🎵'
'🎶"'
'α'
'α'"'"''
'http://example.com/;'"'"'\$(gt=\$(perl\$IFS-E\$IFS'"'"'s//62/;s/62/chr/e;say'"'"');eval\$IFS'"'"''"'"'cowsay\$IFS'"'"''"'"'pwned\$IFS\$gt/dev/tty)'"'"';cowsay\$IFS'"'"''"'"'pwned'
HERE

${LUA} ./cdb-util escape extended <${LOG1} | diff -au /dev/fd/3 - 3<<HERE
'a'\$'\\x09''b'
'a\$b'
'a'\$'\\x0d''b'
'x'"'"''
''\$'\\xf0'''\$'\\x9f'''\$'\\x8e'''\$'\\xb5'''
''\$'\\xf0'''\$'\\x9f'''\$'\\x8e'''\$'\\xb6''"'
''\$'\\xce'''\$'\\xb1'''
''\$'\\xce'''\$'\\xb1'''"'"''
'http://example.com/;'"'"'\$(gt=\$(perl\$IFS-E\$IFS'"'"'s//62/;s/62/chr/e;say'"'"');eval\$IFS'"'"''"'"'cowsay\$IFS'"'"''"'"'pwned\$IFS\$gt/dev/tty)'"'"';cowsay\$IFS'"'"''"'"'pwned'
HERE

${LUA} ./cdb-util escape human <${LOG1} | diff -au /dev/fd/3 - 3<<HERE
'a'$'\\x09''b'
'a\$b'
'a'\$'\\x0d''b'
"x'"
'🎵'
'🎶"'
'α'
"α'"
'http://example.com/;'"'"'\$(gt=\$(perl\$IFS-E\$IFS'"'"'s//62/;s/62/chr/e;say'"'"');eval\$IFS'"'"''"'"'cowsay\$IFS'"'"''"'"'pwned\$IFS\$gt/dev/tty)'"'"';cowsay\$IFS'"'"''"'"'pwned'
HERE



set +x
echo "OK"
