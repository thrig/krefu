# MacPorts may instead need just tcl here
TCL?=tcl86
TCLSH?=tclsh8.6
# some OS may need to pull in ncurses via pkg-config
CFLAGS=-std=c99 -O2 -Wall -pedantic -fno-diagnostics-color -fstack-protector-all -fPIC -fPIE -pie -pipe `pkg-config --cflags --libs $(TCL)` -lcurses

krefu: krefu.c

depend:
	echo 'package require sqlite3 3.24.0' | $(TCLSH)
	cpanm --installdeps .

test: krefu
	@prove --nocolor

.PHONY: depend test
