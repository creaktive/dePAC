# perl -MConfig -E 'say $Config{archname}'
ARCH=darwin-thread-multi-2level
WHITELIST=^(AnyEvent|JE|common)
MINIFY_PROC=4
MINIFY_ARGS=--backup-and-modify-in-place \
			--backup-file-extension=/ \
			--blank-lines-before-packages=0 \
			--blank-lines-before-subs=0 \
			--check-syntax \
			--converge \
			--delete-all-comments \
			--delete-old-newlines \
			--delete-old-whitespace \
			--delete-semicolons \
			--indent-columns=0 \
			--keep-old-blank-lines=0 \
			--maximum-consecutive-blank-lines=0 \
			--maximum-line-length=100000 \
			--noadd-semicolons \
			--noadd-whitespace \
			--noblanks-before-blocks \
			--noprofile \
			--notabs \
			--standard-error-output
all: depac
	ls -alh depac
depac.trace: depac.pl
	fatpack trace --to=depac.trace depac.pl
depac.packlists: depac.trace
	fatpack packlists-for `egrep '$(WHITELIST)' depac.trace` > depac.packlists
fatlib: depac.packlists
	fatpack tree `cat depac.packlists`
	cp -a fatlib/$(ARCH)/* fatlib/
	rm -rf fatlib/$(ARCH)
	cp AnyEvent/constants.pm fatlib/AnyEvent/constants.pm
	perl -i.bak -pe 's{(AnyEvent/constants)\.pl}{\1.pm}' fatlib/AnyEvent.pm
fatlib/.minified: fatlib
	find fatlib/ -type f -name \*.pm | xargs -P $(MINIFY_PROC) perltidy $(MINIFY_ARGS)
	touch fatlib/.minified
depac: fatlib/.minified
	fatpack file depac.pl > depac
	perl -c depac && chmod +x depac
clean:
	rm -rf depac depac.trace depac.packlists fatlib/
deps:
	cpan -i App::FatPacker Perl::Tidy
fast:
	git checkout origin/master depac
	git diff origin/master depac.pl | sed 's/depac\.pl/depac/' | patch -p1
	rm depac.orig
