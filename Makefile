TCLSH?=tclsh8.6

depend:
	echo 'package require sqlite3 3.24.0' | $(TCLSH)
	cpanm --installdeps .

test:
	@prove --nocolor

.PHONY: depend test
